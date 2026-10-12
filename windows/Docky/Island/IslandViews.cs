using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using Docky.Core;
using Docky.Services;

namespace Docky.Island
{
    /// <summary>Builds what goes inside the island for each presentation.</summary>
    public static class IslandViews
    {
        public const double HeaderHeight = 16 + 31 + 14;
        public const double Side = 22;
        private static Settings S => SettingsStore.Current;

        // View state that changes the island's height.
        public static bool TimerComposerOpen;
        public static string Composing; // "reminder" | "alarm" | null
        public static DateTime SelectedDay = DateTime.Today;
        private static int lastTabIndex;

        public static double ContentHeight(IslandWindow w)
        {
            var clock = ClockService.Shared;
            switch (w.Tab)
            {
                case Tab.NowPlaying: return 150;
                case Tab.Timers:
                    if (w.TimersMode == "pomodoro") return 38 + (clock.Session == null ? 132 : 70);
                    if (clock.Timers.Count == 0 || TimerComposerOpen) return 38 + 118;
                    return 38 + Math.Min(clock.Timers.Count, 3) * 58 + 34;
                case Tab.Clipboard: return 136;
                default: return 204;
            }
        }

        public static FrameworkElement Build(IslandWindow w, Pres p)
        {
            var size = w.TargetSize;
            FrameworkElement view = p switch
            {
                Pres.Music => CompactMusic(w),
                Pres.Timer => CompactTimer(w),
                Pres.Pomodoro => CompactPomodoro(w),
                Pres.Hud => new HudView(w),
                Pres.Peek => Peek(w),
                Pres.Expanded => Expanded(w),
                Pres.Alert => Alert(w),
                Pres.Notice => Notice(w),
                Pres.Break => BreakCard(w),
                Pres.Onboarding => Onboarding.Build(w, w.OnboardingStep ?? 0),
                Pres.OnboardingDemo => OnboardingDemo(w),
                _ => new Grid(),
            };
            // The view's margin is its inset from the island's edge, so it sizes to what's left.
            var m = view.Margin;
            view.Width = Math.Max(0, size.Width - m.Left - m.Right);
            view.Height = Math.Max(0, size.Height - m.Top - m.Bottom);
            return view;
        }

        // MARK: Compact

        private static Grid Wings(IslandWindow w, UIElement left, UIElement center, UIElement right)
        {
            double inset = Math.Round(w.Band * 0.22) + 5;
            var g = new Grid { Margin = new Thickness(inset, 0, inset, 0) };
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            void Put(UIElement e, int col)
            {
                if (e == null) return;
                Grid.SetColumn(e, col);
                if (e is FrameworkElement fe) fe.VerticalAlignment = VerticalAlignment.Center;
                g.Children.Add(e);
            }
            Put(left, 0);
            if (center is FrameworkElement c) c.Margin = new Thickness(10, 0, 10, 0);
            Put(center, 1);
            Put(right, 2);
            return g;
        }

        private static double Art(IslandWindow w) => w.Band - Math.Round(w.Band * 0.22) * 2;

        private static FrameworkElement CompactMusic(IslandWindow w)
        {
            var m = MediaService.Shared.Current;
            double art = Art(w);
            var tint = S.TintFromArtwork && m != null ? m.Accent : Colors.White;
            var eq = new Equalizer(tint, 4, 2.6, art * 0.66);
            eq.Loaded += (_, _) => eq.SetPlaying(m?.IsPlaying == true);
            UIElement center = null;
            if (S.ShowTitle && m != null)
                center = new Marquee(m.Artist.Length > 0 ? $"{m.Title}  ·  {m.Artist}" : m.Title, 12.5, FontWeights.Medium, Theme.White(0.85)) { Height = 20 };
            return Wings(w, UI.Artwork(m?.Artwork, art, art * 0.3), center, new Border { Width = art, Child = eq });
        }

        private static FrameworkElement CompactTimer(IslandWindow w)
        {
            var t = ClockService.Shared.ActiveTimer;
            double ring = Art(w);
            var r = new Ring(Theme.Orange, 2.2) { Width = ring, Height = ring };
            var icon = Theme.Glyph(t?.IsRunning == true ? G.Timer : G.Pause, ring * 0.46, Theme.Brush(Theme.Orange));
            var left = new Grid { Width = ring, Height = ring };
            left.Children.Add(r); left.Children.Add(icon);
            var text = Theme.Text("", w.Band * 0.44, FontWeights.SemiBold, Theme.Brush(Theme.Orange));
            text.FontFamily = Theme.Display;
            var g = Wings(w, left, null, text);
            UiTicker.Attach(g, () =>
            {
                var cur = ClockService.Shared.ActiveTimer;
                if (cur == null) return;
                r.Progress = cur.Progress;
                text.Text = Theme.Clock(cur.Remaining, true);
                text.Opacity = cur.IsRunning ? 1 : 0.6;
            });
            return g;
        }

        private static FrameworkElement CompactPomodoro(IslandWindow w)
        {
            var s = ClockService.Shared.Session;
            var tint = s?.IsRest == true ? Theme.Rest : Theme.Focus;
            double ring = Art(w);
            var r = new Ring(tint, 2.2) { Width = ring, Height = ring };
            var left = new Grid { Width = ring, Height = ring };
            left.Children.Add(r);
            left.Children.Add(Theme.Glyph(s?.IsRunning == false ? G.Pause : (s?.IsRest == true ? G.Coffee : G.Focus), ring * 0.44, Theme.Brush(tint)));
            var text = Theme.Text("", w.Band * 0.44, FontWeights.SemiBold, Theme.Brush(tint));
            text.FontFamily = Theme.Display;
            var g = Wings(w, left, null, text);
            UiTicker.Attach(g, () =>
            {
                var cur = ClockService.Shared.Session;
                if (cur == null) return;
                r.Progress = cur.Progress;
                text.Text = Theme.Clock(cur.Remaining, true);
            });
            return g;
        }

        public static FrameworkElement Bubble(IslandWindow w)
        {
            double size = w.Band;
            var g = new Grid { Width = size, Height = size };
            var clock = ClockService.Shared;
            var tint = clock.Session != null ? (clock.Session.IsRest ? Theme.Rest : Theme.Focus) : Theme.Orange;
            var ring = new Ring(tint, 2) { Margin = new Thickness(size * 0.2) };
            g.Children.Add(ring);
            g.Children.Add(Theme.Glyph(clock.Session != null ? G.Focus : G.Timer, size * 0.24, Theme.Brush(tint)));
            UiTicker.Attach(g, () =>
            {
                if (clock.Session != null) ring.Progress = clock.Session.Progress;
                else if (clock.ActiveTimer != null) ring.Progress = clock.ActiveTimer.Progress;
            });
            return g;
        }

        private static FrameworkElement Peek(IslandWindow w)
        {
            var m = MediaService.Shared.Current;
            var g = new Grid { Margin = new Thickness(20, 0, 20, 0) };
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var art = UI.Artwork(m?.Artwork, 44, 11);
            art.VerticalAlignment = VerticalAlignment.Center;
            g.Children.Add(art);
            var texts = new StackPanel { Margin = new Thickness(12, 0, 10, 0), VerticalAlignment = VerticalAlignment.Center };
            texts.Children.Add(new Marquee(m?.Title ?? "", 14, FontWeights.SemiBold, Brushes.White) { Height = 19, Centered = false });
            texts.Children.Add(Theme.Text(m?.Artist ?? "", 12, FontWeights.Normal, Theme.White(0.55)));
            Grid.SetColumn(texts, 1);
            g.Children.Add(texts);
            var eq = new Equalizer(S.TintFromArtwork && m != null ? m.Accent : Colors.White, 5, 3, 18);
            eq.Loaded += (_, _) => eq.SetPlaying(m?.IsPlaying == true);
            Grid.SetColumn(eq, 2);
            g.Children.Add(eq);
            return g;
        }

        private static FrameworkElement OnboardingDemo(IslandWindow w)
        {
            double art = Art(w);
            var square = new Border
            {
                Width = art, Height = art, CornerRadius = new CornerRadius(art * 0.3),
                Background = new LinearGradientBrush(Color.FromRgb(255, 90, 140), Color.FromRgb(140, 76, 255), 45),
            };
            var eq = new Equalizer(Theme.Pink, 4, 2.6, art * 0.66);
            eq.Loaded += (_, _) => eq.SetPlaying(true);
            var label = S.ShowTitle ? Theme.Text("Looking good", 12.5, FontWeights.Medium, Theme.White(0.85)) : null;
            if (label != null) label.HorizontalAlignment = HorizontalAlignment.Center;
            return Wings(w, square, label, new Border { Width = art, Child = eq });
        }

