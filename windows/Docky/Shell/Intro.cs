using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Docky.Core;
using Docky.Island;

namespace Docky.Shell
{
    internal static class Ease
    {
        public static Func<double, double> Bezier(double x1, double y1, double x2, double y2) => t =>
        {
            if (t <= 0) return 0;
            if (t >= 1) return 1;
            double u = t;
            for (int i = 0; i < 8; i++)
            {
                double x = B(u, x1, x2) - t, dx = D(u, x1, x2);
                if (Math.Abs(x) < 1e-5 || Math.Abs(dx) < 1e-6) break;
                u = Math.Clamp(u - x / dx, 0, 1);
            }
            return B(u, y1, y2);
        };

        private static double B(double u, double a, double b) => 3 * a * u * (1 - u) * (1 - u) + 3 * b * u * u * (1 - u) + u * u * u;
        private static double D(double u, double a, double b) => 3 * a * (1 - u) * (1 - u) + 6 * (b - a) * u * (1 - u) + 3 * (1 - b) * u * u;

        public static readonly Func<double, double> Main = Bezier(0.3, 0, 0.2, 1);
        public static readonly Func<double, double> Overshoot = Bezier(0.2, 1.35, 0.4, 1);
        public static readonly Func<double, double> In = Bezier(0.42, 0, 1, 1);
        public static readonly Func<double, double> InOut = Bezier(0.42, 0, 0.58, 1);

        /// <summary>Keyframes at absolute times, with an optional easing per segment.</summary>
        public static double Keys(double t, double[] times, double[] values, Func<double, double>[] eases = null)
        {
            if (t <= times[0]) return values[0];
            for (int i = 0; i < times.Length - 1; i++)
                if (t < times[i + 1])
                {
                    double f = (t - times[i]) / Math.Max(1e-6, times[i + 1] - times[i]);
                    var e = eases != null ? eases[i] : null;
                    return values[i] + (values[i + 1] - values[i]) * (e?.Invoke(f) ?? f);
                }
            return values[^1];
        }
    }

    /// <summary>
    /// The launch intro:
    ///   0.00  the screen's edges dim slightly
    ///   0.05  two flames ignite at the bottom centre and race up both sides, shedding sparks
    ///   0.95  they meet at the top centre in a flash and a burst of sparks
    ///   0.45  "Docky" rises in the middle; a highlight sweeps across it
    ///   1.85  the wordmark shrinks up into the top of the screen…
    ///   2.05  …and the island drops in, wearing the same glow for three seconds
    ///   5.05  the edge glow, vignette and island glow fade away
    /// Drawn in a handful of small click-through windows around the edges (plus one in the
    /// middle for the wordmark) rather than one full-screen layered window, which keeps it smooth.
    /// </summary>
    public sealed class IntroPlayer
    {
        private const double Ignite = 0.9, Meet = 0.95, WordIn = 0.45, WordOut = 1.85, DropTime = 2.05, FadeTime = 5.05, EndTime = 6.0;
        private const double IslandPad = 70;

        private sealed class Pane
        {
            public OverlayPane Window;
            public Canvas Glow;
            public Image Vignette;
            public RotateTransform[] Spins = Array.Empty<RotateTransform>();
            public SceneLayer Scene;
            public bool LastHit = true;
        }

        private sealed class Spark
        {
            public double X, Y, VX, VY, Age, Life, Size, Shrink, Fade, Gravity, Drag;
            public int Color;
        }

        private sealed class SceneLayer : FrameworkElement
        {
            private readonly IntroPlayer player;
            private readonly Rect region;
            public SceneLayer(IntroPlayer p, Rect r) { player = p; region = r; Width = r.Width; Height = r.Height; IsHitTestVisible = false; }
            protected override void OnRender(DrawingContext dc)
            {
                dc.PushClip(new RectangleGeometry(new Rect(0, 0, region.Width, region.Height)));
                dc.PushTransform(new TranslateTransform(-region.X, -region.Y));
                player.Draw(dc, region);
                dc.Pop();
                dc.Pop();
            }
        }

