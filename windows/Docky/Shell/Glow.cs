using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Docky.Core;

namespace Docky.Shell
{
    /// <summary>
    /// Bitmaps for the screen-edge glows. Glows are soft, so they're computed once at low
    /// resolution and the GPU scales them up; only opacity and a brush rotation animate.
    /// </summary>
    internal static class GlowKit
    {
        public static readonly Color[] Intro =
        {
            Color.FromRgb(84, 133, 255), Color.FromRgb(168, 107, 255), Color.FromRgb(255, 107, 204),
            Color.FromRgb(255, 140, 82), Color.FromRgb(250, 92, 122), Color.FromRgb(77, 209, 255),
        };

        public static readonly Color[] Warm =
        {
            Color.FromRgb(255, 184, 107), Color.FromRgb(255, 148, 117), Color.FromRgb(255, 163, 173),
            Color.FromRgb(255, 214, 143), Color.FromRgb(252, 158, 102),
        };

        /// <summary>A conic gradient that cycles through the colours.</summary>
        public static BitmapSource Conic(Color[] colors, int size = 256)
        {
            var px = new byte[size * size * 4];
            double c = (size - 1) / 2.0;
            int n = colors.Length;
            for (int y = 0; y < size; y++)
                for (int x = 0; x < size; x++)
                {
                    double a = Math.Atan2(y - c, x - c) / (2 * Math.PI);
                    double f = (a + 1) % 1 * n;
                    int i = (int)f;
                    double t = f - i;
                    t = t * t * (3 - 2 * t);
                    var A = colors[i % n];
                    var B = colors[(i + 1) % n];
                    int o = (y * size + x) * 4;
                    px[o] = (byte)(A.B + (B.B - A.B) * t);
                    px[o + 1] = (byte)(A.G + (B.G - A.G) * t);
                    px[o + 2] = (byte)(A.R + (B.R - A.R) * t);
                    px[o + 3] = 255;
                }
            var bmp = BitmapSource.Create(size, size, 96, 96, PixelFormats.Bgra32, null, px, size * 4);
            bmp.Freeze();
            return bmp;
        }

        /// <summary>A radial sprite: colours spread evenly from the centre to the rim.</summary>
        public static BitmapSource Radial(int size, params Color[] stops)
        {
            var px = new byte[size * size * 4];
            double c = (size - 1) / 2.0;
            for (int y = 0; y < size; y++)
                for (int x = 0; x < size; x++)
                {
                    double r = Math.Min(1, Math.Sqrt((x - c) * (x - c) + (y - c) * (y - c)) / c);
                    double f = r * (stops.Length - 1);
                    int i = Math.Min(stops.Length - 2, (int)f);
                    double t = f - i;
                    var A = stops[i];
                    var B = stops[i + 1];
                    double a = (A.A + (B.A - A.A) * t) / 255.0;
                    int o = (y * size + x) * 4;
                    px[o] = (byte)((A.B + (B.B - A.B) * t) * a);
                    px[o + 1] = (byte)((A.G + (B.G - A.G) * t) * a);
                    px[o + 2] = (byte)((A.R + (B.R - A.R) * t) * a);
                    px[o + 3] = (byte)(a * 255);
                }
            var bmp = BitmapSource.Create(size, size, 96, 96, PixelFormats.Pbgra32, null, px, size * 4);
            bmp.Freeze();
            return bmp;
        }

        private static double Erf(double x)
        {
            double t = 1 / (1 + 0.3275911 * Math.Abs(x));
            double y = 1 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t * Math.Exp(-x * x);
            return x >= 0 ? y : -y;
        }

        /// <summary>A band of width <paramref name="width"/> centred on 0, blurred by a Gaussian,
        /// sampled at signed distance <paramref name="d"/>.</summary>
        public static double Band(double d, double width, double blur)
        {
            double s = Math.Max(0.35, blur * 0.8) * Math.Sqrt(2);
            return 0.5 * (Erf((width / 2 - d) / s) - Erf((-width / 2 - d) / s));
        }

        /// <summary>Three box-blur passes (close to a Gaussian) over a single channel, in place.</summary>
        public static void Blur(float[] a, int w, int h, int radius)
        {
            if (radius < 1) return;
            var tmp = new float[a.Length];
            for (int pass = 0; pass < 3; pass++)
            {
                BoxH(a, tmp, w, h, radius);
                BoxV(tmp, a, w, h, radius);
            }
        }

        private static void BoxH(float[] src, float[] dst, int w, int h, int r)
        {
            float norm = 1f / (2 * r + 1);
            for (int y = 0; y < h; y++)
            {
                int row = y * w;
                float sum = 0;
                for (int x = -r; x <= r; x++) sum += src[row + Math.Clamp(x, 0, w - 1)];
                for (int x = 0; x < w; x++)
                {
                    dst[row + x] = sum * norm;
                    sum += src[row + Math.Min(w - 1, x + r + 1)] - src[row + Math.Max(0, x - r)];
                }
            }
        }