        // MARK: Indicators

        /// <summary>Volume / brightness / status indicator. The level bar is a real slider.</summary>
        public sealed class HudView : Grid
        {
            private readonly IslandWindow w;
            private readonly TextBlock icon, title, detail, number;
            private readonly LevelBar bar;
            private Point? dragStart;
            private double dragBase;

            public HudView(IslandWindow w)
            {
                this.w = w;
                var e = w.Hud;
                double size = w.Band * 0.42;
                icon = Theme.Glyph(e?.Glyph ?? G.Volume, size, Brushes.White);
                icon.Width = w.Band * 0.72;
                title = Theme.Text("", 12.5, FontWeights.SemiBold, Theme.White(0.92));
                detail = Theme.Text("", 12.5, FontWeights.SemiBold, Brushes.White);
                number = Theme.Text("", 12, FontWeights.SemiBold, Theme.White(0.75));
                number.Width = 28;
                number.TextAlignment = TextAlignment.Right;
                bar = new LevelBar(Brushes.White, 6);
                bar.Cursor = Cursors.Hand;
                bar.Background = Brushes.Transparent;
                bar.MouseLeftButtonDown += (_, ev) => { w.SetAdjustingLevel(true); bar.CaptureMouse(); SetFromBar(ev); ev.Handled = true; };
                bar.MouseMove += (_, ev) => { if (bar.IsMouseCaptured) SetFromBar(ev); };
                bar.MouseLeftButtonUp += (_, ev) => { bar.ReleaseMouseCapture(); w.SetAdjustingLevel(false); ev.Handled = true; };

                bool level = e?.Level != null;
                var center = level ? (UIElement)new Border { Height = 18, Background = Brushes.Transparent, Child = bar } : title;
                Children.Add(Wings(w, icon, center, level ? number : detail));
                Background = Brushes.Transparent;

                // Click-drag anywhere on the indicator: up or right raises, down or left lowers.
                if (level)
                {
                    MouseLeftButtonDown += (_, ev) => { dragStart = ev.GetPosition(this); dragBase = w.Hud?.Level ?? 0; CaptureMouse(); w.SetAdjustingLevel(true); ev.Handled = true; };
                    MouseMove += (_, ev) =>
                    {
                        if (dragStart is not Point s || !IsMouseCaptured) return;
                        var d = ev.GetPosition(this) - s;
                        w.SetHudLevel(dragBase + (d.X - d.Y) / 160);
                    };
                    MouseLeftButtonUp += (_, ev) => { dragStart = null; ReleaseMouseCapture(); w.SetAdjustingLevel(false); ev.Handled = true; };
                    MouseEnter += (_, _) => bar.SetThickness(9);
                    MouseLeave += (_, _) => bar.SetThickness(6);
                }
                Update(e, animate: false);
            }

            private void SetFromBar(MouseEventArgs ev)
            {
                double x = ev.GetPosition(bar).X;
                w.SetHudLevel(x / Math.Max(1, bar.ActualWidth));
            }

            public void Update(HudEvent e, bool animate = true)
            {
                if (e == null) return;
                icon.Text = e.Glyph;
                if (e.Level is double l)
                {
                    bar.SetLevel(l, animate);
                    number.Text = Math.Round(l * 100).ToString();
                    icon.Foreground = Brushes.White;
                }
                else
                {
                    title.Text = e.Title;
                    detail.Text = e.Detail;
                    detail.Foreground = Theme.Brush(e.Tint == Colors.White ? Color.FromRgb(180, 180, 180) : e.Tint);
                    icon.Foreground = Theme.Brush(e.Tint == Colors.White ? Color.FromRgb(200, 200, 200) : e.Tint);
                }
            }
        }

        // MARK: Expanded

        /// <summary>The open island: a tab bar that stays put, and the current tab below it.</summary>
        public sealed class ExpandedView : DockPanel
        {
            public readonly Grid BodyHost = new() { Margin = new Thickness(0, 14, 0, 0) };
            public FrameworkElement HeaderView, Body;
        }

        private static FrameworkElement Expanded(IslandWindow w)
        {
            var view = new ExpandedView { Margin = new Thickness(Side, 16, Side, 20), LastChildFill = true };
            view.HeaderView = Header(w);
            DockPanel.SetDock(view.HeaderView, Dock.Top);
            view.Children.Add(view.HeaderView);
            view.Body = TabBody(w);
            view.BodyHost.Children.Add(view.Body);
            view.Children.Add(view.BodyHost);
            return view;
        }

        private static FrameworkElement TabBody(IslandWindow w) => w.Tab switch
        {
            Tab.NowPlaying => NowPlayingTab(w),
            Tab.Timers => TimersTab(w),
            Tab.Reminders => RemindersTab(w),
            Tab.Calendar => CalendarTab(w),
            _ => ClipboardTab(w),
        };

        /// <summary>Rebuilds the open island in place: the tab bar's highlight slides to the new
        /// tab, and the old tab's content fades out as the new one rises in.</summary>
        public static void UpdateExpanded(ExpandedView view, IslandWindow w, bool animate)
        {
            var size = w.TargetSize;
            var m = view.Margin;
            view.Width = Math.Max(0, size.Width - m.Left - m.Right);
            view.Height = Math.Max(0, size.Height - m.Top - m.Bottom);

            var header = Header(w);
            DockPanel.SetDock(header, Dock.Top);
            view.Children.Remove(view.HeaderView);
            view.Children.Insert(0, header);
            view.HeaderView = header;

            var old = view.Body;
            var next = TabBody(w);
            view.Body = next;
            next.VerticalAlignment = VerticalAlignment.Top;
            view.BodyHost.Children.Add(next);
            if (old == null) return;
            if (!animate)
            {
                view.BodyHost.Children.Remove(old);
                return;
            }
            old.IsHitTestVisible = false;
            old.VerticalAlignment = VerticalAlignment.Top;
            Anim.To(old, UIElement.OpacityProperty, 0, 120, done: () => view.BodyHost.Children.Remove(old));
            var rise = new TranslateTransform(0, 8);
            next.RenderTransform = rise;
            next.Opacity = 0;
            Anim.To(next, UIElement.OpacityProperty, 1, 240, delayMs: 60);
            Anim.To(rise, TranslateTransform.YProperty, 0, 320, new BackEase { Amplitude = 0.2, EasingMode = EasingMode.EaseOut }, 60);
        }

        private static FrameworkElement Header(IslandWindow w)
        {
            var tabs = new List<(Tab tab, string glyph, string tip)>
            {
                (Tab.NowPlaying, G.Music, "Now Playing"), (Tab.Timers, G.Timer, "Timers & Pomodoro"),
                (Tab.Reminders, G.Alarm, "Reminders & Alarms"),
            };
            if (S.ShowCalendar) tabs.Add((Tab.Calendar, G.Calendar, "Calendar"));
            tabs.Add((Tab.Clipboard, G.Clipboard, "Clipboard"));

            const double cell = 36;
            int index = Math.Max(0, tabs.FindIndex(t => t.tab == w.Tab));
            var slide = new TranslateTransform(lastTabIndex * cell, 0);
            var bar = new Grid { Height = 31 };
            var pillBack = new Border { Background = Theme.White(0.05), CornerRadius = new CornerRadius(15.5), Width = cell * tabs.Count + 4, HorizontalAlignment = HorizontalAlignment.Left };
            bar.Children.Add(pillBack);
            var highlight = new Border
            {
                Width = cell, Height = 27, CornerRadius = new CornerRadius(13.5), Background = Theme.White(0.15),
                HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(2, 0, 0, 0), RenderTransform = slide,
            };
            bar.Children.Add(highlight);
            var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(2, 0, 0, 0) };
            for (int i = 0; i < tabs.Count; i++)
            {
                var t = tabs[i];
                bool selected = i == index;
                var cellView = new Border
                {
                    Width = cell, Height = 27, Background = Brushes.Transparent, Cursor = Cursors.Hand, ToolTip = t.tip,
                    Child = Theme.Glyph(t.glyph, 13, selected ? Brushes.White : Theme.White(0.45)),
                };
                cellView.MouseLeftButtonUp += (_, e) => { lastTabIndex = index; w.SelectTab(t.tab); e.Handled = true; };
                row.Children.Add(cellView);
            }
            bar.Children.Add(row);
            Anim.To(slide, TranslateTransform.XProperty, index * cell, 380, new BackEase { Amplitude = 0.25, EasingMode = EasingMode.EaseOut });
            lastTabIndex = index;