        private IslandWindow island;
        private Action done;
        private double W, H;
        private readonly List<Pane> panes = new();
        private EdgeMask bloom, core;
        private BitmapSource conic, headSprite, flashSprite, wordBloom, wordFace, islandMask;
        private BitmapSource[] sparkSprites;
        private Size wordSize;
        private double wordFont;
        private Stopwatch clock;
        private double last;
        private bool burstDone, revealFinished, dropped;
        private Spring drop;
        private Size islandSize;
        private readonly List<Spark> sparks = new();
        private readonly Random rng = new();
        private double emitCarry;

        // Per-frame state read by the scene layers.
        private double t, reveal, angle, glowOpacity, headOpacity, flashOpacity, wordOpacity, wordScale, wordY, shineX = double.NaN, islandGlowOpacity;
        private ImageBrush lineBrush, islandBrush;
        private readonly Pen linePen = new() { Thickness = 2.5, StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round, LineJoin = PenLineJoin.Round };
        private Brush shineBrush;

        public bool IsPlaying => clock != null;

        public void Play(IslandWindow island, Action done)
        {
            Stop();
            this.island = island;
            this.done = done;
            W = SystemParameters.PrimaryScreenWidth;
            H = SystemParameters.PrimaryScreenHeight;
            island.HideForIntro();

            conic = GlowKit.Conic(GlowKit.Intro);
            bloom = new EdgeMask(W, H, 80, 50, 0.16, trackPerimeter: true);
            core = new EdgeMask(W, H, 22, 12, 0.32, trackPerimeter: true);
            bloom.Reveal(0);
            core.Reveal(0);
            var vignette = new EdgeMask(W, H, 140, 70, 0.1, tint: Colors.Black, strength: 0.45);
            headSprite = GlowKit.Radial(90, Colors.White, Color.FromArgb(102, 255, 107, 204), Color.FromArgb(0, 255, 107, 204));
            flashSprite = GlowKit.Radial(280, Color.FromArgb(235, 255, 255, 255), Color.FromArgb(128, 168, 107, 255), Color.FromArgb(0, 168, 107, 255));
            sparkSprites = GlowKit.Intro.Select(c => GlowKit.Radial(32, Colors.White, Color.FromArgb(170, c.R, c.G, c.B), Color.FromArgb(0, c.R, c.G, c.B))).ToArray();
            wordFont = Math.Clamp(W * 0.07, 72, 124);
            (wordBloom, wordFace, wordSize) = Wordmark(wordFont);
            shineBrush = new LinearGradientBrush(new GradientStopCollection
            {
                new(Color.FromArgb(0, 255, 255, 255), 0), new(Color.FromArgb(242, 255, 255, 255), 0.5), new(Color.FromArgb(0, 255, 255, 255), 1),
            }, new Point(0, 0.5), new Point(1, 0.5));
            shineBrush.Freeze();

            const double S = 240;
            var regions = GlowKit.Partition(W, H, S, 540, H / 2 + wordSize.Height / 2 + 20);
            for (int i = 0; i < regions.Count; i++)
            {
                var r = regions[i];
                var pane = new Pane { Window = new OverlayPane(r) };
                bool edge = i < 4;
                if (edge)
                {
                    pane.Vignette = pane.Window.AddScreenImage(vignette.Bitmap, W, H);
                    pane.Vignette.Opacity = 0;
                    pane.Glow = new Canvas { Width = r.Width, Height = r.Height };
                    pane.Spins = new[]
                    {
                        pane.Window.AddMaskedConic(pane.Glow, conic, bloom.Bitmap, W, H, 0.8).spin,
                        pane.Window.AddMaskedConic(pane.Glow, conic, core.Bitmap, W, H, 0.95).spin,
                    };
                    pane.Window.Root.Children.Add(pane.Glow);
                }
                pane.Scene = new SceneLayer(this, r);
                pane.Window.Root.Children.Add(pane.Scene);
                pane.Window.Show();
                panes.Add(pane);
            }
            island.RaiseToTop();

            clock = Stopwatch.StartNew();
            last = 0;
            CompositionTarget.Rendering += OnFrame;
        }

