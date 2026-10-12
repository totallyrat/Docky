using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using Docky.Core;

namespace Docky.Island
{
    /// <summary>
    /// Setup walkthrough that happens inside the island. Every choice is saved immediately and
    /// the island demonstrates it on itself (it shrinks to the compact look and springs back).
    /// </summary>
    public static class Onboarding
    {
        public const int StepCount = 7;
        private static readonly double[] Heights = { 214, 250, 236, 236, 262, 262, 262 };
        public static double Height(int step) => Heights[Math.Clamp(step, 0, Heights.Length - 1)];
        private static Settings S => SettingsStore.Current;

        public static FrameworkElement Build(IslandWindow w, int step)
        {
            var root = new DockPanel { Margin = new Thickness(26, 18, 26, 20), LastChildFill = true };

            // Header: label and progress dots
            var header = new Grid { Height = 14 };
            var label = Theme.Text("DOCKY SETUP", 10, FontWeights.Bold, Theme.White(0.35));
            header.Children.Add(label);
            var dots = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center };
            for (int i = 0; i < StepCount; i++)
            {
                var dot = new Border { Height = 6, Width = i == step ? 18 : 6, CornerRadius = new CornerRadius(3), Margin = new Thickness(5, 0, 0, 0), Background = Theme.White(i <= step ? 0.9 : 0.18) };
                if (i == step)
                {
                    dot.Width = 6;
                    dot.Loaded += (_, _) => Anim.To(dot, FrameworkElement.WidthProperty, 18, 360, new BackEase { Amplitude = 0.4, EasingMode = EasingMode.EaseOut });
                }
                dots.Children.Add(dot);
            }
            header.Children.Add(dots);
            DockPanel.SetDock(header, Dock.Top);
            root.Children.Add(header);

            // Footer: navigation
            var controls = new Grid { Margin = new Thickness(0, 10, 0, 0) };
            if (step == 0)
            {
                var skip = Theme.Text("Skip Setup", 12.5, FontWeights.SemiBold, Theme.White(0.45));
                skip.Cursor = System.Windows.Input.Cursors.Hand;
                skip.Background = Brushes.Transparent;
                skip.MouseLeftButtonUp += (_, e) => { w.FinishOnboarding(); e.Handled = true; };
                controls.Children.Add(skip);
            }
            else if (step < StepCount - 1)
                controls.Children.Add(Button("Back", false, () => w.OnboardingGo(-1)));
            string primary = step == 0 ? "Let's Go" : step == StepCount - 1 ? "Done" : "Continue";
            var next = Button(primary, true, () => w.OnboardingGo(1));
            next.HorizontalAlignment = HorizontalAlignment.Right;
            controls.Children.Add(next);
            DockPanel.SetDock(controls, Dock.Bottom);
            root.Children.Add(controls);

            FrameworkElement page = step switch
            {
                0 => Welcome(),
                1 => Shape(w),
                2 => Motion(w),
                3 => Gestures(),
                4 => Features(),
                5 => FitIn(),
                _ => Done(),
            };
            page.Margin = new Thickness(0, 12, 0, 0);
            page.VerticalAlignment = VerticalAlignment.Top;
            root.Children.Add(page);
            return root;
        }

        // MARK: Pieces

        private static Pressable Button(string title, bool prominent, Action click)
        {
            var b = new Pressable
            {
                Height = 32, Padding = new Thickness(prominent ? 20 : 15, 0, prominent ? 20 : 15, 0), CornerRadius = new CornerRadius(16),
                Child = Theme.Text(title, 13, FontWeights.SemiBold, prominent ? Brushes.Black : Theme.White(0.85)),
                Normal = prominent ? Brushes.White : Theme.White(0.11),
                Hover = prominent ? Theme.Brush(Color.FromRgb(232, 232, 232)) : Theme.White(0.18),
                PressScale = 0.93, HorizontalAlignment = HorizontalAlignment.Left,
            };
            b.Click += click;
            return b;
        }

        private static FrameworkElement Title(string title, string subtitle)
        {
            var s = new StackPanel();
            s.Children.Add(Theme.Text(title, 22, FontWeights.Bold, Brushes.White, true));
            var sub = Theme.Text(subtitle, 12.5, FontWeights.Normal, Theme.White(0.55));
            sub.TextWrapping = TextWrapping.Wrap;
            sub.TextTrimming = TextTrimming.None;
            sub.Margin = new Thickness(0, 4, 0, 0);
            s.Children.Add(sub);
            return s;
        }

