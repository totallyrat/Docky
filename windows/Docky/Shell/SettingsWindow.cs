using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using Docky.Core;
using Docky.Island;
using Docky.Services;

namespace Docky.Shell
{
    /// <summary>Things Settings can ask the app to do.</summary>
    public sealed class AppActions
    {
        public Action PlayIntro, RunSetup, PreviewBreakGlow, CheckForUpdates, InstallUpdate, Quit;
    }

    /// <summary>Docky Settings: a dark window with a sidebar, opened from the island or the tray.</summary>
    public sealed class SettingsWindow : Window
    {
        private static Settings S => SettingsStore.Current;
        private readonly AppActions actions;
        private readonly Grid content = new();
        private readonly StackPanel nav = new() { Margin = new Thickness(10, 14, 10, 10) };
        private readonly Border body;
        private string page = "General";
        private readonly ScaleTransform openScale = new(0.96, 0.96);
        private readonly TranslateTransform openShift = new(0, -14);

        private static readonly (string name, string glyph)[] Pages =
        {
            ("General", G.Settings), ("Island", G.Sparkle), ("Now Playing", G.Music), ("Indicators", G.Volume),
            ("Timers & Pomodoro", G.Timer), ("Calendar", G.Calendar), ("About", G.Star),
        };

        private static readonly Color Back = Color.FromRgb(28, 28, 30), Side = Color.FromRgb(22, 22, 24), CardColor = Color.FromRgb(40, 40, 43);

        public SettingsWindow(AppActions actions)
        {
            this.actions = actions;
            Title = "Docky Settings";
            Width = 780;
            Height = 580;
            MinWidth = 640;
            MinHeight = 440;
            Background = Theme.Brush(Back);
            FontFamily = Theme.Font;
            WindowStartupLocation = WindowStartupLocation.Manual;
            Left = (SystemParameters.WorkArea.Width - Width) / 2 + SystemParameters.WorkArea.Left;
            Top = SystemParameters.WorkArea.Top + 70;
            try { Icon = Onboarding.AppIcon(); } catch { }

            var root = new Grid();
            root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(212) });
            root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            var side = new Border { Background = Theme.Brush(Side), Child = nav };
            root.Children.Add(side);
            body = new Border { Child = content };
            Grid.SetColumn(body, 1);
            root.Children.Add(body);

            // Opens out of the island: drops slightly and grows into place.
            root.RenderTransformOrigin = new Point(0.5, 0);
            root.RenderTransform = new TransformGroup { Children = { openScale, openShift } };
            root.Opacity = 0;
            Content = root;
            Loaded += (_, _) =>
            {
                var spring = new BackEase { Amplitude = 0.25, EasingMode = EasingMode.EaseOut };
                Anim.To(root, OpacityProperty, 1, 260);
                Anim.To(openScale, ScaleTransform.ScaleXProperty, 1, 420, spring);
                Anim.To(openScale, ScaleTransform.ScaleYProperty, 1, 420, spring);
                Anim.To(openShift, TranslateTransform.YProperty, 0, 420, spring);
            };