        public void Stop()
        {
            if (clock == null) return;
            CompositionTarget.Rendering -= OnFrame;
            clock = null;
            foreach (var p in panes) p.Window.Close();
            panes.Clear();
            sparks.Clear();
            burstDone = revealFinished = dropped = false;
            if (island != null) { island.DropIn(); island.EndIntro(); }
            var cb = done;
            done = null;
            cb?.Invoke();
        }

        // MARK: Frame

        private void OnFrame(object sender, EventArgs e)
        {
            if (clock == null) return;
            t = clock.Elapsed.TotalSeconds;
            double dt = Math.Clamp(t - last, 0, 0.05);
            last = t;
            if (t >= EndTime) { Stop(); return; }

            angle = t / 4.5 * 360 % 360;
            double cx = W / 2, cy = H / 2;

            // Edge glow
            reveal = Ease.Main(Math.Clamp((t - 0.05) / Ignite, 0, 1));
            if (!revealFinished)
            {
                bloom.Reveal(reveal * 1.04);
                core.Reveal(reveal * 1.04);
                if (reveal >= 1) revealFinished = true;
            }
            glowOpacity = Ease.Keys(t, new[] { 0, FadeTime, FadeTime + 0.8 }, new[] { 1.0, 1, 0 });
            double vignette = Ease.Keys(t, new[] { 0, 0.42, 5.0, 5.8 }, new[] { 0.0, 1, 1, 0 });
            foreach (var p in panes)
            {
                foreach (var s in p.Spins) s.Angle = angle;
                if (p.Glow != null) p.Glow.Opacity = glowOpacity;
                if (p.Vignette != null) p.Vignette.Opacity = vignette;
            }
            double D = Math.Sqrt(W * W + H * H) + 4;
            lineBrush = new ImageBrush(conic) { ViewportUnits = BrushMappingMode.Absolute, Viewport = new Rect(cx - D / 2, cy - D / 2, D, D), Transform = new RotateTransform(angle, cx, cy) };
            linePen.Brush = lineBrush;

            // Flame heads and their sparks
            headOpacity = Ease.Keys(t, new[] { 0, 0.06, 0.95, 1.15 }, new[] { 0.0, 1, 1, 0 });
            if (t > 0.05 && t < 0.05 + Ignite * 0.92)
            {
                emitCarry += 170 * dt;
                int n = (int)emitCarry;
                emitCarry -= n;
                foreach (bool left in new[] { true, false })
                {
                    var head = PointAlong(HalfPath(left, 3), reveal);
                    for (int i = 0; i < n; i++) sparks.Add(TrailSpark(head));
                }
            }

            // The meeting flash and burst
            flashOpacity = Ease.Keys(t, new[] { 0, 0.92, 1.05, 1.9 }, new[] { 0.0, 0, 1, 0 });
            if (!burstDone && t >= Meet)
            {
                burstDone = true;
                for (int i = 0; i < 200; i++) sparks.Add(BurstSpark(new Point(cx, 4)));
            }
            for (int i = sparks.Count - 1; i >= 0; i--)
            {
                var s = sparks[i];
                s.Age += dt;
                if (s.Age >= s.Life) { sparks.RemoveAt(i); continue; }
                double k = Math.Max(0, 1 - s.Drag * dt);
                s.VX *= k;
                s.VY = s.VY * k + s.Gravity * dt;
                s.X += s.VX * dt;
                s.Y += s.VY * dt;
                s.Size = Math.Max(0, s.Size - s.Shrink * dt);
            }

            // Wordmark
            double[] keys = { 0, WordIn, WordIn + 0.65, WordOut, WordOut + 0.42 };
            wordOpacity = Ease.Keys(t, new[] { 0, WordIn, WordIn + 0.4, WordOut + 0.1, WordOut + 0.4 }, new[] { 0.0, 0, 1, 1, 0 });
            wordScale = Ease.Keys(t, keys, new[] { 0.84, 0.84, 1.0, 1.03, 0.12 }, new[] { Ease.Main, Ease.Overshoot, Ease.Main, Ease.In });
            wordY = Ease.Keys(t, keys, new[] { cy + 30, cy + 30, cy, cy - 6, 22 }, new[] { Ease.Main, Ease.Main, Ease.Main, Ease.In });
            double sweepStart = WordIn + 0.45;
            double u = wordFont / 120;
            shineX = t >= sweepStart && t <= sweepStart + 0.9
                ? -160 * u + (wordSize.Width + 320 * u) * Ease.InOut((t - sweepStart) / 0.9)
                : double.NaN;

            // The island drops in wearing the glow
            if (!dropped && t >= DropTime)
            {
                dropped = true;
                island.DropIn();
                islandSize = island.TargetSize;
                islandMask = GlowKit.IslandMask(islandSize, island.TargetRadius, IslandPad, 2);
                drop = new Spring(-(islandSize.Height + 8 + 30)) { Target = 0, Response = 0.6, Damping = 0.68 };
            }
            if (dropped)
            {
                drop.Step(dt);
                var size = island.TargetSize;
                // Follow small size changes (e.g. music starting) without rebuilding the mask.
                islandSize = new Size(islandSize.Width + (size.Width - islandSize.Width) * Math.Min(1, dt * 10), islandSize.Height + (size.Height - islandSize.Height) * Math.Min(1, dt * 10));
            }
            islandGlowOpacity = Ease.Keys(t, new[] { 0, DropTime, DropTime + 0.15, FadeTime, FadeTime + 0.8 }, new[] { 0.0, 0, 1, 1, 0 });
            if (dropped)
            {
                var ir = IslandGlowRect();
                double d2 = Math.Sqrt(ir.Width * ir.Width + ir.Height * ir.Height);
                var c = new Point(ir.X + ir.Width / 2, ir.Y + ir.Height / 2);
                islandBrush = new ImageBrush(conic) { ViewportUnits = BrushMappingMode.Absolute, Viewport = new Rect(c.X - d2 / 2, c.Y - d2 / 2, d2, d2), Transform = new RotateTransform(angle, c.X, c.Y) };
            }

            // Redraw only the panes something moved in.
            var bounds = DynamicBounds();
            foreach (var p in panes)
            {
                bool hit = bounds.Any(b => b.IntersectsWith(p.Window.Region));
                if (hit || p.LastHit) p.Scene.InvalidateVisual();
                p.LastHit = hit;
            }
        }