        private static Border Panel(UIElement child, double padding = 14)
            => new() { Background = Theme.White(0.06), CornerRadius = new CornerRadius(16), Padding = new Thickness(padding), Margin = new Thickness(0, 14, 0, 0), Child = child };

        private static FrameworkElement Toggle(string glyph, string title, bool value, Action<bool> set)
        {
            var g = new Grid { Height = 26, Margin = new Thickness(0, 2, 0, 2) };
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(22) });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var icon = Theme.Glyph(glyph, 12, Theme.White(0.7));
            icon.HorizontalAlignment = HorizontalAlignment.Left;
            g.Children.Add(icon);
            var t = Theme.Text(title, 12.5, FontWeights.Medium, Theme.White(0.88));
            Grid.SetColumn(t, 1);
            g.Children.Add(t);
            var sw = new ToggleSwitch(value) { LayoutTransform = new ScaleTransform(0.85, 0.85), VerticalAlignment = VerticalAlignment.Center };
            sw.Toggled += on => set(on);
            Grid.SetColumn(sw, 2);
            g.Children.Add(sw);
            return g;
        }

        private static Grid TwoColumns(IEnumerable<FrameworkElement> left, IEnumerable<FrameworkElement> right)
        {
            var g = new Grid();
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(18) });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            var l = new StackPanel(); foreach (var e in left) l.Children.Add(e);
            var r = new StackPanel(); foreach (var e in right) r.Children.Add(e);
            g.Children.Add(l);
            Grid.SetColumn(r, 2);
            g.Children.Add(r);
            return g;
        }

        // MARK: Steps

        private static FrameworkElement Welcome()
        {
            var g = new Grid { Margin = new Thickness(0, 6, 0, 0) };
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            var icon = new System.Windows.Controls.Image { Width = 84, Height = 84, Source = AppIcon(), VerticalAlignment = VerticalAlignment.Center };
            icon.Effect = new System.Windows.Media.Effects.DropShadowEffect { Color = Color.FromRgb(153, 115, 255), BlurRadius = 30, ShadowDepth = 0, Opacity = 0.7 };
            var rot = new RotateTransform(-4);
            icon.RenderTransform = rot;
            icon.RenderTransformOrigin = new Point(0.5, 0.5);
            var wave = new DoubleAnimation(-4, 4, TimeSpan.FromSeconds(1.6)) { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever, EasingFunction = Anim.EaseInOut };
            Timeline.SetDesiredFrameRate(wave, 30);
            rot.BeginAnimation(RotateTransform.AngleProperty, wave);
            g.Children.Add(icon);
            var title = Title("Hi, I'm Docky", "Your Dynamic Island for Windows. I'll show music, timers, reminders and more, right here at the top of your screen. Let's set me up together; it takes a minute.");
            title.Margin = new Thickness(18, 0, 0, 0);
            title.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(title, 1);
            g.Children.Add(title);
            return g;
        }

        public static BitmapSource AppIcon()
        {
            try
            {
                using var s = typeof(Onboarding).Assembly.GetManifestResourceStream("Docky.png");
                if (s == null) return null;
                var img = new BitmapImage();
                img.BeginInit();
                img.StreamSource = s;
                img.CacheOption = BitmapCacheOption.OnLoad;
                img.EndInit();
                img.Freeze();
                return img;
            }
            catch { return null; }
        }

        private static FrameworkElement Shape(IslandWindow w)
        {
            var s = new StackPanel();
            s.Children.Add(Title("Pick my size", "Drag the slider and I'll show you each change. You can always fine-tune it in Settings."));
            var inner = new StackPanel();

            var sizeRow = new Grid { Height = 30 };
            sizeRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            sizeRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            sizeRow.Children.Add(Theme.Text("Size", 12.5, FontWeights.Medium, Theme.White(0.75)));
            var sliderRow = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center };
            sliderRow.Children.Add(new Border { Width = 16, Height = 7, CornerRadius = new CornerRadius(3.5), Background = Theme.White(0.4), VerticalAlignment = VerticalAlignment.Center });
            var slider = new IslandSlider(0.8, 1.3, S.IslandScale) { Width = 240, Margin = new Thickness(10, 0, 10, 0) };
            slider.ValueChanged += v => SettingsStore.Update(x => x.IslandScale = Math.Round(v * 20) / 20);
            slider.Released += () => w.Demonstrate(0.05);
            sliderRow.Children.Add(slider);
            sliderRow.Children.Add(new Border { Width = 26, Height = 12, CornerRadius = new CornerRadius(6), Background = Theme.White(0.4), VerticalAlignment = VerticalAlignment.Center });
            Grid.SetColumn(sliderRow, 1);
            sizeRow.Children.Add(sliderRow);
            inner.Children.Add(sizeRow);

            inner.Children.Add(Toggle(G.Sparkle, "Grow a little when I point at it", S.HoverGrow, on => SettingsStore.Update(x => x.HoverGrow = on)));

            var show = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Cursor = System.Windows.Input.Cursors.Hand, Background = Brushes.Transparent, Margin = new Thickness(0, 4, 0, 0) };
            show.Children.Add(Theme.Glyph(G.Eye, 11, Theme.White(0.7)));
            var showText = Theme.Text("Show Me", 11.5, FontWeights.SemiBold, Theme.White(0.7));
            showText.Margin = new Thickness(6, 0, 0, 0);
            show.Children.Add(showText);
            show.MouseLeftButtonUp += (_, e) => { w.Demonstrate(0); e.Handled = true; };
            inner.Children.Add(show);
            s.Children.Add(Panel(inner));
            return s;
        }

        private static FrameworkElement Motion(IslandWindow w)
        {
            var s = new StackPanel();
            s.Children.Add(Title("How should I move?", "Click one and watch me. Every morph uses this spring."));
            var row = new UniformGrid { Columns = 3, Margin = new Thickness(-5, 14, -5, 0) };
            var options = new (string key, string title, string detail, string glyph)[]
            {
                ("smooth", "Smooth", "Calm and fluid, like iPhone.", G.Music),
                ("snappy", "Snappy", "Quick and precise.", G.Bolt),
                ("bouncy", "Bouncy", "Playful, with a little overshoot.", G.Sparkle),
            };
            var cards = new List<(Pressable card, string key, TextBlock[] texts, TextBlock icon)>();
            void Paint()
            {
                foreach (var (card, key, texts, icon) in cards)
                {
                    bool sel = S.AnimationFeel == key;
                    card.Normal = sel ? Brushes.White : Theme.White(0.07);
                    card.Hover = sel ? Brushes.White : Theme.White(0.12);
                    card.Background = card.Normal;
                    icon.Foreground = sel ? Brushes.Black : Theme.White(0.85);
                    texts[0].Foreground = sel ? Brushes.Black : Brushes.White;
                    texts[1].Foreground = sel ? Theme.Brush(Colors.Black, 0.6) : Theme.White(0.5);
                    var st = (ScaleTransform)((TransformGroup)card.LayoutTransform).Children[0];
                    Anim.To(st, ScaleTransform.ScaleXProperty, sel ? 1.03 : 1, 320, new BackEase { Amplitude = 0.5, EasingMode = EasingMode.EaseOut });
                    Anim.To(st, ScaleTransform.ScaleYProperty, sel ? 1.03 : 1, 320, new BackEase { Amplitude = 0.5, EasingMode = EasingMode.EaseOut });
                }
            }
            foreach (var o in options)
            {
                var content = new StackPanel();
                var icon = Theme.Glyph(o.glyph, 18, Brushes.White);
                icon.HorizontalAlignment = HorizontalAlignment.Left;
                content.Children.Add(icon);
                var t = Theme.Text(o.title, 14, FontWeights.SemiBold, Brushes.White);
                t.Margin = new Thickness(0, 6, 0, 0);
                content.Children.Add(t);
                var d = Theme.Text(o.detail, 11, FontWeights.Normal, Theme.White(0.5));
                d.TextWrapping = TextWrapping.Wrap;
                d.TextTrimming = TextTrimming.None;
                d.Margin = new Thickness(0, 6, 0, 0);
                content.Children.Add(d);
                var card = new Pressable
                {
                    CornerRadius = new CornerRadius(16), Padding = new Thickness(13), Height = 104, Margin = new Thickness(5, 0, 5, 0),
                    Child = content, PressScale = 0.95, LayoutTransform = new TransformGroup { Children = { new ScaleTransform(1, 1) } },
                };
                string key = o.key;
                card.Click += () =>
                {
                    SettingsStore.Update(x => x.AnimationFeel = key);
                    Paint();
                    w.Demonstrate(0.25);
                };
                cards.Add((card, key, new[] { t, d }, icon));
                row.Children.Add(card);
            }
            row.Loaded += (_, _) => Paint();
            s.Children.Add(row);
            return s;
        }

        private static FrameworkElement Gestures()
        {
            var s = new StackPanel();
            s.Children.Add(Title("Open me your way", "Point at me and scroll down, drag down, or just click. Move the mouse away to close me again."));
            s.Children.Add(Panel(TwoColumns(
                new[]
                {
                    Toggle(G.Down, "Scroll down to open", S.ScrollToOpen, on => SettingsStore.Update(x => x.ScrollToOpen = on)),
                    Toggle(G.Hand, "Click to open", S.ClickToOpen, on => SettingsStore.Update(x => x.ClickToOpen = on)),
                },
                new[]
                {
                    Toggle(G.Eye, "Open on hover", S.HoverToOpen, on => SettingsStore.Update(x => x.HoverToOpen = on)),
                    Toggle(G.Timer, "Timer bubble beside me", S.ShowTimerBubble, on => SettingsStore.Update(x => x.ShowTimerBubble = on)),
                })));
            return s;
        }

        private static FrameworkElement Features()
        {
            var s = new StackPanel();
            s.Children.Add(Title("What should I show?", "The most-used options. Everything else is in Docky Settings."));
            s.Children.Add(Panel(TwoColumns(
                new[]
                {
                    Toggle(G.Music, "Now Playing", S.NowPlayingEnabled, on => SettingsStore.Update(x => x.NowPlayingEnabled = on)),
                    Toggle(G.Headphones, "Only music", S.MusicOnly, on => SettingsStore.Update(x => x.MusicOnly = on)),
                    Toggle(G.List, "Song title", S.ShowTitle, on => SettingsStore.Update(x => x.ShowTitle = on)),
                    Toggle(G.Calendar, "Calendar tab", S.ShowCalendar, on => SettingsStore.Update(x => x.ShowCalendar = on)),
                },
                new[]
                {
                    Toggle(G.Volume, "Volume", S.HudVolume, on => SettingsStore.Update(x => x.HudVolume = on)),
                    Toggle(G.Brightness, "Brightness", S.HudBrightness, on => SettingsStore.Update(x => x.HudBrightness = on)),
                    Toggle(G.Open, "Hide in fullscreen", S.HideInFullscreen, on => SettingsStore.Update(x => x.HideInFullscreen = on)),
                    Toggle(G.Sparkle, "Intro at launch", S.PlayIntro, on => SettingsStore.Update(x => x.PlayIntro = on)),
                }), 12));
            return s;
        }

        private static FrameworkElement FitIn()
        {
            var s = new StackPanel();
            s.Children.Add(Title("Make me feel at home", "Let me take over a few things Windows usually does. You can change these any time."));
            var list = new StackPanel();
            list.Children.Add(Row(G.Volume, "Replace the volume pop-up", "The volume keys show me instead of Windows' flyout",
                S.ReplaceVolumeOverlay, on => SettingsStore.Update(x => x.ReplaceVolumeOverlay = on)));
            list.Children.Add(Row(G.Pause, "Auto-pause other media", "Starting something pauses whatever was playing",
                S.AutoPauseOthers, on => SettingsStore.Update(x => x.AutoPauseOthers = on)));
            list.Children.Add(Row(G.Power, "Start with Windows", "Be here every time you sign in",
                S.LaunchAtStartup, on => { SettingsStore.Update(x => x.LaunchAtStartup = on); SettingsStore.ApplyStartup(); }));
            s.Children.Add(Panel(list, 12));
            return s;
        }

        private static FrameworkElement Row(string glyph, string title, string detail, bool value, Action<bool> set)
        {
            var g = new Grid { Margin = new Thickness(0, 3, 0, 3) };
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            g.Children.Add(new Border { Width = 28, Height = 28, CornerRadius = new CornerRadius(8), Background = Theme.White(0.12), Child = Theme.Glyph(glyph, 12, Brushes.White) });
            var texts = new StackPanel { Margin = new Thickness(10, 0, 8, 0), VerticalAlignment = VerticalAlignment.Center };
            texts.Children.Add(Theme.Text(title, 13, FontWeights.SemiBold, Brushes.White));
            texts.Children.Add(Theme.Text(detail, 11, FontWeights.Normal, Theme.White(0.5)));
            Grid.SetColumn(texts, 1);
            g.Children.Add(texts);
            var sw = new ToggleSwitch(value) { VerticalAlignment = VerticalAlignment.Center, LayoutTransform = new ScaleTransform(0.85, 0.85) };
            sw.Toggled += on => set(on);
            Grid.SetColumn(sw, 2);
            g.Children.Add(sw);
            return g;
        }

        private static FrameworkElement Done()
        {
            var g = new Grid();
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            var badge = new Grid { Width = 70, Height = 70, VerticalAlignment = VerticalAlignment.Top };
            badge.Children.Add(new Border { CornerRadius = new CornerRadius(35), Background = Theme.Brush(Theme.Green, 0.2) });
            var check = Theme.Glyph(G.Check, 28, Theme.Brush(Theme.Green));
            var pop = new ScaleTransform(0.3, 0.3);
            check.RenderTransform = pop;
            check.RenderTransformOrigin = new Point(0.5, 0.5);
            badge.Children.Add(check);
            badge.Loaded += (_, _) =>
            {
                var ease = new ElasticEase { Oscillations = 1, Springiness = 4, EasingMode = EasingMode.EaseOut };
                Anim.To(pop, ScaleTransform.ScaleXProperty, 1, 600, ease, 80);
                Anim.To(pop, ScaleTransform.ScaleYProperty, 1, 600, ease, 80);
            };
            g.Children.Add(badge);

            var right = new StackPanel { Margin = new Thickness(18, 0, 0, 0) };
            right.Children.Add(Title("You're all set", "A few things to try:"));
            var tips = new (string glyph, string text)[]
            {
                (G.Down, "Scroll down on me to open"),
                (G.Clipboard, "Drag files onto me to keep them"),
                (G.Volume, "Point at the volume and scroll to change it"),
                (G.Focus, "Try Pomodoro in the Timers tab"),
            };
            for (int i = 0; i < tips.Length; i++)
            {
                var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, i == 0 ? 10 : 8, 0, 0), Opacity = 0 };
                var icon = Theme.Glyph(tips[i].glyph, 12, Theme.White(0.75));
                icon.Width = 18;
                row.Children.Add(icon);
                var t = Theme.Text(tips[i].text, 12.5, FontWeights.Normal, Theme.White(0.85));
                t.Margin = new Thickness(10, 0, 0, 0);
                row.Children.Add(t);
                var slide = new TranslateTransform(10, 0);
                row.RenderTransform = slide;
                int delay = 100 + i * 60;
                row.Loaded += (_, _) =>
                {
                    Anim.To(row, UIElement.OpacityProperty, 1, 380, delayMs: delay);
                    Anim.To(slide, TranslateTransform.XProperty, 0, 450, new BackEase { Amplitude = 0.3, EasingMode = EasingMode.EaseOut }, delay);
                };
                right.Children.Add(row);
            }
            Grid.SetColumn(right, 1);
            g.Children.Add(right);
            return g;
        }
    }

    /// <summary>A dark capsule slider for the island.</summary>
    public sealed class IslandSlider : Grid
    {
        private readonly double min, max;
        private double value;
        private readonly Border fill, knob;
        public event Action<double> ValueChanged;
        public event Action Released;

        public IslandSlider(double min, double max, double value)
        {
            this.min = min; this.max = max; this.value = Math.Clamp(value, min, max);
            Height = 22;
            Background = Brushes.Transparent;
            Cursor = System.Windows.Input.Cursors.Hand;
            Children.Add(new Border { Height = 4, CornerRadius = new CornerRadius(2), Background = Theme.White(0.18), VerticalAlignment = VerticalAlignment.Center });
            fill = new Border { Height = 4, CornerRadius = new CornerRadius(2), Background = Brushes.White, HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Center };
            Children.Add(fill);
            knob = new Border
            {
                Width = 18, Height = 18, CornerRadius = new CornerRadius(9), Background = Brushes.White, HorizontalAlignment = HorizontalAlignment.Left,
                Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 6, ShadowDepth = 1, Opacity = 0.35 },
            };
            Children.Add(knob);
            SizeChanged += (_, _) => Layout();
            MouseLeftButtonDown += (_, e) => { CaptureMouse(); SetFrom(e.GetPosition(this).X); e.Handled = true; };
            MouseMove += (_, e) => { if (IsMouseCaptured) SetFrom(e.GetPosition(this).X); };
            MouseLeftButtonUp += (_, e) => { if (!IsMouseCaptured) return; ReleaseMouseCapture(); Released?.Invoke(); e.Handled = true; };
        }

        private void SetFrom(double x)
        {
            double usable = Math.Max(1, ActualWidth - 18);
            value = min + Math.Clamp((x - 9) / usable, 0, 1) * (max - min);
            Layout();
            ValueChanged?.Invoke(value);
        }

        private void Layout()
        {
            double usable = Math.Max(0, ActualWidth - 18);
            double f = (value - min) / (max - min);
            knob.Margin = new Thickness(f * usable, 0, 0, 0);
            fill.Width = f * usable + 9;
        }
    }
}
