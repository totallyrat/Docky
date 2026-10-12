using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using Docky.Core;

namespace Docky.Island
{
    /// <summary>Hover highlight, a springy press, and a Click event for any Border.</summary>
    public class Pressable : Border
    {
        public event Action Click;
        private readonly ScaleTransform scale = new(1, 1);
        public Brush Normal { get; set; } = Brushes.Transparent;
        public Brush Hover { get; set; } = Theme.White(0.12);
        public double PressScale { get; set; } = 0.88;
        private bool down;

        public Pressable()
        {
            RenderTransform = scale;
            RenderTransformOrigin = new Point(0.5, 0.5);
            Cursor = Cursors.Hand;
            Loaded += (_, _) => Background = Normal;
            MouseEnter += (_, _) => Background = Hover;
            MouseLeave += (_, _) => { Background = Normal; Release(); };
            MouseLeftButtonDown += (_, e) => { down = true; Press(PressScale); CaptureMouse(); e.Handled = true; };
            MouseLeftButtonUp += (_, e) =>
            {
                bool inside = IsMouseOver;
                ReleaseMouseCapture();
                if (down && inside) Click?.Invoke();
                down = false;
                Release();
                e.Handled = true;
            };
        }

        private void Press(double to)
        {
            Anim.To(scale, ScaleTransform.ScaleXProperty, to, 90);
            Anim.To(scale, ScaleTransform.ScaleYProperty, to, 90);
        }

        private void Release()
        {
            var ease = new ElasticEase { Oscillations = 1, Springiness = 6, EasingMode = EasingMode.EaseOut };
            Anim.To(scale, ScaleTransform.ScaleXProperty, 1, 380, ease);
            Anim.To(scale, ScaleTransform.ScaleYProperty, 1, 380, ease);
        }
    }

    public static class UI
    {
        public static Pressable IconButton(string glyph, double size, Brush fg, Action click,
                                           Brush background = null, double diameter = 0, string tip = null)
        {
            double d = diameter > 0 ? diameter : size * 2.2;
            var b = new Pressable
            {
                Width = d, Height = d, CornerRadius = new CornerRadius(d / 2),
                Child = Theme.Glyph(glyph, size, fg),
                Normal = background ?? Brushes.Transparent,
                Hover = background != null ? Lighten(background) : Theme.White(0.12),
                ToolTip = tip,
            };
            b.Click += click;
            return b;
        }

        public static Pressable Pill(string text, Color tint, Action click, bool filled = false, string glyph = null, double height = 32)
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
            var fg = filled ? Brushes.Black : Theme.Brush(tint);
            if (glyph != null) { var g = Theme.Glyph(glyph, 11, fg); g.Margin = new Thickness(0, 0, 6, 0); row.Children.Add(g); }
            row.Children.Add(Theme.Text(text, 13, FontWeights.SemiBold, fg));
            var b = new Pressable
            {
                Height = height, Padding = new Thickness(14, 0, 14, 0), CornerRadius = new CornerRadius(height / 2),
                Child = row, PressScale = 0.93,
                Normal = filled ? Theme.Brush(tint) : Theme.Brush(tint, 0.22),
                Hover = filled ? Theme.Brush(Blend(tint, Colors.White, 0.15)) : Theme.Brush(tint, 0.32),
            };
            b.Click += click;
            return b;
        }

        public static Pressable Chip(string text, Color tint, Action click, bool selected = false)
        {
            var b = new Pressable
            {
                Height = 26, Padding = new Thickness(11, 0, 11, 0), CornerRadius = new CornerRadius(13), PressScale = 0.9,
                Child = Theme.Text(text, 12, FontWeights.SemiBold, selected ? Brushes.Black : Theme.Brush(tint, 0.9)),
                Normal = selected ? Theme.Brush(tint) : Theme.White(0.09),
                Hover = selected ? Theme.Brush(tint) : Theme.White(0.16),
            };
            b.Click += click;
            return b;
        }

        public static Color Blend(Color a, Color b, double t)
            => Color.FromRgb((byte)(a.R + (b.R - a.R) * t), (byte)(a.G + (b.G - a.G) * t), (byte)(a.B + (b.B - a.B) * t));