        private Rect IslandGlowRect()
        {
            double top = 8 + drop.Value;
            return new Rect(W / 2 - islandSize.Width / 2 - IslandPad, top - IslandPad, islandSize.Width + IslandPad * 2, islandSize.Height + IslandPad * 2);
        }

        private List<Rect> DynamicBounds()
        {
            var list = new List<Rect>();
            if (reveal > 0 && glowOpacity > 0)
            {
                // The crisp line runs around the edge.
                list.Add(new Rect(0, 0, W, 4));
                list.Add(new Rect(0, H - 4, W, 4));
                list.Add(new Rect(0, 0, 4, H));
                list.Add(new Rect(W - 4, 0, 4, H));
            }
            if (flashOpacity > 0) list.Add(new Rect(W / 2 - 280, -280, 560, 560));
            if (wordOpacity > 0) list.Add(WordRect());
            if (dropped && islandGlowOpacity > 0) list.Add(IslandGlowRect());
            if (sparks.Count > 0)
            {
                double x0 = sparks.Min(s => s.X), x1 = sparks.Max(s => s.X), y0 = sparks.Min(s => s.Y), y1 = sparks.Max(s => s.Y);
                list.Add(new Rect(x0 - 20, y0 - 20, x1 - x0 + 40, y1 - y0 + 40));
            }
            return list;
        }