            BuildNav();
            Show(page);
            SettingsStore.Changed += OnSettingsChanged;
            Updater.Shared.StatusChanged += OnUpdateStatus;
            Closed += (_, _) => { SettingsStore.Changed -= OnSettingsChanged; Updater.Shared.StatusChanged -= OnUpdateStatus; };
        }

        protected override void OnSourceInitialized(EventArgs e)
        {
            base.OnSourceInitialized(e);
            Native.DarkTitleBar(new WindowInteropHelper(this).Handle);
        }

        private bool rebuilding;
        private void OnSettingsChanged()
        {
            // Settings changed elsewhere (e.g. the island's setup) — keep this page in sync.
            if (rebuilding) return;
            Dispatcher.BeginInvoke(new Action(() => { if (!editing) Show(page, animate: false); }));
        }

        private bool editing;

        private void OnUpdateStatus()
        {
            if (page == "General" || page == "About") Dispatcher.BeginInvoke(new Action(() => { if (!editing) Show(page, animate: false); }));
        }

        private void Set(Action<Settings> change)
        {
            rebuilding = true;
            SettingsStore.Update(change);
            rebuilding = false;
        }

        // MARK: Navigation

        private void BuildNav()
        {
            nav.Children.Clear();
            var header = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(8, 4, 0, 18) };
            header.Children.Add(new Image { Source = Onboarding.AppIcon(), Width = 30, Height = 30 });
            var t = Theme.Text("Docky", 17, FontWeights.Bold, Brushes.White, true);
            t.Margin = new Thickness(10, 0, 0, 0);
            header.Children.Add(t);
            nav.Children.Add(header);
            foreach (var (name, glyph) in Pages)
            {
                bool selected = name == page;
                var row = new StackPanel { Orientation = Orientation.Horizontal };
                var icon = Theme.Glyph(glyph, 13, selected ? Brushes.White : Theme.White(0.65));
                icon.Width = 20;
                row.Children.Add(icon);
                var label = Theme.Text(name, 13, selected ? FontWeights.SemiBold : FontWeights.Normal, selected ? Brushes.White : Theme.White(0.75));
                label.Margin = new Thickness(10, 0, 0, 0);
                row.Children.Add(label);
                var item = new Pressable
                {
                    Height = 34, CornerRadius = new CornerRadius(8), Padding = new Thickness(10, 0, 10, 0), Margin = new Thickness(0, 0, 0, 2),
                    Child = row, PressScale = 0.97,
                    Normal = selected ? Theme.White(0.1) : Brushes.Transparent,
                    Hover = selected ? Theme.White(0.12) : Theme.White(0.06),
                };
                string n = name;
                item.Click += () => { page = n; BuildNav(); Show(n); };
                nav.Children.Add(item);
            }
        }

        public void ShowPage(string name) { page = name; BuildNav(); Show(name); }

        private void Show(string name, bool animate = true)
        {
            var stack = new StackPanel { Margin = new Thickness(28, 22, 28, 28) };
            stack.Children.Add(Theme.Text(name, 24, FontWeights.Bold, Brushes.White, true));
            switch (name)
            {
                case "General": General(stack); break;
                case "Island": IslandPage(stack); break;
                case "Now Playing": NowPlaying(stack); break;
                case "Indicators": Indicators(stack); break;
                case "Timers & Pomodoro": Timers(stack); break;
                case "Calendar": CalendarPage(stack); break;
                default: About(stack); break;
            }
            var scroll = new ScrollViewer { Content = stack, VerticalScrollBarVisibility = ScrollBarVisibility.Hidden, PanningMode = PanningMode.VerticalOnly };
            content.Children.Clear();
            content.Children.Add(scroll);
            if (animate)
            {
                var shift = new TranslateTransform(0, 10);
                stack.RenderTransform = shift;
                stack.Opacity = 0;
                Anim.To(stack, OpacityProperty, 1, 220);
                Anim.To(shift, TranslateTransform.YProperty, 0, 320);
            }
        }

        // MARK: Building blocks

        private static TextBlock SectionTitle(string text)
        {
            var t = Theme.Text(text.ToUpperInvariant(), 11, FontWeights.SemiBold, Theme.White(0.45));
            t.Margin = new Thickness(4, 22, 0, 8);
            return t;
        }

        private static Border Group(params FrameworkElement[] rows)
        {
            var s = new StackPanel();
            for (int i = 0; i < rows.Length; i++)
            {
                if (i > 0) s.Children.Add(new Border { Height = 1, Background = Theme.White(0.06), Margin = new Thickness(14, 0, 0, 0) });
                s.Children.Add(rows[i]);
            }
            return new Border { Background = Theme.Brush(CardColor), CornerRadius = new CornerRadius(10), Child = s };
        }

        private static Grid Row(string title, string detail, FrameworkElement control)
        {
            var g = new Grid { MinHeight = 48, Margin = new Thickness(14, 8, 14, 8) };
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var texts = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 16, 0) };
            texts.Children.Add(Theme.Text(title, 13.5, FontWeights.Normal, Brushes.White));
            if (detail != null)
            {
                var d = Theme.Text(detail, 11.5, FontWeights.Normal, Theme.White(0.5));
                d.TextWrapping = TextWrapping.Wrap;
                d.TextTrimming = TextTrimming.None;
                d.Margin = new Thickness(0, 2, 0, 0);
                texts.Children.Add(d);
            }
            g.Children.Add(texts);
            if (control != null)
            {
                control.VerticalAlignment = VerticalAlignment.Center;
                Grid.SetColumn(control, 1);
                g.Children.Add(control);
            }
            return g;
        }

        private Grid Toggle(string title, string detail, bool value, Action<Settings, bool> set)
        {
            var sw = new ToggleSwitch(value) { Tint = Theme.Blue };
            sw.Toggled += on => Set(s => set(s, on));
            return Row(title, detail, sw);
        }

        private Grid Slider(string title, string detail, double min, double max, double value, Func<double, string> format, Action<Settings, double> set, double step = 0)
        {
            var label = Theme.Text(format(value), 12.5, FontWeights.SemiBold, Theme.White(0.7));
            label.Width = 54;
            label.TextAlignment = TextAlignment.Right;
            var slider = new IslandSlider(min, max, value) { Width = 190 };
            slider.ValueChanged += v =>
            {
                if (step > 0) v = Math.Round(v / step) * step;
                label.Text = format(v);
                editing = true;
                Set(s => set(s, v));
            };
            slider.Released += () => editing = false;
            var row = new StackPanel { Orientation = Orientation.Horizontal };
            row.Children.Add(slider);
            row.Children.Add(label);
            return Row(title, detail, row);
        }

        private Grid Choice(string title, string detail, string[] labels, string[] values, string current, Action<Settings, string> set)
        {
            var seg = new Segments(labels, Math.Max(0, Array.IndexOf(values, current)), 78);
            seg.Changed += i => Set(s => set(s, values[i]));
            return Row(title, detail, seg);
        }

        private static Pressable Button(string text, Action click, bool accent = false)
            => UI.Pill(text, accent ? Theme.Blue : Color.FromRgb(200, 200, 205), click, filled: accent, height: 30);

        // MARK: Pages

        private void General(StackPanel s)
        {
            s.Children.Add(SectionTitle("Updates"));
            s.Children.Add(UpdatesGroup());
            s.Children.Add(SectionTitle("Startup"));
            s.Children.Add(Group(
                Toggle("Start Docky with Windows", null, S.LaunchAtStartup, (x, v) => { x.LaunchAtStartup = v; SettingsStore.ApplyStartup(); }),
                Toggle("Play the intro at launch", "A glowing border, the wordmark, and the island dropping in.", S.PlayIntro, (x, v) => x.PlayIntro = v),
                Row("Watch the intro", null, Button("Play Now", () => actions.PlayIntro?.Invoke()))));
            s.Children.Add(SectionTitle("Behaviour"));
            s.Children.Add(Group(
                Toggle("Hide in fullscreen apps", "Point at the top of the screen to bring the island back.", S.HideInFullscreen, (x, v) => x.HideInFullscreen = v),
                Toggle("Hide when there's nothing to show", "The island appears when music plays, a timer runs or you point at the top.", S.HideWhenIdle, (x, v) => x.HideWhenIdle = v),
                Toggle("24-hour time", null, S.Use24Hour, (x, v) => x.Use24Hour = v)));
            s.Children.Add(SectionTitle("Docky"));
            s.Children.Add(Group(
                Row("Run setup again", "Walk through size, animation and the most-used options in the island.", Button("Start Setup", () => { actions.RunSetup?.Invoke(); })),
                Row("Quit Docky", null, Button("Quit", () => actions.Quit?.Invoke()))));
        }

        private void IslandPage(StackPanel s)
        {
            s.Children.Add(SectionTitle("Look"));
            s.Children.Add(Group(
                Slider("Size", null, 0.8, 1.3, S.IslandScale, v => Math.Round(v * 100) + "%", (x, v) => x.IslandScale = v, 0.05),
                Choice("Animation", "Every morph uses this spring.", new[] { "Smooth", "Snappy", "Bouncy" }, new[] { "smooth", "snappy", "bouncy" }, S.AnimationFeel, (x, v) => x.AnimationFeel = v),
                Toggle("Grow a little when pointed at", null, S.HoverGrow, (x, v) => x.HoverGrow = v),
                Toggle("Timer bubble", "A small ring beside the island while music plays and a timer runs.", S.ShowTimerBubble, (x, v) => x.ShowTimerBubble = v)));
            s.Children.Add(SectionTitle("Opening and closing"));
            s.Children.Add(Group(
                Toggle("Scroll down to open", "Point at the island and scroll (or swipe down on a touchpad).", S.ScrollToOpen, (x, v) => x.ScrollToOpen = v),
                Toggle("Click to open", null, S.ClickToOpen, (x, v) => x.ClickToOpen = v),
                Toggle("Open on hover", null, S.HoverToOpen, (x, v) => x.HoverToOpen = v),
                Slider("Hover delay", null, 0.1, 1.5, S.HoverDelay, v => v.ToString("0.0") + " s", (x, v) => x.HoverDelay = v, 0.1),
                Slider("Close after leaving", null, 0.1, 1.5, S.CollapseDelay, v => v.ToString("0.0") + " s", (x, v) => x.CollapseDelay = v, 0.05)));
            s.Children.Add(Hint("Drag inwards on the island (or swipe sideways on a touchpad) to tuck Now Playing away; drag outwards to bring it back."));
        }

        private void NowPlaying(StackPanel s)
        {
            s.Children.Add(SectionTitle("Now Playing"));
            s.Children.Add(Group(
                Toggle("Show Now Playing", null, S.NowPlayingEnabled, (x, v) => x.NowPlayingEnabled = v),
                Toggle("Only music", "Music apps like Spotify, Apple Music and Tidal — or anything between 1 and 5 minutes long, so short clips don't show.", S.MusicOnly, (x, v) => x.MusicOnly = v),
                Toggle("Show the song title", null, S.ShowTitle, (x, v) => x.ShowTitle = v),
                Toggle("Tint with the artwork's colour", null, S.TintFromArtwork, (x, v) => x.TintFromArtwork = v),
                Toggle("Peek when the song changes", null, S.TrackChangePeek, (x, v) => x.TrackChangePeek = v),
                Slider("Keep paused media for", null, 5, 120, S.PausedLinger, v => Math.Round(v) + " s", (x, v) => x.PausedLinger = v, 5)));
            s.Children.Add(SectionTitle("Playback"));
            s.Children.Add(Group(
                Toggle("Auto-pause other media", "When something starts playing, whatever was playing before pauses.", S.AutoPauseOthers, (x, v) => x.AutoPauseOthers = v)));
        }

        private void Indicators(StackPanel s)
        {
            s.Children.Add(SectionTitle("Show in the island"));
            s.Children.Add(Group(
                Toggle("Volume", null, S.HudVolume, (x, v) => x.HudVolume = v),
                Toggle("Brightness", BrightnessService.Shared.Available ? null : "Only built-in laptop screens report brightness.", S.HudBrightness, (x, v) => x.HudBrightness = v),
                Toggle("Do not disturb", null, S.HudFocus, (x, v) => x.HudFocus = v),
                Toggle("Bluetooth devices and drives", null, S.HudDevices, (x, v) => x.HudDevices = v),
                Toggle("Charging", null, S.HudCharging, (x, v) => x.HudCharging = v)));
            s.Children.Add(SectionTitle("Windows"));
            s.Children.Add(Group(
                Toggle("Replace the Windows volume pop-up", "Docky handles the volume keys so only the island shows the change.", S.ReplaceVolumeOverlay, (x, v) => x.ReplaceVolumeOverlay = v)));
            s.Children.Add(Hint("Point at the volume or brightness in the island and scroll, or drag along it, to adjust. Windows doesn't let apps hide its brightness pop-up."));
        }

        private void Timers(StackPanel s)
        {
            var clock = ClockService.Shared;
            var cfg = clock.Pomodoro;
            s.Children.Add(SectionTitle("Sounds"));
            s.Children.Add(Group(
                Choice("Alarm sound", null, new[] { "Radar", "Chime" }, new[] { "Radar", "Chime" }, S.AlarmSound, (x, v) => { x.AlarmSound = v; clock.PlayOnce(v); }),
                Choice("Timer sound", null, new[] { "Radar", "Chime" }, new[] { "Radar", "Chime" }, S.TimerSound, (x, v) => { x.TimerSound = v; clock.PlayOnce(v); }),
                Slider("Snooze for", null, 1, 30, S.SnoozeMinutes, v => Math.Round(v) + " min", (x, v) => x.SnoozeMinutes = (int)Math.Round(v), 1)));
            s.Children.Add(SectionTitle("Pomodoro"));
            Grid PomodoroSlider(string title, double min, double max, int value, Action<int> set, string unit = " min")
            {
                var label = Theme.Text(value + unit, 12.5, FontWeights.SemiBold, Theme.White(0.7));
                label.Width = 60;
                label.TextAlignment = TextAlignment.Right;
                var slider = new IslandSlider(min, max, value) { Width = 190 };
                slider.ValueChanged += v => { int i = (int)Math.Round(v); label.Text = i + unit; set(i); };
                slider.Released += () => clock.Save();
                var row = new StackPanel { Orientation = Orientation.Horizontal };
                row.Children.Add(slider);
                row.Children.Add(label);
                return Row(title, null, row);
            }
            var autoStart = new ToggleSwitch(cfg.AutoStartFocus) { Tint = Theme.Blue };
            autoStart.Toggled += on => { cfg.AutoStartFocus = on; clock.Save(); };
            var glow = new ToggleSwitch(cfg.BreakGlow) { Tint = Theme.Blue };
            glow.Toggled += on => { cfg.BreakGlow = on; clock.Save(); };
            s.Children.Add(Group(
                PomodoroSlider("Focus", 5, 120, cfg.WorkMinutes, v => cfg.WorkMinutes = v),
                PomodoroSlider("Break", 1, 30, cfg.BreakMinutes, v => cfg.BreakMinutes = v),
                PomodoroSlider("Long break", 5, 60, cfg.LongBreakMinutes, v => cfg.LongBreakMinutes = v),
                PomodoroSlider("Rounds before a long break", 0, 8, cfg.RoundsBeforeLongBreak, v => cfg.RoundsBeforeLongBreak = v, ""),
                Row("Start the next focus automatically", null, autoStart),
                Row("Warm glow during breaks", "A soft glow around the screen until the break ends or you put the island away.", glow),
                Row("Preview the break glow", null, Button("Preview", () => actions.PreviewBreakGlow?.Invoke()))));
        }

        private void CalendarPage(StackPanel s)
        {
            s.Children.Add(SectionTitle("Calendar"));
            s.Children.Add(Group(Toggle("Show the Calendar tab", null, S.ShowCalendar, (x, v) => x.ShowCalendar = v)));
            s.Children.Add(SectionTitle("Calendars"));
            var rows = new List<FrameworkElement>();
            foreach (var url in S.CalendarUrls)
            {
                string u = url;
                var remove = UI.IconButton(G.Delete, 12, Theme.White(0.7), () => { Set(x => x.CalendarUrls.Remove(u)); _ = CalendarService.Shared.ReloadAsync(); Show(page, false); }, Theme.White(0.08), 30, "Remove");
                var r = Row(Shorten(u), null, remove);
                rows.Add(r);
            }
            var box = new TextBox
            {
                Background = Theme.White(0.08), Foreground = Brushes.White, CaretBrush = Brushes.White, BorderThickness = new Thickness(0),
                Padding = new Thickness(10, 7, 10, 7), FontSize = 13, Width = 330, VerticalContentAlignment = VerticalAlignment.Center,
            };
            var add = Button("Add", () =>
            {
                var text = box.Text.Trim();
                if (text.StartsWith("webcal://", StringComparison.OrdinalIgnoreCase)) text = "https://" + text[9..];
                if (!Uri.TryCreate(text, UriKind.Absolute, out _)) { box.Background = Theme.Brush(Theme.Red, 0.25); return; }
                if (!S.CalendarUrls.Contains(text)) Set(x => x.CalendarUrls.Add(text));
                _ = CalendarService.Shared.ReloadAsync();
                Show(page, false);
            }, accent: true);
            add.Margin = new Thickness(8, 0, 0, 0);
            var addRow = new StackPanel { Orientation = Orientation.Horizontal };
            addRow.Children.Add(new Border { CornerRadius = new CornerRadius(8), Background = Theme.White(0.08), Child = box });
            addRow.Children.Add(add);
            rows.Add(Row("Add a calendar link", "Paste a secret iCal (.ics) address.", null));
            rows.Add(new Border { Padding = new Thickness(14, 0, 14, 12), Child = addRow });
            s.Children.Add(Group(rows.ToArray()));
            if (CalendarService.Shared.LastError != null) s.Children.Add(Hint("Couldn't load a calendar: " + CalendarService.Shared.LastError));
            s.Children.Add(Hint("Google Calendar: Settings → your calendar → Integrate calendar → Secret address in iCal format.\n" +
                                "Outlook: Settings → Calendar → Shared calendars → Publish a calendar → ICS link.\n" +
                                "iCloud: Calendar on the web → Share → Public Calendar → copy the link."));
        }

        private static string Shorten(string url)
        {
            try
            {
                var u = new Uri(url);
                return u.Host + (u.AbsolutePath.Length > 24 ? u.AbsolutePath[..24] + "…" : u.AbsolutePath);
            }
            catch { return url; }
        }

        private Border UpdatesGroup()
        {
            var u = Updater.Shared;
            FrameworkElement action = u.ReadyVersion != null
                ? Button("Restart to Update", () => actions.InstallUpdate?.Invoke(), accent: true)
                : Button(u.Checking ? "Checking…" : "Check Now", () => { if (!u.Checking) actions.CheckForUpdates?.Invoke(); });
            string status = string.IsNullOrEmpty(u.Status) ? "Updates come from github.com/" + Updater.Repo + "." : u.Status;
            return Group(
                Row($"Docky {Updater.Current.ToString(3)}", status, action),
                Toggle("Update Docky automatically", "Checks GitHub every few hours, downloads new versions in the background and installs them when Docky restarts.",
                       S.AutoUpdate, (x, v) => x.AutoUpdate = v));
        }

        private void About(StackPanel s)
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 20, 0, 0) };
            row.Children.Add(new Image { Source = Onboarding.AppIcon(), Width = 84, Height = 84 });
            var texts = new StackPanel { Margin = new Thickness(18, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
            texts.Children.Add(Theme.Text("Docky", 26, FontWeights.Bold, Brushes.White, true));
            texts.Children.Add(Theme.Text($"Version {Updater.Current.ToString(3)} for Windows", 12.5, FontWeights.Normal, Theme.White(0.55)));
            texts.Children.Add(Theme.Text("A Dynamic Island for your PC.", 12.5, FontWeights.Normal, Theme.White(0.55)));
            row.Children.Add(texts);
            s.Children.Add(row);
            s.Children.Add(SectionTitle("Tips"));
            s.Children.Add(Group(
                Row("Open the island", "Point at it and scroll down, click it, or drag down.", null),
                Row("Keep files", "Drag files onto the island. Drag them back out to use them, or onto Share.", null),
                Row("Volume and brightness", "Point at the indicator and scroll or drag to adjust.", null),
                Row("Pomodoro", "Timers tab → Pomodoro. When focus ends you'll get a warm glow and \"Time for a break\".", null)));
        }

        private static TextBlock Hint(string text)
        {
            var t = Theme.Text(text, 11.5, FontWeights.Normal, Theme.White(0.45));
            t.TextWrapping = TextWrapping.Wrap;
            t.TextTrimming = TextTrimming.None;
            t.Margin = new Thickness(4, 10, 4, 0);
            t.LineHeight = 18;
            return t;
        }
    }
}