        private static void BoxV(float[] src, float[] dst, int w, int h, int r)
        {
            float norm = 1f / (2 * r + 1);
            for (int x = 0; x < w; x++)
            {
                float sum = 0;
                for (int y = -r; y <= r; y++) sum += src[Math.Clamp(y, 0, h - 1) * w + x];
                for (int y = 0; y < h; y++)
                {
                    dst[y * w + x] = sum * norm;
                    sum += src[Math.Min(h - 1, y + r + 1) * w + x] - src[Math.Max(0, y - r) * w + x];
                }
            }
        }

        /// <summary>The island's outline glow: signed distance to a rounded rectangle.</summary>
        public static BitmapSource IslandMask(Size island, double radius, double pad, double scale)
        {
            int w = (int)Math.Ceiling((island.Width + pad * 2) * scale), h = (int)Math.Ceiling((island.Height + pad * 2) * scale);
            var px = new byte[w * h * 4];
            double hw = island.Width / 2, hh = island.Height / 2, r = Math.Min(radius, Math.Min(hw, hh));
            double cx = pad + hw, cy = pad + hh;
            for (int y = 0; y < h; y++)
                for (int x = 0; x < w; x++)
                {
                    double qx = Math.Abs((x + 0.5) / scale - cx) - (hw - r), qy = Math.Abs((y + 0.5) / scale - cy) - (hh - r);
                    double outside = Math.Sqrt(Math.Max(qx, 0) * Math.Max(qx, 0) + Math.Max(qy, 0) * Math.Max(qy, 0));
                    double sd = outside + Math.Min(Math.Max(qx, qy), 0) - r;
                    double a = Math.Min(1, 0.95 * Band(sd, 26, 22) + Band(sd, 7, 4) + Band(sd, 2.5, 0));
                    byte b = (byte)(a * 255);
                    int o = (y * w + x) * 4;
                    px[o] = px[o + 1] = px[o + 2] = px[o + 3] = b;
                }
            var bmp = BitmapSource.Create(w, h, 96 * scale, 96 * scale, PixelFormats.Pbgra32, null, px, w * 4);
            bmp.Freeze();
            return bmp;
        }

        /// <summary>Screen rectangles that tile the edges (and optionally a centre column)
        /// without overlapping. Small layered windows are far cheaper than one full-screen one.</summary>
        public static List<Rect> Partition(double W, double H, double S, double centerHalfWidth = 0, double centerBottom = 0)
        {
            S = Math.Min(S, Math.Min(W, H) / 2 - 1);
            var list = new List<Rect>
            {
                new(0, 0, W, S),
                new(0, H - S, W, S),
                new(0, S, S, H - 2 * S),
                new(W - S, S, S, H - 2 * S),
            };
            if (centerHalfWidth > 0)
            {
                double left = Math.Max(S, W / 2 - centerHalfWidth), right = Math.Min(W - S, W / 2 + centerHalfWidth);
                double bottom = Math.Min(H - S, centerBottom);
                if (right > left && bottom > S) list.Add(new Rect(left, S, right - left, bottom - S));
            }
            return list;
        }
    }

    /// <summary>A soft border light over the whole screen, kept as alpha so any colour can shine through.</summary>
    internal sealed class EdgeMask
    {
        public readonly int PW, PH;
        private readonly float[] alpha, along;
        private readonly byte[] buffer;
        public readonly WriteableBitmap Bitmap;

        /// <param name="tint">When set the colour is baked in (a static wash); otherwise white alpha for masks.</param>
        public EdgeMask(double W, double H, double width, double blur, double resolution, bool trackPerimeter = false, Color? tint = null, double strength = 1)
        {
            PW = Math.Max(8, (int)Math.Round(W * resolution));
            PH = Math.Max(8, (int)Math.Round(H * resolution));
            alpha = new float[PW * PH];
            if (trackPerimeter) along = new float[PW * PH];
            double k = Math.Max(12, (width + 2 * blur) * 0.35);
            for (int py = 0; py < PH; py++)
                for (int px = 0; px < PW; px++)
                {
                    double x = (px + 0.5) / resolution, y = (py + 0.5) / resolution;
                    double dl = x, dr = W - x, dt = y, db = H - y;
                    double d = Math.Min(Math.Min(dl, dr), Math.Min(dt, db));
                    // A soft minimum rounds the corners instead of leaving a hard diagonal crease.
                    double soft = d - k * Math.Log(Math.Exp((d - dl) / k) + Math.Exp((d - dr) / k) + Math.Exp((d - dt) / k) + Math.Exp((d - db) / k));
                    int i = py * PW + px;
                    alpha[i] = (float)(GlowKit.Band(Math.Max(0, soft), width, blur) * strength);
                    if (along == null) continue;
                    // Distance along the border from the bottom centre, up either side, to the top centre.
                    double s;
                    if (d == db) s = Math.Abs(x - W / 2);
                    else if (d == dl || d == dr) s = W / 2 + (H - y);
                    else s = W / 2 + H + (W / 2 - Math.Abs(x - W / 2));
                    along[i] = (float)(s / (W + H));
                }
            buffer = new byte[PW * PH * 4];
            Bitmap = new WriteableBitmap(PW, PH, 96, 96, PixelFormats.Pbgra32, null);
            var c = tint ?? Colors.White;
            for (int i = 0; i < alpha.Length; i++)
            {
                double a = alpha[i];
                buffer[i * 4] = (byte)(c.B * a);
                buffer[i * 4 + 1] = (byte)(c.G * a);
                buffer[i * 4 + 2] = (byte)(c.R * a);
                buffer[i * 4 + 3] = (byte)(255 * a);
            }
            Bitmap.WritePixels(new Int32Rect(0, 0, PW, PH), buffer, PW * 4, 0);
        }