        private Rect WordRect()
            => new(W / 2 - wordSize.Width * wordScale / 2, wordY - wordSize.Height * wordScale / 2, wordSize.Width * wordScale, wordSize.Height * wordScale);

        private Spark TrailSpark(Point at)
        {
            double a = rng.NextDouble() * Math.PI * 2, speed = 190 + (rng.NextDouble() * 2 - 1) * 130;
            return new Spark
            {
                X = at.X + (rng.NextDouble() - 0.5) * 6, Y = at.Y + (rng.NextDouble() - 0.5) * 6,
                VX = Math.Cos(a) * speed, VY = Math.Sin(a) * speed,
                Life = 0.8 + (rng.NextDouble() * 2 - 1) * 0.4, Size = 48 * (0.22 + (rng.NextDouble() * 2 - 1) * 0.12),
                Shrink = 48 * 0.2, Fade = 1.1, Gravity = 160, Drag = 2.0, Color = rng.Next(4),
            };
        }

        private Spark BurstSpark(Point at)
        {
            double a = Math.PI / 2 + (rng.NextDouble() * 2 - 1) * 0.96, speed = 280 + (rng.NextDouble() * 2 - 1) * 160;
            return new Spark
            {
                X = at.X, Y = at.Y, VX = Math.Cos(a) * speed, VY = Math.Sin(a) * speed,
                Life = 1.1 + (rng.NextDouble() * 2 - 1) * 0.4, Size = 48 * (0.28 + (rng.NextDouble() * 2 - 1) * 0.15),
                Shrink = 48 * 0.18, Fade = 0.8, Gravity = 260, Drag = 1.5, Color = rng.Next(GlowKit.Intro.Length),
            };
        }

        // MARK: Geometry

        /// <summary>From the bottom centre up one side to the top centre.</summary>
        private Point[] HalfPath(bool left, double inset)
        {
            double x = left ? inset : W - inset;
            return new[] { new Point(W / 2, H - inset), new Point(x, H - inset), new Point(x, inset), new Point(W / 2, inset) };
        }

        private static double Length(Point[] pts)
        {
            double L = 0;
            for (int i = 1; i < pts.Length; i++) L += (pts[i] - pts[i - 1]).Length;
            return L;
        }

        private static Point PointAlong(Point[] pts, double fraction)
        {
            double target = Length(pts) * Math.Clamp(fraction, 0, 1);
            for (int i = 1; i < pts.Length; i++)
            {
                double seg = (pts[i] - pts[i - 1]).Length;
                if (target <= seg) return pts[i - 1] + (pts[i] - pts[i - 1]) * (target / Math.Max(seg, 1e-6));
                target -= seg;
            }
            return pts[^1];
        }

        private static StreamGeometry Partial(Point[] pts, double fraction)
        {
            var g = new StreamGeometry();
            double target = Length(pts) * Math.Clamp(fraction, 0, 1);
            using (var ctx = g.Open())
            {
                ctx.BeginFigure(pts[0], false, false);
                for (int i = 1; i < pts.Length; i++)
                {
                    double seg = (pts[i] - pts[i - 1]).Length;
                    if (target <= seg) { ctx.LineTo(pts[i - 1] + (pts[i] - pts[i - 1]) * (target / Math.Max(seg, 1e-6)), true, true); break; }
                    ctx.LineTo(pts[i], true, true);
                    target -= seg;
                }
            }
            g.Freeze();
            return g;
        }

        // MARK: Drawing (called for each pane, already translated to screen coordinates and clipped)