            var right = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center };
            if (ClockService.Shared.NextAlarm is var (alarm, when) && alarm != null)
            {
                var a = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 6, 0), VerticalAlignment = VerticalAlignment.Center };
                a.Children.Add(Theme.Glyph(G.Alarm, 10, Theme.White(0.45)));
                var t = Theme.Text(Theme.Time(when), 11, FontWeights.SemiBold, Theme.White(0.45));
                t.Margin = new Thickness(4, 0, 0, 0);
                a.Children.Add(t);
                right.Children.Add(a);
            }
            right.Children.Add(UI.IconButton(G.Settings, 12, Theme.White(0.6), w.OpenSettings, tip: "Docky Settings"));

            var g = new Grid { Height = 31 };
            g.Children.Add(bar);
            g.Children.Add(right);
            return g;
        }

        // Now Playing

        private static FrameworkElement NowPlayingTab(IslandWindow w)
        {
            var media = MediaService.Shared;
            var m = media.Current;
            if (m == null)
            {
                return Empty(G.Music, "Not Playing", "Play something in Spotify, a browser or any media app.");
            }
            var tint = S.TintFromArtwork ? m.Accent : Colors.White;
            var root = new StackPanel();

            var top = new Grid();
            top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            top.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            top.Children.Add(UI.Artwork(m.Artwork, 62, 14));
            var texts = new StackPanel { Margin = new Thickness(14, 0, 8, 0), VerticalAlignment = VerticalAlignment.Center };
            texts.Children.Add(new Marquee(m.Title, 15, FontWeights.SemiBold, Brushes.White) { Height = 21, Centered = false });
            texts.Children.Add(Theme.Text(m.Artist.Length > 0 ? m.Artist : m.AppName, 13, FontWeights.Normal, Theme.White(0.55)));
            var app = Theme.Text(m.AppName, 10.5, FontWeights.SemiBold, Theme.White(0.35));
            app.Margin = new Thickness(0, 3, 0, 0);
            texts.Children.Add(app);
            Grid.SetColumn(texts, 1);
            top.Children.Add(texts);
            var eq = new Equalizer(tint, 5, 3, 20);
            eq.Loaded += (_, _) => eq.SetPlaying(m.IsPlaying);
            Grid.SetColumn(eq, 2);
            top.Children.Add(eq);
            root.Children.Add(top);

            // Scrubber
            var scrub = new Grid { Margin = new Thickness(0, 12, 0, 0) };
            scrub.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(44) });
            scrub.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            scrub.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(48) });
            var elapsed = Theme.Text("0:00", 11, FontWeights.Medium, Theme.White(0.5));
            elapsed.TextAlignment = TextAlignment.Right;
            var remaining = Theme.Text("", 11, FontWeights.Medium, Theme.White(0.5));
            remaining.Margin = new Thickness(10, 0, 0, 0);
            var bar = new LevelBar(Theme.White(0.85), 5) { Margin = new Thickness(10, 0, 0, 0), Cursor = Cursors.Hand, Background = Brushes.Transparent };
            bool scrubbing = false;
            void SeekFrom(MouseEventArgs e)
            {
                if (m.Duration <= 0) return;
                double f = Math.Clamp(e.GetPosition(bar).X / Math.Max(1, bar.ActualWidth), 0, 1);
                bar.SetLevel(f, false);
                elapsed.Text = Theme.Clock(f * m.Duration);
            }
            bar.MouseEnter += (_, _) => bar.SetThickness(8);
            bar.MouseLeave += (_, _) => { if (!scrubbing) bar.SetThickness(5); };
            bar.MouseLeftButtonDown += (_, e) => { scrubbing = true; bar.CaptureMouse(); SeekFrom(e); e.Handled = true; };
            bar.MouseMove += (_, e) => { if (scrubbing) SeekFrom(e); };
            bar.MouseLeftButtonUp += (_, e) =>
            {
                if (!scrubbing) return;
                scrubbing = false;
                bar.ReleaseMouseCapture();
                if (m.Duration > 0) media.Seek(bar.Level * m.Duration);
                e.Handled = true;
            };
            scrub.Children.Add(elapsed);
            Grid.SetColumn(bar, 1); scrub.Children.Add(bar);
            Grid.SetColumn(remaining, 2); scrub.Children.Add(remaining);
            root.Children.Add(scrub);
            UiTicker.Attach(scrub, () =>
            {
                var cur = media.Current;
                if (cur == null || scrubbing) return;
                double pos = cur.CurrentPosition;
                elapsed.Text = Theme.Clock(pos);
                remaining.Text = cur.Duration > 0 ? "-" + Theme.Clock(Math.Max(0, cur.Duration - pos)) : "--:--";
                bar.SetLevel(cur.Duration > 0 ? pos / cur.Duration : 0, false);
            });

            // Transport
            var controls = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 8, 0, 0) };
            var prev = UI.IconButton(G.Prev, 18, Brushes.White, media.Previous, diameter: 42);
            var play = UI.IconButton(m.IsPlaying ? G.Pause : G.Play, 24, Brushes.White, media.TogglePlayPause, diameter: 48);
            var next = UI.IconButton(G.Next, 18, Brushes.White, media.Next, diameter: 42);
            prev.Margin = new Thickness(0, 0, 30, 0);
            next.Margin = new Thickness(30, 0, 0, 0);
            controls.Children.Add(prev); controls.Children.Add(play); controls.Children.Add(next);
            root.Children.Add(controls);
            return root;
        }

        private static FrameworkElement Empty(string glyph, string title, string subtitle, FrameworkElement action = null)
        {
            var s = new StackPanel { VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center };
            s.Children.Add(Theme.Glyph(glyph, 24, Theme.White(0.3)));
            var t = Theme.Text(title, 14, FontWeights.SemiBold, Theme.White(0.75));
            t.HorizontalAlignment = HorizontalAlignment.Center;
            t.Margin = new Thickness(0, 8, 0, 2);
            s.Children.Add(t);
            var st = Theme.Text(subtitle, 11.5, FontWeights.Normal, Theme.White(0.42));
            st.HorizontalAlignment = HorizontalAlignment.Center;
            st.TextWrapping = TextWrapping.Wrap;
            st.TextAlignment = TextAlignment.Center;
            st.MaxWidth = 320;
            s.Children.Add(st);
            if (action != null) { action.Margin = new Thickness(0, 10, 0, 0); action.HorizontalAlignment = HorizontalAlignment.Center; s.Children.Add(action); }
            return s;
        }

        // Timers & Pomodoro

        private static FrameworkElement ModeBar(string[] items, int selected, Action<int> changed, FrameworkElement trailing = null)
        {
            var g = new Grid { Height = 28 };
            var seg = new Segments(items, selected, 96, light: false) { HorizontalAlignment = HorizontalAlignment.Left };
            seg.Changed += changed;
            g.Children.Add(seg);
            if (trailing != null) { trailing.HorizontalAlignment = HorizontalAlignment.Right; g.Children.Add(trailing); }
            return g;
        }

        private static FrameworkElement TimersTab(IslandWindow w)
        {
            var root = new DockPanel();
            var bar = ModeBar(new[] { "Timers", "Pomodoro" }, w.TimersMode == "pomodoro" ? 1 : 0, i => w.SetTimersMode(i == 1 ? "pomodoro" : "timers"));
            DockPanel.SetDock(bar, Dock.Top);
            root.Children.Add(bar);
            FrameworkElement body = w.TimersMode == "pomodoro" ? PomodoroPanel(w) : TimersPanel(w);
            body.Margin = new Thickness(0, 10, 0, 0);
            root.Children.Add(body);
            return root;
        }

        private static readonly (string, double)[] Presets = { ("1 min", 60), ("5 min", 300), ("10 min", 600), ("15 min", 900), ("30 min", 1800), ("1 hr", 3600) };

        private static FrameworkElement TimersPanel(IslandWindow w)
        {
            var clock = ClockService.Shared;
            if (clock.Timers.Count == 0 || TimerComposerOpen)
            {
                var root = new StackPanel();
                var row = new Grid();
                var dials = new StackPanel { Orientation = Orientation.Horizontal };
                var h = new Dial(0, 0, 23, Theme.Orange, 36, "h");
                var m = new Dial(5, 0, 59, Theme.Orange, 36, "m");
                var s = new Dial(0, 0, 59, Theme.Orange, 36, "s");
                dials.Children.Add(h); dials.Children.Add(Colon(Theme.Orange)); dials.Children.Add(m); dials.Children.Add(Colon(Theme.Orange)); dials.Children.Add(s);
                row.Children.Add(dials);
                var start = UI.IconButton(G.Play, 20, Brushes.Black, () =>
                {
                    clock.StartTimer(h.Value * 3600 + m.Value * 60 + s.Value);
                    TimerComposerOpen = false;
                    w.Rebuild();
                }, Theme.Brush(Theme.Orange), 52, "Start");
                start.HorizontalAlignment = HorizontalAlignment.Right;
                row.Children.Add(start);
                root.Children.Add(row);
                var chips = new WrapPanel { Margin = new Thickness(0, 10, 0, 0) };
                foreach (var (label, secs) in Presets)
                {
                    var c = UI.Chip(label, Theme.Orange, () => { clock.StartTimer(secs); TimerComposerOpen = false; w.Rebuild(); });
                    c.Margin = new Thickness(0, 0, 6, 0);
                    chips.Children.Add(c);
                }
                root.Children.Add(chips);
                return root;
            }

            var list = new StackPanel();
            foreach (var t in clock.Timers.Take(3))
            {
                var rowG = new Grid { Height = 52, Margin = new Thickness(0, 0, 0, 6) };
                var card = new Border { Background = Theme.White(0.045), CornerRadius = new CornerRadius(16), Padding = new Thickness(10, 0, 10, 0) };
                var inner = new Grid();
                inner.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                inner.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                inner.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                var ring = new Ring(Theme.Orange, 3.5) { Width = 30, Height = 30, VerticalAlignment = VerticalAlignment.Center };
                inner.Children.Add(ring);
                var texts = new StackPanel { Margin = new Thickness(12, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
                var time = Theme.Text("", 22, FontWeights.SemiBold, Theme.Brush(Theme.Orange), true);
                texts.Children.Add(time);
                texts.Children.Add(Theme.Text(t.Title, 11, FontWeights.Medium, Theme.White(0.45)));
                Grid.SetColumn(texts, 1);
                inner.Children.Add(texts);
                var buttons = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
                var toggle = UI.IconButton(t.IsRunning ? G.Pause : G.Play, 13, Theme.Brush(Theme.Orange), () => { clock.ToggleTimer(t); w.Rebuild(); }, Theme.Brush(Theme.Orange, 0.22), 36);
                var cancel = UI.IconButton(G.Close, 12, Theme.White(0.8), () => { clock.CancelTimer(t); w.Rebuild(); }, Theme.White(0.12), 36);
                cancel.Margin = new Thickness(8, 0, 0, 0);
                buttons.Children.Add(toggle); buttons.Children.Add(cancel);
                Grid.SetColumn(buttons, 2);
                inner.Children.Add(buttons);
                card.Child = inner;
                rowG.Children.Add(card);
                UiTicker.Attach(rowG, () => { ring.Progress = t.Progress; time.Text = Theme.Clock(t.Remaining, true); time.Opacity = t.IsRunning ? 1 : 0.55; });
                list.Children.Add(rowG);
            }
            var footer = new Grid { Margin = new Thickness(0, 2, 0, 0) };
            var quick = new StackPanel { Orientation = Orientation.Horizontal };
            foreach (var (label, secs) in Presets.Take(3))
            {
                var c = UI.Chip(label, Theme.Orange, () => { clock.StartTimer(secs); w.Rebuild(); });
                c.Margin = new Thickness(0, 0, 6, 0);
                quick.Children.Add(c);
            }
            footer.Children.Add(quick);
            var add = UI.Pill("New Timer", Theme.Orange, () => { TimerComposerOpen = true; w.Rebuild(); }, glyph: G.Add, height: 28);
            add.HorizontalAlignment = HorizontalAlignment.Right;
            footer.Children.Add(add);
            list.Children.Add(footer);
            return list;
        }

        private static TextBlock Colon(Color c, double size = 32)
        {
            var t = Theme.Text(":", size, FontWeights.SemiBold, Theme.Brush(c, 0.6), true);
            t.Margin = new Thickness(2, 0, 2, 4);
            return t;
        }

        private static FrameworkElement PomodoroPanel(IslandWindow w)
        {
            var clock = ClockService.Shared;
            var cfg = clock.Pomodoro;
            var s = clock.Session;
            if (s == null)
            {
                var root = new StackPanel();
                var row = new Grid();
                var dials = new StackPanel { Orientation = Orientation.Horizontal };
                FrameworkElement Labeled(Dial d, string label)
                {
                    var p = new StackPanel { Margin = new Thickness(0, 0, 10, 0) };
                    p.Children.Add(d);
                    var t = Theme.Text(label, 9, FontWeights.Bold, Theme.White(0.4));
                    t.HorizontalAlignment = HorizontalAlignment.Center;
                    p.Children.Add(t);
                    return p;
                }
                var focus = new Dial(cfg.WorkMinutes, 1, 180, Theme.Focus, 26, "m", "0");
                var rest = new Dial(cfg.BreakMinutes, 1, 60, Theme.Rest, 26, "m", "0");
                var lng = new Dial(cfg.LongBreakMinutes, 1, 90, Theme.Rest, 26, "m", "0");
                var rounds = new Dial(cfg.RoundsBeforeLongBreak, 0, 12, Colors.White, 26, null, "0");
                focus.Changed += v => { cfg.WorkMinutes = v; clock.Save(); };
                rest.Changed += v => { cfg.BreakMinutes = v; clock.Save(); };
                lng.Changed += v => { cfg.LongBreakMinutes = v; clock.Save(); };
                rounds.Changed += v => { cfg.RoundsBeforeLongBreak = v; clock.Save(); };
                dials.Children.Add(Labeled(focus, "FOCUS"));
                dials.Children.Add(Labeled(rest, "BREAK"));
                dials.Children.Add(Labeled(lng, "LONG"));
                dials.Children.Add(Labeled(rounds, "ROUNDS"));
                row.Children.Add(dials);
                var start = UI.IconButton(G.Play, 20, Brushes.Black, () => { clock.StartPomodoro(); w.Rebuild(); }, Theme.Brush(Theme.Focus), 52, "Start focusing");
                start.HorizontalAlignment = HorizontalAlignment.Right;
                start.VerticalAlignment = VerticalAlignment.Center;
                row.Children.Add(start);
                root.Children.Add(row);
                var chips = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 8, 0, 0) };
                var auto = UI.Chip("Auto-start focus", Theme.Focus, () => { cfg.AutoStartFocus = !cfg.AutoStartFocus; clock.Save(); w.Rebuild(); }, cfg.AutoStartFocus);
                var glow = UI.Chip("Break glow", Theme.Warm, () => { cfg.BreakGlow = !cfg.BreakGlow; clock.Save(); w.Rebuild(); }, cfg.BreakGlow);
                glow.Margin = new Thickness(6, 0, 0, 0);
                chips.Children.Add(auto); chips.Children.Add(glow);
                root.Children.Add(chips);
                return root;
            }

            var tint = s.IsRest ? Theme.Rest : Theme.Focus;
            var g = new Grid();
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var ringBox = new Grid { Width = 60, Height = 60 };
            var ring = new Ring(tint, 5);
            ringBox.Children.Add(ring);
            ringBox.Children.Add(Theme.Glyph(s.IsRest ? G.Coffee : G.Focus, 20, Theme.Brush(tint)));
            g.Children.Add(ringBox);
            var texts = new StackPanel { Margin = new Thickness(14, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
            texts.Children.Add(Theme.Text(s.IsRest ? (s.IsLongBreak ? "Long break" : "Break") : "Focus", 12, FontWeights.SemiBold, Theme.Brush(tint)));
            var time = Theme.Text("", 28, FontWeights.SemiBold, Brushes.White, true);
            texts.Children.Add(time);
            var dots = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 3, 0, 0) };
            int total = Math.Max(1, cfg.RoundsBeforeLongBreak), done = s.CompletedRounds % total;
            for (int i = 0; i < Math.Min(total, 12); i++)
                dots.Children.Add(new System.Windows.Shapes.Ellipse { Width = 6, Height = 6, Margin = new Thickness(0, 0, 4, 0), Fill = i < done ? Theme.Brush(Theme.Focus) : Theme.White(0.18) });
            texts.Children.Add(dots);
            Grid.SetColumn(texts, 1);
            g.Children.Add(texts);
            var buttons = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
            buttons.Children.Add(UI.IconButton(s.IsRunning ? G.Pause : G.Play, 14, Theme.Brush(tint), () => { clock.TogglePomodoro(); w.Rebuild(); }, Theme.Brush(tint, 0.22), 38, s.IsRunning ? "Pause" : "Resume"));
            var skip = UI.IconButton(G.Skip, 13, Theme.White(0.85), () => { clock.SkipPomodoro(); w.Rebuild(); }, Theme.White(0.12), 38, s.IsRest ? "End the break" : "Start the break now");
            skip.Margin = new Thickness(8, 0, 8, 0);
            buttons.Children.Add(skip);
            buttons.Children.Add(UI.IconButton(G.Close, 12, Theme.White(0.8), () => { clock.StopPomodoro(); w.Rebuild(); }, Theme.White(0.12), 38, "Stop Pomodoro"));
            Grid.SetColumn(buttons, 2);
            g.Children.Add(buttons);
            UiTicker.Attach(g, () =>
            {
                var cur = ClockService.Shared.Session;
                if (cur == null) return;
                ring.Progress = cur.Progress;
                time.Text = Theme.Clock(cur.Remaining, true);
            });
            return g;
        }

        // Reminders & Alarms

        private static FrameworkElement RemindersTab(IslandWindow w)
        {
            bool alarms = w.RemindersMode == "alarms";
            var clock = ClockService.Shared;
            var root = new DockPanel();
            FrameworkElement add = Composing == null
                ? UI.IconButton(G.Add, 12, Theme.Brush(alarms ? Theme.Orange : Theme.Yellow), () => { Composing = alarms ? "alarm" : "reminder"; w.Rebuild(); },
                                Theme.Brush(alarms ? Theme.Orange : Theme.Yellow, 0.2), 28, alarms ? "New Alarm" : "New Reminder")
                : null;
            var bar = ModeBar(new[] { "Reminders", "Alarms" }, alarms ? 1 : 0, i => { Composing = null; w.SetRemindersMode(i == 1 ? "alarms" : "reminders"); }, add);
            DockPanel.SetDock(bar, Dock.Top);
            root.Children.Add(bar);
            FrameworkElement body;
            if (Composing == "reminder") body = ReminderComposer(w);
            else if (Composing == "alarm") body = AlarmComposer(w);
            else if (alarms) body = AlarmList(w);
            else body = ReminderList(w);
            body.Margin = new Thickness(0, 10, 0, 0);
            root.Children.Add(body);
            return root;
        }

        private static ScrollViewer Scroll(UIElement content)
            => new() { Content = content, VerticalScrollBarVisibility = ScrollBarVisibility.Hidden, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, PanningMode = PanningMode.VerticalOnly };

        private static FrameworkElement ReminderList(IslandWindow w)
        {
            var clock = ClockService.Shared;
            var open = clock.Reminders.Where(r => !r.Completed).ToList();
            if (open.Count == 0) return Empty(G.List, "No Reminders", "Click + to add one.");
            var list = new StackPanel();
            foreach (var r in open)
            {
                var row = new Grid { Margin = new Thickness(0, 0, 0, 4), Background = Brushes.Transparent };
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                var check = new Border
                {
                    Width = 20, Height = 20, CornerRadius = new CornerRadius(10), BorderThickness = new Thickness(1.6),
                    BorderBrush = Theme.White(0.35), Cursor = Cursors.Hand, VerticalAlignment = VerticalAlignment.Center, Background = Brushes.Transparent,
                };
                check.MouseLeftButtonUp += (_, e) =>
                {
                    check.Background = Theme.Brush(Theme.Yellow);
                    check.BorderBrush = Theme.Brush(Theme.Yellow);
                    var t = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromMilliseconds(600) };
                    t.Tick += (_, _) => { t.Stop(); clock.CompleteReminder(r); w.Rebuild(); };
                    t.Start();
                    e.Handled = true;
                };
                row.Children.Add(check);
                var texts = new StackPanel { Margin = new Thickness(10, 0, 0, 0) };
                texts.Children.Add(Theme.Text(r.Title, 13.5, FontWeights.Medium, Theme.White(0.95)));
                if (r.Due is DateTime due)
                    texts.Children.Add(Theme.Text(DueText(due), 11, FontWeights.Medium, due < DateTime.Now ? Theme.Brush(Theme.Red, 0.9) : Theme.White(0.45)));
                Grid.SetColumn(texts, 1);
                row.Children.Add(texts);
                var del = UI.IconButton(G.Delete, 11, Theme.White(0.5), () => { clock.DeleteReminder(r); w.Rebuild(); });
                del.Opacity = 0;
                row.MouseEnter += (_, _) => del.Opacity = 1;
                row.MouseLeave += (_, _) => del.Opacity = 0;
                Grid.SetColumn(del, 2);
                row.Children.Add(del);
                list.Children.Add(row);
            }
            return Scroll(list);
        }

        private static string DueText(DateTime due)
        {
            string time = Theme.Time(due);
            if (due.Date == DateTime.Today) return "Today, " + time;
            if (due.Date == DateTime.Today.AddDays(1)) return "Tomorrow, " + time;
            return due.ToString("ddd d MMM") + ", " + time;
        }

        /// <summary>A text box for the island. Typing needs keyboard focus, so the island turns
        /// activatable while it's being edited.</summary>
        private static TextBox Field(IslandWindow w, double width = double.NaN)
        {
            var box = new TextBox
            {
                Background = Brushes.Transparent, Foreground = Brushes.White, CaretBrush = Brushes.White, BorderThickness = new Thickness(0),
                FontSize = 14, FontFamily = Theme.Font, Padding = new Thickness(10, 7, 10, 7), Width = width, VerticalContentAlignment = VerticalAlignment.Center,
            };
            box.GotKeyboardFocus += (_, _) => w.BeginEditing();
            box.PreviewMouseLeftButtonDown += (_, _) => { w.BeginEditing(); box.Focus(); };
            return box;
        }

        /// <summary>The rounded field background with a placeholder that hides once you type.</summary>
        private static Grid Rounded(TextBox box, string placeholder)
        {
            var host = new Grid();
            host.Children.Add(new Border { CornerRadius = new CornerRadius(11), Background = Theme.White(0.09), Child = box });
            var hint = Theme.Text(placeholder, box.FontSize, FontWeights.Normal, Theme.White(0.35));
            hint.Margin = new Thickness(12, 0, 0, 0);
            hint.IsHitTestVisible = false;
            host.Children.Add(hint);
            box.TextChanged += (_, _) => hint.Visibility = box.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
            return host;
        }

        private static FrameworkElement ReminderComposer(IslandWindow w)
        {
            var clock = ClockService.Shared;
            var root = new StackPanel();
            var row = new Grid();
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var box = Field(w);
            row.Children.Add(Rounded(box, "New Reminder"));
            DateTime? due = null;
            void Save()
            {
                clock.AddReminder(box.Text, due);
                Composing = null;
                w.EndEditing();
                w.Rebuild();
            }
            box.KeyDown += (_, e) => { if (e.Key == Key.Enter) Save(); if (e.Key == Key.Escape) { Composing = null; w.EndEditing(); w.Rebuild(); } };
            var cancel = UI.IconButton(G.Close, 11, Theme.White(0.7), () => { Composing = null; w.EndEditing(); w.Rebuild(); }, Theme.White(0.1), 32, "Cancel");
            cancel.Margin = new Thickness(8, 0, 6, 0);
            Grid.SetColumn(cancel, 1); row.Children.Add(cancel);
            var ok = UI.IconButton(G.Check, 13, Brushes.Black, Save, Theme.Brush(Theme.Yellow), 32, "Add Reminder");
            Grid.SetColumn(ok, 2); row.Children.Add(ok);
            root.Children.Add(row);

            var chips = new WrapPanel { Margin = new Thickness(0, 10, 0, 0) };
            var options = new List<(string, Func<DateTime>)>
            {
                ("In 15 min", () => DateTime.Now.AddMinutes(15)), ("In 1 hour", () => DateTime.Now.AddHours(1)),
            };
            if (DateTime.Now.Hour < 19) options.Add(("Tonight", () => DateTime.Today.AddHours(20)));
            options.Add(("Tomorrow", () => DateTime.Today.AddDays(1).AddHours(9)));
            var chipViews = new List<Pressable>();
            foreach (var (label, make) in options)
            {
                Pressable chip = null;
                chip = UI.Chip(label, Theme.Yellow, () =>
                {
                    bool was = chip.Tag as string == "on";
                    foreach (var c in chipViews) { c.Tag = null; c.Normal = Theme.White(0.09); c.Background = c.Normal; ((TextBlock)c.Child).Foreground = Theme.Brush(Theme.Yellow, 0.9); }
                    if (was) { due = null; return; }
                    due = make();
                    chip.Tag = "on";
                    chip.Normal = Theme.Brush(Theme.Yellow);
                    chip.Background = chip.Normal;
                    ((TextBlock)chip.Child).Foreground = Brushes.Black;
                });
                chip.Margin = new Thickness(0, 0, 6, 0);
                chipViews.Add(chip);
                chips.Children.Add(chip);
            }
            root.Children.Add(chips);
            root.Loaded += (_, _) => { w.BeginEditing(); box.Focus(); Keyboard.Focus(box); };
            return root;
        }

        private static FrameworkElement AlarmList(IslandWindow w)
        {
            var clock = ClockService.Shared;
            if (clock.Alarms.Count == 0) return Empty(G.Alarm, "No Alarms", "Click + to set one.");
            var list = new StackPanel();
            foreach (var a in clock.Alarms)
            {
                var row = new Grid { Margin = new Thickness(0, 0, 0, 4), Background = Brushes.Transparent };
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                var texts = new StackPanel { Opacity = a.Enabled ? 1 : 0.45 };
                var t = DateTime.Today.AddHours(a.Hour).AddMinutes(a.Minute);
                var time = Theme.Text(Theme.Time(t), 28, FontWeights.Light, Brushes.White, true);
                texts.Children.Add(time);
                texts.Children.Add(Theme.Text(a.Label.Length > 0 ? $"{a.Label}, {a.RepeatSummary}" : a.RepeatSummary, 11.5, FontWeights.Medium, Theme.White(0.5)));
                row.Children.Add(texts);
                var del = UI.IconButton(G.Delete, 11, Theme.White(0.5), () => { clock.DeleteAlarm(a); w.Rebuild(); });
                del.Opacity = 0;
                row.MouseEnter += (_, _) => del.Opacity = 1;
                row.MouseLeave += (_, _) => del.Opacity = 0;
                Grid.SetColumn(del, 1); row.Children.Add(del);
                var toggle = new ToggleSwitch(a.Enabled) { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(6, 0, 0, 0) };
                toggle.Toggled += on => { clock.SetAlarm(a, on); texts.Opacity = on ? 1 : 0.45; };
                Grid.SetColumn(toggle, 2); row.Children.Add(toggle);
                list.Children.Add(row);
            }
            return Scroll(list);
        }

        private static FrameworkElement AlarmComposer(IslandWindow w)
        {
            var clock = ClockService.Shared;
            bool h24 = S.Use24Hour;
            var root = new StackPanel();
            var row = new Grid();
            var dials = new StackPanel { Orientation = Orientation.Horizontal };
            var hour = new Dial(7, h24 ? 0 : 1, h24 ? 23 : 12, Theme.Orange, 34, null, h24 ? "00" : "0");
            var minute = new Dial(0, 0, 59, Theme.Orange, 34);
            dials.Children.Add(hour); dials.Children.Add(Colon(Theme.Orange, 30)); dials.Children.Add(minute);
            bool pm = false;
            if (!h24)
            {
                var ampm = new Segments(new[] { "AM", "PM" }, 0, 40) { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 0, 0) };
                ampm.Changed += i => pm = i == 1;
                dials.Children.Add(ampm);
            }
            row.Children.Add(dials);
            var side = new StackPanel { HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center };
            var label = Field(w, 150);
            label.FontSize = 13;
            side.Children.Add(Rounded(label, "Label"));
            var days = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 8, 0, 0) };
            var selectedDays = new HashSet<int>();
            var names = System.Globalization.CultureInfo.CurrentCulture.DateTimeFormat.ShortestDayNames;
            for (int d = 0; d < 7; d++)
            {
                int day = d;
                var cell = new Border { Width = 20, Height = 20, CornerRadius = new CornerRadius(10), Background = Theme.White(0.1), Margin = new Thickness(0, 0, 2, 0), Cursor = Cursors.Hand };
                var txt = Theme.Text(names[d][..1], 10.5, FontWeights.Bold, Theme.White(0.7));
                txt.HorizontalAlignment = HorizontalAlignment.Center;
                cell.Child = txt;
                cell.MouseLeftButtonUp += (_, e) =>
                {
                    if (!selectedDays.Add(day)) selectedDays.Remove(day);
                    bool on = selectedDays.Contains(day);
                    cell.Background = on ? Theme.Brush(Theme.Orange) : Theme.White(0.1);
                    txt.Foreground = on ? Brushes.Black : Theme.White(0.7);
                    e.Handled = true;
                };
                days.Children.Add(cell);
            }
            side.Children.Add(days);
            row.Children.Add(side);
            root.Children.Add(row);

            var actions = new Grid { Margin = new Thickness(0, 10, 0, 0) };
            var cancel = Theme.Text("Cancel", 12.5, FontWeights.SemiBold, Theme.White(0.55));
            cancel.Cursor = Cursors.Hand;
            cancel.MouseLeftButtonUp += (_, _) => { Composing = null; w.EndEditing(); w.Rebuild(); };
            actions.Children.Add(cancel);
            var set = UI.Pill("Set Alarm", Theme.Orange, () =>
            {
                int h = h24 ? hour.Value : hour.Value % 12 + (pm ? 12 : 0);
                clock.AddAlarm(new IslandAlarm { Hour = h, Minute = minute.Value, Label = label.Text.Trim(), RepeatDays = selectedDays.OrderBy(x => x).ToList() });
                Composing = null;
                w.EndEditing();
                w.Rebuild();
            }, filled: true, glyph: G.Alarm);
            set.HorizontalAlignment = HorizontalAlignment.Right;
            actions.Children.Add(set);
            root.Children.Add(actions);
            return root;
        }

        // Calendar

        private static FrameworkElement CalendarTab(IslandWindow w)
        {
            var cal = CalendarService.Shared;
            var root = new DockPanel();
            var strip = new StackPanel { Orientation = Orientation.Horizontal };
            for (int i = 0; i < 7; i++)
            {
                var day = DateTime.Today.AddDays(i);
                bool today = i == 0, selected = day == SelectedDay.Date;
                var cell = new StackPanel { Width = 46, Background = Brushes.Transparent, Cursor = Cursors.Hand };
                var wd = Theme.Text(day.ToString("ddd").ToUpperInvariant(), 9, FontWeights.Bold, today ? Theme.Brush(Theme.Red) : Theme.White(0.4));
                wd.HorizontalAlignment = HorizontalAlignment.Center;
                cell.Children.Add(wd);
                var num = new Border
                {
                    Width = 30, Height = 30, CornerRadius = new CornerRadius(15), Margin = new Thickness(0, 3, 0, 2),
                    Background = selected ? (today ? Theme.Brush(Theme.Red) : Theme.White(0.2)) : Brushes.Transparent,
                    Child = new TextBlock
                    {
                        Text = day.Day.ToString(), FontSize = 14, FontWeight = FontWeights.SemiBold, FontFamily = Theme.Font,
                        Foreground = selected ? Brushes.White : (today ? Theme.Brush(Theme.Red) : Theme.White(0.85)),
                        HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
                    },
                };
                cell.Children.Add(num);
                cell.Children.Add(new System.Windows.Shapes.Ellipse { Width = 4, Height = 4, Fill = cal.On(day).Any() ? Theme.White(0.5) : Brushes.Transparent });
                cell.MouseLeftButtonUp += (_, e) => { SelectedDay = day; w.Rebuild(); e.Handled = true; };
                strip.Children.Add(cell);
            }
            var top = new Grid();
            top.Children.Add(strip);
            DockPanel.SetDock(top, Dock.Top);
            root.Children.Add(top);

            FrameworkElement body;
            if (S.CalendarUrls.Count == 0)
            {
                var connect = UI.Pill("Add a Calendar", Theme.Red, () => w.OpenSettings(), filled: true, glyph: G.Add);
                body = Empty(G.Calendar, "Connect your calendar", "Paste your Google, Outlook or iCloud calendar's iCal link in Docky Settings.", connect);
            }
            else
            {
                var events = cal.On(SelectedDay).ToList();
                if (events.Count == 0) body = Empty(G.Calendar, "Nothing Scheduled", SelectedDay == DateTime.Today ? "The rest of today is yours." : "A free day.");
                else
                {
                    var list = new StackPanel();
                    foreach (var e in events)
                    {
                        var row = new Grid { Margin = new Thickness(0, 0, 0, 6) };
                        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                        row.Children.Add(new Border { Width = 4, Height = 32, CornerRadius = new CornerRadius(2), Background = Theme.Brush(e.Color) });
                        var texts = new StackPanel { Margin = new Thickness(10, 0, 0, 0) };
                        texts.Children.Add(Theme.Text(e.Title, 13.5, FontWeights.Medium, Theme.White(0.95)));
                        string when = e.AllDay ? "All day" : $"{Theme.Time(e.Start)} – {Theme.Time(e.End)}";
                        texts.Children.Add(Theme.Text(e.Location != null ? $"{when}  ·  {e.Location}" : when, 11, FontWeights.Medium, Theme.White(0.45)));
                        Grid.SetColumn(texts, 1); row.Children.Add(texts);
                        var badges = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
                        if (e.Now)
                            badges.Children.Add(new Border { CornerRadius = new CornerRadius(9), Background = Theme.Brush(Theme.Green), Padding = new Thickness(7, 1, 7, 1), Margin = new Thickness(0, 0, 6, 0), Child = Theme.Text("Now", 10, FontWeights.Bold, Brushes.Black) });
                        if (e.JoinUrl != null)
                            badges.Children.Add(UI.IconButton(G.Video, 11, Brushes.Black, () => Open(e.JoinUrl), Theme.Brush(Theme.Green), 28, "Join"));
                        Grid.SetColumn(badges, 2); row.Children.Add(badges);
                        list.Children.Add(row);
                    }
                    body = Scroll(list);
                }
            }
            body.Margin = new Thickness(0, 8, 0, 0);
            root.Children.Add(body);
            return root;
        }

        private static void Open(string url)
        {
            try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(url) { UseShellExecute = true }); } catch { }
        }

        // Clipboard

        private static FrameworkElement ClipboardTab(IslandWindow w)
        {
            var shelf = ShelfService.Shared;
            var g = new Grid();
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(108) });

            var dropZone = new Border
            {
                CornerRadius = new CornerRadius(18), Background = Theme.White(0.05), BorderThickness = new Thickness(1.5),
                BorderBrush = new VisualBrush { TileMode = TileMode.Tile, Viewport = new Rect(0, 0, 9, 9), ViewportUnits = BrushMappingMode.Absolute },
                AllowDrop = true,
            };
            dropZone.BorderBrush = shelf.Items.Count == 0 ? Theme.White(0.18) : Brushes.Transparent;
            if (shelf.Items.Count == 0)
            {
                var hint = new StackPanel { VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center };
                hint.Children.Add(Theme.Glyph(G.Clipboard, 22, Theme.White(0.35)));
                var t1 = Theme.Text("Drop Files Here", 13, FontWeights.SemiBold, Theme.White(0.75));
                t1.HorizontalAlignment = HorizontalAlignment.Center; t1.Margin = new Thickness(0, 6, 0, 2);
                hint.Children.Add(t1);
                var t2 = Theme.Text("They stay here until you remove them.", 11, FontWeights.Normal, Theme.White(0.38));
                t2.HorizontalAlignment = HorizontalAlignment.Center;
                hint.Children.Add(t2);
                dropZone.Child = hint;
            }
            else
            {
                var tiles = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(8, 0, 8, 0) };
                foreach (var item in shelf.Items) tiles.Children.Add(Tile(w, item));
                dropZone.Child = new ScrollViewer
                {
                    Content = tiles, HorizontalScrollBarVisibility = ScrollBarVisibility.Hidden, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
                    VerticalAlignment = VerticalAlignment.Center,
                };
            }
            dropZone.DragEnter += (_, e) => { dropZone.Background = Theme.White(0.11); dropZone.BorderBrush = Theme.White(0.55); e.Effects = DragDropEffects.Copy; e.Handled = true; };
            dropZone.DragLeave += (_, e) => { dropZone.Background = Theme.White(0.05); dropZone.BorderBrush = shelf.Items.Count == 0 ? Theme.White(0.18) : Brushes.Transparent; };
            dropZone.DragOver += (_, e) => { e.Effects = DragDropEffects.Copy; e.Handled = true; };
            dropZone.Drop += (_, e) => { shelf.Accept(e.Data); e.Handled = true; };
            g.Children.Add(dropZone);

            var share = new Border
            {
                CornerRadius = new CornerRadius(18), Background = Theme.Brush(Theme.Blue, 0.14), Margin = new Thickness(12, 0, 0, 0),
                BorderThickness = new Thickness(1.5), BorderBrush = Theme.Brush(Theme.Blue, 0.45), AllowDrop = true, Cursor = Cursors.Hand,
            };
            var shareContent = new StackPanel { VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center };
            var shareIcon = Theme.Glyph(G.Share, 21, Theme.Brush(Theme.Blue));
            var shareText = Theme.Text("Share", 12.5, FontWeights.SemiBold, Theme.Brush(Theme.Blue));
            shareText.HorizontalAlignment = HorizontalAlignment.Center; shareText.Margin = new Thickness(0, 6, 0, 0);
            shareContent.Children.Add(shareIcon); shareContent.Children.Add(shareText);
            share.Child = shareContent;
            share.ToolTip = shelf.Items.Count == 0 ? "Drop a file here to share it" : "Share everything on the shelf";
            void Highlight(bool on)
            {
                share.Background = on ? Theme.Brush(Theme.Blue, 0.85) : Theme.Brush(Theme.Blue, 0.14);
                shareIcon.Foreground = shareText.Foreground = on ? Brushes.White : Theme.Brush(Theme.Blue);
            }
            share.DragEnter += (_, e) => { Highlight(true); e.Effects = DragDropEffects.Copy; e.Handled = true; };
            share.DragLeave += (_, _) => Highlight(false);
            share.DragOver += (_, e) => { e.Effects = DragDropEffects.Copy; e.Handled = true; };
            share.Drop += (_, e) => { Highlight(false); var paths = shelf.Accept(e.Data, keep: false); ShelfService.Share(w.Handle, paths); e.Handled = true; };
            share.MouseLeftButtonUp += (_, e) => { ShelfService.Share(w.Handle, shelf.Items.Select(i => i.Path).ToList()); e.Handled = true; };
            Grid.SetColumn(share, 1);
            g.Children.Add(share);
            return g;
        }

        private static FrameworkElement Tile(IslandWindow w, ShelfItem item)
        {
            var tile = new Grid { Width = 86, Margin = new Thickness(0, 0, 6, 0), Background = Brushes.Transparent, ToolTip = item.Path };
            var back = new Border { CornerRadius = new CornerRadius(13), Background = Brushes.Transparent };
            tile.Children.Add(back);
            var stack = new StackPanel { Margin = new Thickness(0, 8, 0, 8) };
            var thumb = ShelfService.Thumbnail(item.Path);
            var image = new System.Windows.Controls.Image { Source = thumb, Width = 52, Height = 52, Stretch = Stretch.Uniform };
            if (thumb == null) stack.Children.Add(Theme.Glyph(G.Clipboard, 30, Theme.White(0.5)));
            else stack.Children.Add(image);
            var name = new TextBlock
            {
                Text = item.Name, FontSize = 10.5, FontWeight = FontWeights.Medium, Foreground = Theme.White(0.85), FontFamily = Theme.Font,
                TextWrapping = TextWrapping.Wrap, TextTrimming = TextTrimming.CharacterEllipsis, MaxHeight = 28, Width = 74,
                TextAlignment = TextAlignment.Center, Margin = new Thickness(0, 5, 0, 0), HorizontalAlignment = HorizontalAlignment.Center,
            };
            stack.Children.Add(name);
            tile.Children.Add(stack);
            var remove = UI.IconButton(G.Close, 8, Brushes.White, () => ShelfService.Shared.Remove(item), Theme.White(0.3), 18, "Remove");
            remove.HorizontalAlignment = HorizontalAlignment.Right;
            remove.VerticalAlignment = VerticalAlignment.Top;
            remove.Opacity = 0;
            tile.Children.Add(remove);
            tile.MouseEnter += (_, _) => { back.Background = Theme.White(0.1); remove.Opacity = 1; };
            tile.MouseLeave += (_, _) => { back.Background = Brushes.Transparent; remove.Opacity = 0; };

            Point? down = null;
            tile.PreviewMouseLeftButtonDown += (_, e) =>
            {
                down = e.GetPosition(tile);
                if (e.ClickCount == 2) Open(item.Path);
            };
            tile.PreviewMouseMove += (_, e) =>
            {
                if (down is not Point d || e.LeftButton != MouseButtonState.Pressed) return;
                if ((e.GetPosition(tile) - d).Length < 6) return;
                down = null;
                var data = new DataObject(DataFormats.FileDrop, new[] { item.Path });
                DragDrop.DoDragDrop(tile, data, DragDropEffects.Copy);
            };
            var menu = new ContextMenu();
            void Add(string header, Action a) { var mi = new MenuItem { Header = header }; mi.Click += (_, _) => a(); menu.Items.Add(mi); }
            Add("Open", () => Open(item.Path));
            Add("Show in Explorer", () => { try { System.Diagnostics.Process.Start("explorer.exe", $"/select,\"{item.Path}\""); } catch { } });
            Add("Share…", () => ShelfService.Share(w.Handle, new List<string> { item.Path }));
            Add("Remove", () => ShelfService.Shared.Remove(item));
            Add("Remove All", () => ShelfService.Shared.Clear());
            tile.ContextMenu = menu;
            return tile;
        }

        // MARK: Cards

        private static FrameworkElement Card(Color tint, string glyph, string caption, string headline, double headlineSize, IEnumerable<FrameworkElement> actions, bool ring = false, bool wrap = false)
        {
            var g = new Grid { Margin = new Thickness(24, 0, 24, 0) };
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var circle = new Border { Width = 46, Height = 46, CornerRadius = new CornerRadius(23), Background = Theme.Brush(tint, 0.2), VerticalAlignment = VerticalAlignment.Center };
            var icon = Theme.Glyph(glyph, 20, Theme.Brush(tint));
            circle.Child = icon;
            if (ring)
            {
                var rot = new RotateTransform(0);
                icon.RenderTransform = rot;
                icon.RenderTransformOrigin = new Point(0.5, 0.2);
                rot.BeginAnimation(RotateTransform.AngleProperty, new DoubleAnimation(-14, 14, TimeSpan.FromMilliseconds(110)) { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever });
            }
            g.Children.Add(circle);
            var texts = new StackPanel { Margin = new Thickness(14, 0, 8, 0), VerticalAlignment = VerticalAlignment.Center };
            texts.Children.Add(Theme.Text(caption, 12, FontWeights.SemiBold, Theme.Brush(tint)));
            var head = Theme.Text(headline, headlineSize, FontWeights.SemiBold, Brushes.White, true);
            if (wrap) { head.TextWrapping = TextWrapping.Wrap; head.TextTrimming = TextTrimming.CharacterEllipsis; head.MaxHeight = headlineSize * 2.8; }
            texts.Children.Add(head);
            Grid.SetColumn(texts, 1);
            g.Children.Add(texts);
            var row = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
            foreach (var a in actions) { a.Margin = new Thickness(8, 0, 0, 0); row.Children.Add(a); }
            Grid.SetColumn(row, 2);
            g.Children.Add(row);
            return g;
        }

        private static FrameworkElement Alert(IslandWindow w)
        {
            var clock = ClockService.Shared;
            var a = clock.Alerts.First();
            switch (a.Type)
            {
                case IslandAlert.Kind.Alarm:
                    return Card(Theme.Orange, G.Alarm, a.Alarm.Label.Length > 0 ? a.Alarm.Label : "Alarm", Theme.Time(a.FiredAt), 26,
                        new FrameworkElement[]
                        {
                            UI.Pill("Snooze", Theme.Orange, () => clock.Snooze(a)),
                            UI.IconButton(G.Close, 13, Brushes.White, () => clock.Dismiss(a), Theme.White(0.16), 38, "Stop"),
                        }, ring: true);
                case IslandAlert.Kind.Timer:
                    return Card(Theme.Orange, G.Timer, a.Timer.Label.Length > 0 ? a.Timer.Label : "Timer · " + IslandTimer.DurationTitle(a.Timer.Duration), "Done", 26,
                        new FrameworkElement[]
                        {
                            UI.IconButton(G.Repeat, 13, Theme.Brush(Theme.Orange), () => clock.RepeatTimer(a), Theme.Brush(Theme.Orange, 0.22), 38, "Repeat"),
                            UI.IconButton(G.Close, 13, Brushes.White, () => clock.Dismiss(a), Theme.White(0.16), 38, "Stop"),
                        }, ring: true);
                case IslandAlert.Kind.Reminder:
                    return Card(Theme.Yellow, G.Bell, "Reminder", a.Reminder.Title, 18,
                        new FrameworkElement[]
                        {
                            UI.Pill("Later", Theme.Yellow, () => clock.Snooze(a)),
                            UI.IconButton(G.Check, 13, Brushes.Black, () => clock.CompleteReminder(a.Reminder), Theme.Brush(Theme.Yellow), 38, "Mark as Done"),
                        });
                default:
                    return Card(Theme.Focus, G.Focus, $"Pomodoro · {a.Round} done", "Break's over", 18,
                        new FrameworkElement[]
                        {
                            UI.Pill("Start Focus", Theme.Focus, () => clock.StartPomodoro(), filled: true, glyph: G.Play),
                            UI.IconButton(G.Close, 13, Brushes.White, () => clock.StopPomodoro(), Theme.White(0.16), 38, "End Pomodoro"),
                        });
            }
        }

        private static FrameworkElement Notice(IslandWindow w)
        {
            FrameworkElement primary;
            if (w.NoticeToggleLabel != null)
            {
                var stack = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
                var sw = new ToggleSwitch(w.NoticeToggleValue?.Invoke() ?? true) { HorizontalAlignment = HorizontalAlignment.Center };
                sw.Toggled += on => w.NoticeToggled?.Invoke(on);
                stack.Children.Add(sw);
                var label = Theme.Text(w.NoticeToggleLabel, 9.5, FontWeights.SemiBold, Theme.White(0.45));
                label.HorizontalAlignment = HorizontalAlignment.Center;
                label.Margin = new Thickness(0, 4, 0, 0);
                stack.Children.Add(label);
                primary = stack;
            }
            else primary = UI.Pill(w.NoticeAction, Theme.Blue, () => w.ResolveNotice(true), filled: true);
            return Card(Theme.Blue, w.NoticeGlyph, w.NoticeTitle, w.NoticeMessage, 13,
                new[] { primary, UI.IconButton(G.Close, 11, Theme.White(0.8), () => w.ResolveNotice(false), Theme.White(0.14), 30, "Not now") },
                wrap: true);
        }

        private static FrameworkElement BreakCard(IslandWindow w)
        {
            var clock = ClockService.Shared;
            var g = new Grid { Margin = new Thickness(22, 0, 22, 0) };
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var halo = new Border { Width = 46, Height = 46, CornerRadius = new CornerRadius(23), Background = Theme.Brush(Theme.Warm, 0.22), VerticalAlignment = VerticalAlignment.Center };
            var breathe = new ScaleTransform(1, 1);
            halo.RenderTransform = breathe;
            halo.RenderTransformOrigin = new Point(0.5, 0.5);
            var b = new DoubleAnimation(0.94, 1.08, TimeSpan.FromSeconds(2.4)) { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever, EasingFunction = Anim.EaseInOut };
            Timeline.SetDesiredFrameRate(b, 30);
            breathe.BeginAnimation(ScaleTransform.ScaleXProperty, b);
            breathe.BeginAnimation(ScaleTransform.ScaleYProperty, b);
            var iconHost = new Grid();
            iconHost.Children.Add(halo);
            iconHost.Children.Add(Theme.Glyph(G.Coffee, 19, Theme.Brush(Theme.Warm)));
            g.Children.Add(iconHost);
            var texts = new StackPanel { Margin = new Thickness(14, 0, 8, 0), VerticalAlignment = VerticalAlignment.Center };
            texts.Children.Add(Theme.Text("Time for a break", 17, FontWeights.SemiBold, Brushes.White, true));
            var sub = Theme.Text("", 12, FontWeights.Medium, Theme.White(0.55));
            texts.Children.Add(sub);
            Grid.SetColumn(texts, 1);
            g.Children.Add(texts);
            var row = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
            row.Children.Add(UI.Pill("Skip", Theme.Rest, () => clock.SkipPomodoro()));
            var up = UI.IconButton(G.Up, 12, Theme.White(0.85), w.DismissBreak, Theme.White(0.14), 32, "Put away (or scroll / drag up)");
            up.Margin = new Thickness(8, 0, 0, 0);
            row.Children.Add(up);
            Grid.SetColumn(row, 2);
            g.Children.Add(row);
            UiTicker.Attach(g, () =>
            {
                var s = clock.Session;
                if (s == null) return;
                sub.Text = (s.IsLongBreak ? "Long break · " : "Back to focus in ") + Theme.Clock(s.Remaining, true);
            });
            return g;
        }
    }
}