        private static Brush Lighten(Brush b)
        {
            if (b is SolidColorBrush s)
            {
                var c = s.Color;
                return new SolidColorBrush(Color.FromArgb((byte)Math.Min(255, c.A + 30), c.R, c.G, c.B));
            }
            return b;
        }

        public static Border Card(UIElement child, double radius = 16, double padding = 14)
            => new()
            {
                Background = Theme.White(0.06),
                CornerRadius = new CornerRadius(radius),
                Padding = new Thickness(padding),
                Child = child,
            };

        public static Border Artwork(ImageSource image, double size, double radius)
        {
            var b = new Border { Width = size, Height = size, CornerRadius = new CornerRadius(radius) };
            if (image != null)
                b.Background = new ImageBrush(image) { Stretch = Stretch.UniformToFill };
            else
            {
                b.Background = new LinearGradientBrush(Color.FromRgb(70, 70, 76), Color.FromRgb(40, 40, 44), 90);
                b.Child = Theme.Glyph(G.Music, size * 0.42, Theme.White(0.55));
            }
            return b;
        }

        public static FrameworkElement Spacer() => new Border { Width = 0 };
    }

    /// <summary>A capsule toggle in the iOS style.</summary>
    public class ToggleSwitch : Border
    {
        private readonly Ellipse knob = new() { Width = 18, Height = 18, Fill = Brushes.White };
        private readonly TranslateTransform shift = new();
        private bool on;
        public event Action<bool> Toggled;
        private Color tint = Theme.Green;
        public Color Tint { get => tint; set { tint = value; Apply(false); } }

        public ToggleSwitch(bool isOn)
        {
            on = isOn;
            Width = 40; Height = 22; CornerRadius = new CornerRadius(11); Cursor = Cursors.Hand;
            knob.HorizontalAlignment = HorizontalAlignment.Left;
            knob.Margin = new Thickness(2, 0, 0, 0);
            knob.RenderTransform = shift;
            knob.Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 4, ShadowDepth = 1, Opacity = 0.25 };
            Child = knob;
            Apply(false);
            MouseLeftButtonUp += (_, e) => { on = !on; Apply(true); Toggled?.Invoke(on); e.Handled = true; };
        }

        public bool IsOn { get => on; set { on = value; Apply(true); } }

        private void Apply(bool animate)
        {
            var bg = on ? Theme.Brush(Tint) : Theme.White(0.18);
            Background = bg;
            if (animate)
                Anim.To(shift, TranslateTransform.XProperty, on ? 18 : 0, 260,
                        new BackEase { Amplitude = 0.4, EasingMode = EasingMode.EaseOut });
            else shift.X = on ? 18 : 0;
        }
    }

    /// <summary>Progress bar used by the volume/brightness indicator and the media scrubber.</summary>
    public class LevelBar : Grid
    {
        private readonly Border fill;
        private readonly ScaleTransform scale = new(0, 1);
        private double level;

        public LevelBar(Brush fillBrush, double height = 6)
        {
            Height = height;
            Children.Add(new Border { Background = Theme.White(0.18), CornerRadius = new CornerRadius(height / 2) });
            fill = new Border { Background = fillBrush, CornerRadius = new CornerRadius(height / 2), RenderTransform = scale };
            Children.Add(fill);
        }

        public void SetLevel(double value, bool animate = true)
        {
            level = Math.Clamp(value, 0, 1);
            if (animate) Anim.To(scale, ScaleTransform.ScaleXProperty, level, 160);
            else { scale.BeginAnimation(ScaleTransform.ScaleXProperty, null); scale.ScaleX = level; }
        }

        public double Level => level;
        public void SetThickness(double h) { Height = h; foreach (Border b in Children) b.CornerRadius = new CornerRadius(h / 2); }
    }

    /// <summary>A circular progress ring.</summary>
    public class Ring : FrameworkElement
    {
        private double progress;
        private readonly Pen track, arc;

        public Ring(Color color, double thickness)
        {
            track = new Pen(Theme.Brush(color, 0.25), thickness);
            arc = new Pen(Theme.Brush(color), thickness) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round };
        }

        public double Progress { get => progress; set { progress = Math.Clamp(value, 0, 1); InvalidateVisual(); } }

        protected override void OnRender(DrawingContext dc)
        {
            double t = track.Thickness;
            var r = Math.Min(ActualWidth, ActualHeight) / 2 - t / 2;
            var c = new Point(ActualWidth / 2, ActualHeight / 2);
            dc.DrawEllipse(null, track, c, r, r);
            if (progress <= 0.001) return;
            if (progress >= 0.999) { dc.DrawEllipse(null, arc, c, r, r); return; }
            double angle = progress * 360;
            var start = new Point(c.X, c.Y - r);
            double rad = (angle - 90) * Math.PI / 180;
            var end = new Point(c.X + r * Math.Cos(rad), c.Y + r * Math.Sin(rad));
            var g = new StreamGeometry();
            using (var ctx = g.Open())
            {
                ctx.BeginFigure(start, false, false);
                ctx.ArcTo(end, new Size(r, r), 0, angle > 180, SweepDirection.Clockwise, true, false);
            }
            dc.DrawGeometry(null, arc, g);
        }
    }

    /// <summary>The "now playing" waveform: bars that wander while playing and settle when paused.</summary>
    public class Equalizer : StackPanel
    {
        private readonly List<ScaleTransform> bars = new();
        private static readonly Random rng = new();

        public Equalizer(Color color, int count = 4, double barWidth = 3, double height = 14)
        {
            Orientation = Orientation.Horizontal;
            Height = height;
            VerticalAlignment = VerticalAlignment.Center;
            for (int i = 0; i < count; i++)
            {
                var s = new ScaleTransform(1, 0.2);
                bars.Add(s);
                Children.Add(new Rectangle
                {
                    Width = barWidth, Height = height, RadiusX = barWidth / 2, RadiusY = barWidth / 2,
                    Fill = Theme.Brush(color), Margin = new Thickness(i == 0 ? 0 : barWidth * 0.75, 0, 0, 0),
                    RenderTransform = s, RenderTransformOrigin = new Point(0.5, 0.5),
                });
            }
        }

        public void SetPlaying(bool playing)
        {
            for (int i = 0; i < bars.Count; i++)
            {
                var s = bars[i];
                if (!playing)
                {
                    s.BeginAnimation(ScaleTransform.ScaleYProperty, new DoubleAnimation(0.2, TimeSpan.FromMilliseconds(300)) { EasingFunction = Anim.EaseOut });
                    continue;
                }
                var a = new DoubleAnimationUsingKeyFrames { RepeatBehavior = RepeatBehavior.Forever };
                double t = 0;
                for (int k = 0; k < 8; k++)
                {
                    t += 0.16 + rng.NextDouble() * 0.12;
                    a.KeyFrames.Add(new EasingDoubleKeyFrame(0.25 + rng.NextDouble() * 0.75, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(t)))
                    { EasingFunction = Anim.EaseInOut });
                }
                a.KeyFrames.Add(new EasingDoubleKeyFrame(0.5, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(t + 0.18))));
                Timeline.SetDesiredFrameRate(a, 30);
                s.BeginAnimation(ScaleTransform.ScaleYProperty, a);
            }
        }
    }

    /// <summary>A big two-digit number you can scroll, drag or click the chevrons of.</summary>
    public class Dial : StackPanel
    {
        private readonly TextBlock number;
        private int value;
        private readonly int min, max;
        private readonly string format;
        public event Action<int> Changed;
        private double accumulator;
        private Point? dragStart;
        private int dragBase;

        public Dial(int value, int min, int max, Color tint, double fontSize = 36, string unit = null, string format = "00")
        {
            this.value = value; this.min = min; this.max = max; this.format = format;
            Orientation = Orientation.Vertical;
            var up = UI.IconButton(G.Up, 9, Theme.White(0.35), () => Set(this.value + 1), diameter: 20);
            var down = UI.IconButton(G.Down, 9, Theme.White(0.35), () => Set(this.value - 1), diameter: 20);
            up.HorizontalAlignment = down.HorizontalAlignment = HorizontalAlignment.Center;
            number = Theme.Text(value.ToString(format), fontSize, FontWeights.SemiBold, Theme.Brush(tint), display: true);
            var row = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center, Background = Brushes.Transparent, Cursor = Cursors.SizeNS };
            row.Children.Add(number);
            if (unit != null)
            {
                var u = Theme.Text(unit, fontSize * 0.36, FontWeights.SemiBold, Theme.White(0.45));
                u.VerticalAlignment = VerticalAlignment.Bottom;
                u.Margin = new Thickness(2, 0, 0, fontSize * 0.18);
                row.Children.Add(u);
            }
            row.MouseWheel += (_, e) =>
            {
                accumulator += e.Delta;
                while (accumulator >= 60) { accumulator -= 60; Set(this.value + 1); }
                while (accumulator <= -60) { accumulator += 60; Set(this.value - 1); }
                e.Handled = true;
            };
            row.MouseLeftButtonDown += (_, e) => { dragStart = e.GetPosition(this); dragBase = this.value; row.CaptureMouse(); e.Handled = true; };
            row.MouseMove += (_, e) =>
            {
                if (dragStart is not Point p) return;
                int steps = (int)Math.Round((p.Y - e.GetPosition(this).Y) / 14);
                Set(dragBase + steps);
            };
            row.MouseLeftButtonUp += (_, e) => { dragStart = null; row.ReleaseMouseCapture(); e.Handled = true; };
            Children.Add(up);
            Children.Add(row);
            Children.Add(down);
        }

        public int Value => value;

        private void Set(int v)
        {
            int span = max - min + 1;
            if (v > max || v < min) v = ((v - min) % span + span) % span + min;
            if (v == value) return;
            bool upward = v > value;
            value = v;
            // Rolling digit: slide the old value out and the new one in.
            var shift = new TranslateTransform(0, upward ? 10 : -10);
            number.RenderTransform = shift;
            number.Text = v.ToString(format);
            number.Opacity = 0.3;
            Anim.To(shift, TranslateTransform.YProperty, 0, 220);
            Anim.To(number, OpacityProperty, 1, 220);
            Changed?.Invoke(v);
        }
    }

    /// <summary>Single-line text that scrolls when it doesn't fit.</summary>
    public class Marquee : Canvas
    {
        private readonly TextBlock a, b;
        private readonly TranslateTransform move = new();
        private const double Gap = 36;

        public Marquee(string text, double size, FontWeight weight, Brush brush)
        {
            ClipToBounds = true;
            a = Theme.Text(text, size, weight, brush);
            b = Theme.Text(text, size, weight, brush);
            a.TextTrimming = b.TextTrimming = TextTrimming.None;
            var row = new StackPanel { Orientation = Orientation.Horizontal, RenderTransform = move };
            row.Children.Add(a);
            row.Children.Add(b);
            Children.Add(row);
            SizeChanged += (_, _) => Restart(row);
            Loaded += (_, _) => Restart(row);
        }

        private void Restart(StackPanel row)
        {
            a.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            double w = a.DesiredSize.Width;
            SetTop(row, Math.Max(0, (ActualHeight - a.DesiredSize.Height) / 2));
            move.BeginAnimation(TranslateTransform.XProperty, null);
            if (w <= ActualWidth + 0.5 || ActualWidth <= 0)
            {
                b.Visibility = Visibility.Collapsed;
                move.X = Math.Max(0, (ActualWidth - w) / 2);
                return;
            }
            b.Visibility = Visibility.Visible;
            b.Margin = new Thickness(Gap, 0, 0, 0);
            double travel = w + Gap;
            var anim = new DoubleAnimationUsingKeyFrames { RepeatBehavior = RepeatBehavior.Forever };
            double scroll = travel / 28;
            anim.KeyFrames.Add(new DiscreteDoubleKeyFrame(0, KeyTime.FromTimeSpan(TimeSpan.Zero)));
            anim.KeyFrames.Add(new DiscreteDoubleKeyFrame(0, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(2))));
            anim.KeyFrames.Add(new LinearDoubleKeyFrame(-travel, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(2 + scroll))));
            Timeline.SetDesiredFrameRate(anim, 30);
            move.BeginAnimation(TranslateTransform.XProperty, anim);
        }
    }

    /// <summary>Pill segmented control with a sliding highlight.</summary>
    public class Segments : Border
    {
        private readonly Grid grid = new();
        private readonly Border highlight;
        private readonly TranslateTransform slide = new();
        private readonly List<TextBlock> labels = new();
        private int index;
        public event Action<int> Changed;
        private readonly double itemWidth;
        private readonly bool light;

        public Segments(string[] items, int selected, double itemWidth = 84, bool light = true)
        {
            this.itemWidth = itemWidth; this.light = light; index = selected;
            Background = Theme.White(0.1);
            CornerRadius = new CornerRadius(15);
            Padding = new Thickness(2);
            highlight = new Border
            {
                Width = itemWidth, Height = 26, CornerRadius = new CornerRadius(13),
                Background = light ? Brushes.White : Theme.White(0.16),
                HorizontalAlignment = HorizontalAlignment.Left, RenderTransform = slide,
            };
            grid.Children.Add(highlight);
            var row = new StackPanel { Orientation = Orientation.Horizontal };
            for (int i = 0; i < items.Length; i++)
            {
                int captured = i;
                var label = Theme.Text(items[i], 12, FontWeights.SemiBold, Brushes.White);
                label.HorizontalAlignment = HorizontalAlignment.Center;
                labels.Add(label);
                var cell = new Border { Width = itemWidth, Height = 26, Background = Brushes.Transparent, Child = label, Cursor = Cursors.Hand };
                cell.MouseLeftButtonUp += (_, e) => { Select(captured, true); Changed?.Invoke(captured); e.Handled = true; };
                row.Children.Add(cell);
            }
            grid.Children.Add(row);
            Child = grid;
            Select(selected, false);
        }

        public void Select(int i, bool animate)
        {
            index = i;
            if (animate)
                Anim.To(slide, TranslateTransform.XProperty, i * itemWidth, 320, new BackEase { Amplitude = 0.3, EasingMode = EasingMode.EaseOut });
            else slide.X = i * itemWidth;
            for (int k = 0; k < labels.Count; k++)
                labels[k].Foreground = k == i ? (light ? Brushes.Black : Brushes.White) : Theme.White(0.6);
        }
    }

    public static class Imaging
    {
        /// <summary>Average colour of an image, lifted so it reads well on black.</summary>
        public static Color Accent(BitmapSource source)
        {
            try
            {
                var small = new TransformedBitmap(new FormatConvertedBitmap(source, PixelFormats.Bgra32, null, 0),
                    new ScaleTransform(12.0 / source.PixelWidth, 12.0 / source.PixelHeight));
                int w = small.PixelWidth, h = small.PixelHeight;
                var px = new byte[w * h * 4];
                small.CopyPixels(px, w * 4, 0);
                double r = 0, g = 0, b = 0, total = 0;
                for (int i = 0; i < w * h; i++)
                {
                    double pb = px[i * 4] / 255.0, pg = px[i * 4 + 1] / 255.0, pr = px[i * 4 + 2] / 255.0;
                    double mx = Math.Max(pr, Math.Max(pg, pb)), mn = Math.Min(pr, Math.Min(pg, pb));
                    double sat = mx == 0 ? 0 : (mx - mn) / mx;
                    double weight = 0.15 + sat * sat * 2 + mx * 0.3;
                    r += pr * weight; g += pg * weight; b += pb * weight; total += weight;
                }
                if (total <= 0) return Colors.White;
                r /= total; g /= total; b /= total;
                double max = Math.Max(r, Math.Max(g, b)), min = Math.Min(r, Math.Min(g, b));
                if (max - min < 0.08) return Color.FromRgb(235, 235, 235);
                double lift = max < 0.78 ? 0.78 / max : 1;
                return Color.FromRgb((byte)Math.Min(255, r * lift * 255), (byte)Math.Min(255, g * lift * 255), (byte)Math.Min(255, b * lift * 255));
            }
            catch { return Colors.White; }
        }
    }
}