        private void Draw(DrawingContext dc, Rect region)
        {
            // Crisp line along the edge
            if (reveal > 0 && glowOpacity > 0)
            {
                dc.PushOpacity(glowOpacity);
                foreach (bool left in new[] { true, false })
                    dc.DrawGeometry(null, linePen, Partial(HalfPath(left, 1.25), reveal));
                dc.Pop();
            }

            // Island glow
            if (dropped && islandGlowOpacity > 0 && islandBrush != null)
            {
                var ir = IslandGlowRect();
                if (ir.IntersectsWith(region))
                {
                    dc.PushOpacity(islandGlowOpacity);
                    dc.PushOpacityMask(new ImageBrush(islandMask) { ViewportUnits = BrushMappingMode.Absolute, Viewport = ir });
                    dc.DrawRectangle(islandBrush, null, ir);
                    dc.Pop();
                    dc.Pop();
                }
            }

            // Flash where the flames meet
            if (flashOpacity > 0)
            {
                var fr = new Rect(W / 2 - 280, -280, 560, 560);
                if (fr.IntersectsWith(region))
                {
                    dc.PushOpacity(flashOpacity);
                    dc.DrawImage(flashSprite, fr);
                    dc.Pop();
                }
            }

            // Heads
            if (headOpacity > 0 && reveal < 1.001)
            {
                dc.PushOpacity(headOpacity);
                foreach (bool left in new[] { true, false })
                {
                    var p = PointAlong(HalfPath(left, 3), reveal);
                    var hr = new Rect(p.X - 45, p.Y - 45, 90, 90);
                    if (hr.IntersectsWith(region)) dc.DrawImage(headSprite, hr);
                }
                dc.Pop();
            }

            // Sparks
            foreach (var s in sparks)
            {
                double a = Math.Clamp(1 - s.Fade * s.Age, 0, 1);
                if (a <= 0.01 || s.Size <= 0.5) continue;
                var r = new Rect(s.X - s.Size / 2, s.Y - s.Size / 2, s.Size, s.Size);
                if (!r.IntersectsWith(region)) continue;
                dc.PushOpacity(a);
                dc.DrawImage(sparkSprites[s.Color % sparkSprites.Length], r);
                dc.Pop();
            }

            // Wordmark and its shine
            if (wordOpacity > 0)
            {
                var wr = WordRect();
                if (wr.IntersectsWith(region))
                {
                    dc.PushOpacity(wordOpacity);
                    dc.DrawImage(wordBloom, wr);
                    dc.DrawImage(wordFace, wr);
                    if (!double.IsNaN(shineX))
                    {
                        double s = wordScale, u = wordFont / 120;
                        dc.PushOpacityMask(new ImageBrush(wordFace) { ViewportUnits = BrushMappingMode.Absolute, Viewport = wr });
                        var c = new Point(wr.X + shineX * s, wr.Y + wr.Height / 2);
                        double sw = 110 * u * s, sh = wr.Height * 1.6;
                        dc.PushTransform(new RotateTransform(20, c.X, c.Y));
                        dc.DrawRectangle(shineBrush, null, new Rect(c.X - sw / 2, c.Y - sh / 2, sw, sh));
                        dc.Pop();
                        dc.Pop();
                    }
                    dc.Pop();
                }
            }
        }