        /// <summary>Show only the part of the border within <paramref name="progress"/> of the bottom centre.</summary>
        public void Reveal(double progress, double soft = 0.025)
        {
            if (along == null) return;
            for (int i = 0; i < alpha.Length; i++)
            {
                double v = Math.Clamp((progress - along[i]) / soft, 0, 1);
                v = v * v * (3 - 2 * v);
                byte b = (byte)(alpha[i] * v * 255);
                buffer[i * 4] = buffer[i * 4 + 1] = buffer[i * 4 + 2] = buffer[i * 4 + 3] = b;
            }
            Bitmap.WritePixels(new Int32Rect(0, 0, PW, PH), buffer, PW * 4, 0);
        }
    }

    /// <summary>A click-through, always-on-top transparent window covering one piece of the screen.</summary>
    internal sealed class OverlayPane : Window
    {
        public readonly Rect Region;
        public readonly Canvas Root;

        public OverlayPane(Rect region)
        {
            Region = region;
            WindowStyle = WindowStyle.None;
            AllowsTransparency = true;
            Background = Brushes.Transparent;
            Topmost = true;
            ShowInTaskbar = false;
            ShowActivated = false;
            ResizeMode = ResizeMode.NoResize;
            Focusable = false;
            IsHitTestVisible = false;
            Left = region.X;
            Top = region.Y;
            Width = region.Width;
            Height = region.Height;
            Title = "Docky Glow";
            Root = new Canvas { Width = region.Width, Height = region.Height, ClipToBounds = true, IsHitTestVisible = false };
            Content = Root;
        }

        protected override void OnSourceInitialized(EventArgs e)
        {
            base.OnSourceInitialized(e);
            Native.MakeClickThrough(new WindowInteropHelper(this).Handle);
        }

        /// <summary>A full-screen image placed so this pane shows its slice.</summary>
        public Image AddScreenImage(ImageSource source, double W, double H)
        {
            var img = new Image { Source = source, Width = W, Height = H, Stretch = Stretch.Fill, IsHitTestVisible = false };
            RenderOptions.SetBitmapScalingMode(img, BitmapScalingMode.Linear);
            Canvas.SetLeft(img, -Region.X);
            Canvas.SetTop(img, -Region.Y);
            Root.Children.Add(img);
            return img;
        }

        /// <summary>A rotating conic gradient seen through a full-screen mask, sized to this pane only.</summary>
        public (System.Windows.Shapes.Rectangle shape, RotateTransform spin) AddMaskedConic(Panel parent, BitmapSource conic, ImageSource mask, double W, double H, double opacity)
        {
            double D = Math.Sqrt(W * W + H * H) + 4;
            double cx = W / 2 - Region.X, cy = H / 2 - Region.Y;
            var spin = new RotateTransform(0, cx, cy);
            var fill = new ImageBrush(conic)
            {
                ViewportUnits = BrushMappingMode.Absolute,
                Viewport = new Rect(cx - D / 2, cy - D / 2, D, D),
                Stretch = Stretch.Fill,
                Transform = spin,
            };
            var maskBrush = new ImageBrush(mask)
            {
                ViewportUnits = BrushMappingMode.Absolute,
                Viewport = new Rect(-Region.X, -Region.Y, W, H),
                Stretch = Stretch.Fill,
            };
            RenderOptions.SetBitmapScalingMode(fill, BitmapScalingMode.Linear);
            RenderOptions.SetBitmapScalingMode(maskBrush, BitmapScalingMode.Linear);
            var rect = new System.Windows.Shapes.Rectangle
            {
                Width = Region.Width, Height = Region.Height, Fill = fill, OpacityMask = maskBrush, Opacity = opacity, IsHitTestVisible = false,
            };
            parent.Children.Add(rect);
            return (rect, spin);
        }
    }
}