        /// <summary>"Docky" in heavy type: a coloured bloom (blurred on the CPU at low resolution,
        /// which is far quicker than a WPF blur effect) and the letters themselves.</summary>
        private static (BitmapSource bloom, BitmapSource face, Size size) Wordmark(double fontSize)
        {
            var typeface = new Typeface(new FontFamily("Segoe UI Variable Display, Segoe UI"), FontStyles.Normal, FontWeights.Bold, FontStretches.Normal);
            var text = new FormattedText("Docky", CultureInfo.InvariantCulture, FlowDirection.LeftToRight, typeface, fontSize, Brushes.White, 1.0);
            double pad = fontSize * 0.8;
            var size = new Size(Math.Ceiling(text.WidthIncludingTrailingWhitespace + pad * 2), Math.Ceiling(text.Height + pad * 2));
            var geometry = text.BuildGeometry(new Point(pad, pad));
            geometry.Freeze();
            double u = fontSize / 120;

            // Bloom: the letters' coverage at quarter resolution, blurred three times with different radii.
            const double low = 0.25;
            int lw = (int)Math.Ceiling(size.Width * low), lh = (int)Math.Ceiling(size.Height * low);
            var shape = new DrawingVisual();
            using (var dc = shape.RenderOpen()) dc.DrawGeometry(Brushes.White, null, geometry);
            var coverage = new RenderTargetBitmap(lw, lh, 96 * low, 96 * low, PixelFormats.Pbgra32);
            coverage.Render(shape);
            var px = new byte[lw * lh * 4];
            coverage.CopyPixels(px, lw * 4, 0);
            var baseAlpha = new float[lw * lh];
            for (int i = 0; i < baseAlpha.Length; i++) baseAlpha[i] = px[i * 4 + 3] / 255f;
            double[] r = new double[baseAlpha.Length], g = new double[baseAlpha.Length], b = new double[baseAlpha.Length], a = new double[baseAlpha.Length];
            foreach (var (color, radius) in new[] { (GlowKit.Intro[0], 80.0), (GlowKit.Intro[2], 44.0), (GlowKit.Intro[1], 20.0) })
            {
                var layer = (float[])baseAlpha.Clone();
                GlowKit.Blur(layer, lw, lh, Math.Max(1, (int)Math.Round(radius * u * low * 0.55)));
                for (int i = 0; i < layer.Length; i++)
                {
                    double v = Math.Min(1, layer[i] * 1.6) * 0.8;
                    // "Screen" the layers together so overlaps brighten without clipping harshly.
                    r[i] = 1 - (1 - r[i]) * (1 - color.R / 255.0 * v);
                    g[i] = 1 - (1 - g[i]) * (1 - color.G / 255.0 * v);
                    b[i] = 1 - (1 - b[i]) * (1 - color.B / 255.0 * v);
                    a[i] = 1 - (1 - a[i]) * (1 - v);
                }
            }
            var out_ = new byte[lw * lh * 4];
            for (int i = 0; i < a.Length; i++)
            {
                double alpha = a[i];
                out_[i * 4] = (byte)(Math.Min(alpha, b[i]) * 255);
                out_[i * 4 + 1] = (byte)(Math.Min(alpha, g[i]) * 255);
                out_[i * 4 + 2] = (byte)(Math.Min(alpha, r[i]) * 255);
                out_[i * 4 + 3] = (byte)(alpha * 255);
            }
            var bloom = BitmapSource.Create(lw, lh, 96 * low, 96 * low, PixelFormats.Pbgra32, null, out_, lw * 4);
            bloom.Freeze();

            // Face: crisp letters with a soft vertical tint, at 2x.
            const double scale = 2;
            var faceBrush = new LinearGradientBrush(new GradientStopCollection
            {
                new(Colors.White, 0), new(Color.FromRgb(235, 230, 255), 0.6), new(Color.FromRgb(255, 219, 242), 1),
            }, new Point(0.5, 0), new Point(0.5, 1));
            var face = new DrawingVisual();
            using (var dc = face.RenderOpen())
            {
                dc.DrawRectangle(Brushes.Transparent, null, new Rect(size));
                dc.DrawGeometry(faceBrush, null, geometry);
            }
            var faceBitmap = new RenderTargetBitmap((int)(size.Width * scale), (int)(size.Height * scale), 96 * scale, 96 * scale, PixelFormats.Pbgra32);
            faceBitmap.Render(face);
            faceBitmap.Freeze();
            return (bloom, faceBitmap, size);
        }
    }
}
