using System;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Threading;
using Docky.Core;
using Docky.Services;

namespace Docky.Island
{
    public enum Pres { Hidden, Idle, Music, Timer, Pomodoro, Hud, Peek, Expanded, Alert, Notice, Break, Onboarding, OnboardingDemo }
    public enum Tab { NowPlaying, Timers, Reminders, Calendar, Clipboard }

    /// <summary>
    /// The island: a transparent, always-on-top, non-activating window at the top centre of the
    /// screen. Transparent pixels let clicks through; only the black island takes the mouse.
    /// Every morph is a spring (width, height, corner radius), stepped once per frame.
    /// </summary>
    public sealed class IslandWindow : Window
    {
        public const double WinW = 820, WinH = 520;
        private const double TopOffset = 8;

        private readonly Canvas root = new() { Width = WinW, Height = WinH, Background = Brushes.Transparent };
        private readonly Border shape = new() { Background = Brushes.Black, SnapsToDevicePixels = false };
        private readonly Grid host = new() { ClipToBounds = false };
        private readonly Border bubble = new() { Background = Brushes.Black, Opacity = 0 };
        private readonly DropShadowEffect shadow = new() { BlurRadius = 32, ShadowDepth = 10, Direction = 270, Opacity = 0, Color = Colors.Black };
        private readonly Spring sw = new(112), sh = new(34), sr = new(17), sy = new(0), sshadow = new(0), sbubble = new(0);
        private readonly ScaleTransform shapeScale = new(1, 1);
        private bool rendering;
        private TimeSpan lastFrame;

        private FrameworkElement current;
        private string currentKey;

        // State
        public Pres Presentation { get; private set; } = Pres.Idle;
        public Tab Tab { get; private set; } = Tab.NowPlaying;
        public string TimersMode = "timers";
        public string RemindersMode = "reminders";
        public bool Expanded { get; private set; }
        public bool Hovering { get; private set; }
        public bool Editing { get; private set; }
        public bool MusicRetracted { get; private set; }
        public bool IntroHidden;
        /// <summary>While the intro plays the island stays visible even if it would normally hide.</summary>
        public bool IntroActive;
        public bool BreakCard { get; private set; }
        public int? OnboardingStep { get; private set; }
        private bool demoShrink;
        private bool peeking;
        private HudEvent hud;
        private bool adjustingLevel;
        private double dragStretch, scrollStretch;
        public Size TargetSize { get; private set; }
        public double TargetRadius { get; private set; }

        private readonly DispatcherTimer hoverTimer = new(), collapseTimer = new(), hudTimer = new(), peekTimer = new(),
            outsideTimer = new() { Interval = TimeSpan.FromMilliseconds(60) }, topmostTimer = new() { Interval = TimeSpan.FromSeconds(2) },
            demoTimer = new(), lingerTimer = new() { Interval = TimeSpan.FromSeconds(1) };

        public IntPtr Handle { get; private set; }
        public event Action OpenSettingsRequested;
        public event Action<bool> BreakGlowRequested;

        public IslandWindow()
        {
            WindowStyle = WindowStyle.None;
            AllowsTransparency = true;
            Background = Brushes.Transparent;
            Topmost = true;
            ShowInTaskbar = false;
            ShowActivated = false;
            ResizeMode = ResizeMode.NoResize;
            Width = WinW;
            Height = WinH;
            Title = "Docky";
            Content = root;
            AllowDrop = true;

            shape.Child = host;
            shape.Effect = shadow;
            shape.RenderTransform = shapeScale;
            shape.RenderTransformOrigin = new Point(0.5, 0);
            root.Children.Add(bubble);
            root.Children.Add(shape);

            PlaceOnScreen();
            Wire();
            Recompute(true);
        }

        public void PlaceOnScreen()
        {
            var area = SystemParameters.WorkArea;
            Left = Math.Round((SystemParameters.PrimaryScreenWidth - WinW) / 2);
            Top = 0;
        }

        protected override void OnSourceInitialized(EventArgs e)
        {
            base.OnSourceInitialized(e);
            Handle = new WindowInteropHelper(this).Handle;
            Native.MakeToolWindow(Handle, noActivate: true);
            HwndSource.FromHwnd(Handle)?.AddHook(WndProc);
        }

        private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
        {
            if (msg == Native.WM_MOUSEHWHEEL && Hovering)
            {
                int delta = (short)((wParam.ToInt64() >> 16) & 0xFFFF);
                HorizontalScroll(delta);
                handled = true;
            }
            return IntPtr.Zero;
        }

        // MARK: Wiring

        private void Wire()
        {
            shape.MouseEnter += (_, _) => SetHover(true);
            shape.MouseLeave += (_, _) => SetHover(false);
            bubble.MouseEnter += (_, _) => SetHover(true);
            bubble.MouseLeave += (_, _) => SetHover(false);
            bubble.MouseLeftButtonUp += (_, _) => Expand(Tab.Timers);

            shape.MouseLeftButtonDown += OnDown;
            shape.MouseMove += OnMove;
            shape.MouseLeftButtonUp += OnUp;
            PreviewMouseWheel += OnWheel;

            shape.AllowDrop = true;
            shape.DragEnter += (_, e) => { if (!Expanded || Tab != Tab.Clipboard) Expand(Tab.Clipboard, haptic: false); e.Effects = DragDropEffects.Copy; };
            shape.DragOver += (_, e) => { e.Effects = DragDropEffects.Copy; e.Handled = true; };
            shape.Drop += (_, e) => { ShelfService.Shared.Accept(e.Data); e.Handled = true; };

            hoverTimer.Tick += (_, _) => { hoverTimer.Stop(); if (Hovering && CanExpand && hud == null) Expand(); };
            collapseTimer.Tick += (_, _) =>
            {
                collapseTimer.Stop();
                if (Hovering || Editing) return;
                if (Native.GetAsyncKeyState(Native.VK_LBUTTON) < 0) { collapseTimer.Start(); return; }
                Collapse();
            };
            hudTimer.Tick += (_, _) => { hudTimer.Stop(); if (Hovering || adjustingLevel) return; hud = null; Recompute(); };
            peekTimer.Tick += (_, _) => { peekTimer.Stop(); peeking = false; Recompute(); };
            demoTimer.Tick += (_, _) => { demoTimer.Stop(); demoShrink = false; Recompute(); };
            lingerTimer.Tick += (_, _) => { if (Presentation == Pres.Music && !MusicActive) Recompute(); };
            lingerTimer.Start();
            outsideTimer.Tick += (_, _) => CheckClickOutside();
            topmostTimer.Tick += (_, _) => { if (Handle != IntPtr.Zero) Native.SetWindowPos(Handle, Native.HWND_TOPMOST, 0, 0, 0, 0, Native.SWP_NOMOVE | Native.SWP_NOSIZE | Native.SWP_NOACTIVATE); };
            topmostTimer.Start();

            MediaService.Shared.Changed += OnMediaChanged;
            ClockService.Shared.Changed += () => Recompute();
            ClockService.Shared.BreakStarted += StartBreak;
            SettingsStore.Changed += () => { Recompute(); };
            SystemMonitor.Shared.FullscreenChanged += _ => Recompute();
            SystemMonitor.Shared.Event += ShowHud;
            ShelfService.Shared.Changed += () => { if (Expanded && Tab == Tab.Clipboard) Rebuild(); };
            CalendarService.Shared.Changed += () => { if (Expanded && Tab == Tab.Calendar) Rebuild(); };
        }

        private int lastTrackChanges;
        private void OnMediaChanged()
        {
            var m = MediaService.Shared;
            if (m.TrackChanges != lastTrackChanges)
            {
                lastTrackChanges = m.TrackChanges;
                var s = SettingsStore.Current;
                if (s.TrackChangePeek && s.ShowTitle && !Hovering && !Expanded && !MusicRetracted && Presentation is Pres.Music or Pres.Idle or Pres.Timer or Pres.Peek)
                {
                    peeking = true;
                    peekTimer.Stop();
                    peekTimer.Interval = TimeSpan.FromSeconds(3.2);
                    peekTimer.Start();
                }
            }
            Recompute();
            if (Expanded && Tab == Tab.NowPlaying) RefreshContent();
        }

        // MARK: State

        private static Settings S => SettingsStore.Current;
        private double Scale => Math.Clamp(S.IslandScale, 0.8, 1.3);
        public double Band => 34 * Scale;

        public bool MusicActive
        {
            get
            {
                var m = MediaService.Shared;
                if (!S.NowPlayingEnabled || m.Current == null) return false;
                if (m.Current.IsPlaying) return true;
                return m.PausedAt is DateTime p && (DateTime.Now - p).TotalSeconds < S.PausedLinger;
            }
        }

        public bool IsLevelHud => Presentation == Pres.Hud && hud?.Level != null;
        public HudEvent Hud => hud;
        public bool CanExpand => Presentation is not (Pres.Alert or Pres.Notice or Pres.Break or Pres.Onboarding or Pres.OnboardingDemo);

        private Pres Compute()
        {
            var clock = ClockService.Shared;
            if (clock.Alerts.Count > 0) return Pres.Alert;
            if (noticeKey != null) return Pres.Notice;
            if (OnboardingStep != null) return demoShrink ? Pres.OnboardingDemo : Pres.Onboarding;
            if (BreakCard) return Pres.Break;
            if (Expanded) return Pres.Expanded;
            if (hud != null) return Pres.Hud;
            if (MusicRetracted && !MusicActive) MusicRetracted = false;
            if (peeking && MusicActive && !MusicRetracted) return Pres.Peek;
            if (SystemMonitor.Shared.FullscreenActive && !Hovering && !IntroHidden && !IntroActive) return Pres.Hidden;
            if (MusicActive && !MusicRetracted) return Pres.Music;
            if (clock.Session != null) return Pres.Pomodoro;
            if (clock.ActiveTimer != null) return Pres.Timer;
            return S.HideWhenIdle && !Hovering && !IntroHidden && !IntroActive ? Pres.Hidden : Pres.Idle;
        }

        private string ContentKey(Pres p) => p switch
        {
            Pres.Expanded => "expanded-" + Tab + "-" + TimersMode + "-" + RemindersMode,
            Pres.Hud => "hud-" + hud?.Type + (hud?.Level == null ? hud?.Title + hud?.Detail : ""),
            Pres.Alert => "alert-" + ClockService.Shared.Alerts.FirstOrDefault()?.Key,
            Pres.Onboarding => "onboarding-" + OnboardingStep,
            Pres.Notice => "notice-" + noticeKey,
            Pres.Music => "music-" + MediaService.Shared.Current?.TrackKey,
            Pres.Hidden => "idle",
            _ => p.ToString(),
        };

        public void Recompute(bool snap = false)
        {
            var p = Compute();
            Presentation = p;
            double H = Band, s = Scale;
            Size size;
            double radius;
            switch (p)
            {
                case Pres.Music: size = new Size((S.ShowTitle ? 236 : 180) * s, H); break;
                case Pres.Timer:
                case Pres.Pomodoro: size = new Size(172 * s, H); break;
                case Pres.Hud: size = new Size((hud?.Level != null ? 268 : 312) * s, H); break;
                case Pres.Peek: size = new Size(350, 78); break;
                case Pres.Expanded: size = new Size(440, IslandViews.HeaderHeight + IslandViews.ContentHeight(this) + 20); break;
                case Pres.Alert: size = new Size(410, 98); break;
                case Pres.Notice:
                case Pres.Break: size = new Size(440, 104); break;
                case Pres.Onboarding: size = new Size(580, Onboarding.Height(OnboardingStep ?? 0)); break;
                case Pres.OnboardingDemo: size = new Size((S.ShowTitle ? 236 : 180) * s, H); break;
                default: size = new Size(112 * s, H); break;
            }
            bool compact = p is Pres.Idle or Pres.Hidden or Pres.Music or Pres.Timer or Pres.Pomodoro or Pres.Hud or Pres.OnboardingDemo;
            if (compact && Hovering && S.HoverGrow && p != Pres.Hidden) size = new Size(size.Width + 10 * s, size.Height + 3 * s);
            if (compact && scrollStretch > 0) size = new Size(size.Width + 12 * scrollStretch, size.Height + 12 * scrollStretch);
            if (compact && dragStretch != 0) size = new Size(Math.Max(60, size.Width + 26 * dragStretch), size.Height);
            radius = p switch
            {
                Pres.Expanded => 34, Pres.Alert or Pres.Notice or Pres.Break => 32, Pres.Peek => 26, Pres.Onboarding => 38,
                _ => size.Height / 2,
            };
            TargetSize = size;
            TargetRadius = radius;

            var (response, damping) = S.Spring;
            foreach (var spring in new[] { sw, sh, sr })
            {
                spring.Response = response;
                spring.Damping = damping;
            }
            sw.Target = size.Width;
            sh.Target = size.Height;
            sr.Target = radius;
            sshadow.Target = compact ? 0 : 0.55;
            sy.Target = IntroHidden ? -(size.Height + TopOffset + 30) : 0;
            sy.Response = 0.6; sy.Damping = 0.68;
            sbubble.Target = p == Pres.Music && S.ShowTimerBubble && (ClockService.Shared.ActiveTimer != null || ClockService.Shared.Session != null) ? 1 : 0;
            sbubble.Response = 0.45; sbubble.Damping = 0.8;
            shape.Opacity = p == Pres.Hidden ? 0.012 : 1;

            if (snap) { sw.Snap(size.Width); sh.Snap(size.Height); sr.Snap(radius); }

            string key = ContentKey(p);
            if (key != currentKey) Swap(IslandViews.Build(this, p), key);

            outsideTimer.IsEnabled = Expanded;
            StartRendering();
        }

        /// <summary>Rebuild the current content in place (e.g. a list changed).</summary>
        public void Rebuild() { currentKey = null; Recompute(); }

        /// <summary>Refresh without the swap animation (live data inside the same view).</summary>
        public void RefreshContent()
        {
            if (current == null) return;
            var next = IslandViews.Build(this, Presentation);
            host.Children.Remove(current);
            Prepare(next);
            next.Opacity = 1;
            host.Children.Add(next);
            current = next;
        }

        // MARK: Rendering

        private void StartRendering()
        {
            if (rendering) return;
            rendering = true;
            lastFrame = TimeSpan.Zero;
            CompositionTarget.Rendering += OnFrame;
        }

        private void OnFrame(object sender, EventArgs e)
        {
            var now = ((RenderingEventArgs)e).RenderingTime;
            double dt = lastFrame == TimeSpan.Zero ? 1 / 60.0 : Math.Min(0.05, (now - lastFrame).TotalSeconds);
            if (dt <= 0) return;
            lastFrame = now;
            sw.Step(dt); sh.Step(dt); sr.Step(dt); sy.Step(dt); sshadow.Step(dt); sbubble.Step(dt);
            Apply();
            if (sw.IsSettled && sh.IsSettled && sr.IsSettled && sy.IsSettled && sshadow.IsSettled && sbubble.IsSettled)
            {
                CompositionTarget.Rendering -= OnFrame;
                rendering = false;
            }
        }

        private void Apply()
        {
            double w = Math.Max(20, sw.Value), h = Math.Max(12, sh.Value), r = Math.Clamp(sr.Value, 0, Math.Min(w, h) / 2);
            shape.Width = w;
            shape.Height = h;
            shape.CornerRadius = new CornerRadius(r);
            host.Clip = new RectangleGeometry(new Rect(0, 0, w, h), r, r);
            Canvas.SetLeft(shape, (WinW - w) / 2);
            Canvas.SetTop(shape, TopOffset + sy.Value);
            shadow.Opacity = Math.Clamp(sshadow.Value, 0, 1);

            double b = Band;
            double bv = Math.Clamp(sbubble.Value, 0, 1);
            bubble.Width = bubble.Height = b;
            bubble.CornerRadius = new CornerRadius(b / 2);
            bubble.Opacity = bv;
            bubble.IsHitTestVisible = bv > 0.5;
            Canvas.SetLeft(bubble, (WinW + w) / 2 + 7 - (1 - bv) * b);
            Canvas.SetTop(bubble, TopOffset + sy.Value);
            if (bubble.Child == null && bv > 0) bubble.Child = IslandViews.Bubble(this);
            if (bv <= 0.01) bubble.Child = null;
        }

        private static void Prepare(FrameworkElement next)
        {
            next.HorizontalAlignment = HorizontalAlignment.Center;
            next.VerticalAlignment = VerticalAlignment.Top;
        }

        /// <summary>The Dynamic Island content swap: old content blurs and shrinks away fast, new
        /// content blooms in just after the shape starts moving.</summary>
        private void Swap(FrameworkElement next, string key)
        {
            currentKey = key;
            var old = current;
            if (old != null)
            {
                old.IsHitTestVisible = false;
                var oldScale = new ScaleTransform(1, 1);
                old.RenderTransform = oldScale;
                old.RenderTransformOrigin = new Point(0.5, 0.3);
                var blur = new BlurEffect { Radius = 0 };
                old.Effect = blur;
                Anim.To(old, OpacityProperty, 0, 140);
                Anim.To(oldScale, ScaleTransform.ScaleXProperty, 0.88, 140);
                Anim.To(oldScale, ScaleTransform.ScaleYProperty, 0.88, 140);
                Anim.To(blur, BlurEffect.RadiusProperty, 9, 140, done: () => host.Children.Remove(old));
            }
            Prepare(next);
            var scale = new ScaleTransform(0.88, 0.88);
            next.RenderTransform = scale;
            next.RenderTransformOrigin = new Point(0.5, 0.2);
            var inBlur = new BlurEffect { Radius = 10 };
            next.Effect = inBlur;
            next.Opacity = 0;
            host.Children.Add(next);
            current = next;
            var ease = new BackEase { Amplitude = 0.15, EasingMode = EasingMode.EaseOut };
            Anim.To(next, OpacityProperty, 1, 320, delayMs: 50);
            Anim.To(scale, ScaleTransform.ScaleXProperty, 1, 380, ease, 50);
            Anim.To(scale, ScaleTransform.ScaleYProperty, 1, 380, ease, 50);
            Anim.To(inBlur, BlurEffect.RadiusProperty, 0, 300, delayMs: 50, done: () => { if (next.Effect == inBlur) next.Effect = null; });
        }

        // MARK: Hover, expand, collapse

        private void SetHover(bool on)
        {
            bool inside = shape.IsMouseOver || bubble.IsMouseOver;
            if (!on && inside) return;
            if (on == Hovering) return;
            Hovering = on;
            hoverTimer.Stop();
            collapseTimer.Stop();
            if (on)
            {
                if (hud != null) hudTimer.Stop();
                if (S.HoverToOpen && !Expanded && CanExpand && hud == null)
                {
                    hoverTimer.Interval = TimeSpan.FromSeconds(Math.Max(0.1, S.HoverDelay));
                    hoverTimer.Start();
                }
            }
            else
            {
                scrollStretch = 0;
                if (Expanded && !Editing)
                {
                    collapseTimer.Interval = TimeSpan.FromSeconds(Math.Max(0.05, S.CollapseDelay));
                    collapseTimer.Start();
                }
                if (hud != null && !adjustingLevel) { hudTimer.Interval = TimeSpan.FromSeconds(0.9); hudTimer.Start(); }
            }
            Recompute();
        }

        public void Expand(Tab? tab = null, bool haptic = true)
        {
            if (!CanExpand) return;
            if (tab is Tab t) Tab = t;
            else if (Presentation == Pres.Timer || Presentation == Pres.Pomodoro) { Tab = Tab.Timers; TimersMode = Presentation == Pres.Pomodoro ? "pomodoro" : "timers"; }
            else if (Presentation is Pres.Music or Pres.Peek) Tab = Tab.NowPlaying;
            if (Tab == Tab.Calendar && !S.ShowCalendar) Tab = Tab.NowPlaying;
            peeking = false;
            Expanded = true;
            Recompute();
        }

        public void Collapse()
        {
            collapseTimer.Stop();
            if (!Expanded && !Editing) return;
            EndEditing();
            Expanded = false;
            Recompute();
        }

        public void SelectTab(Tab tab)
        {
            Tab = tab;
            Recompute();
        }

        public void SetTimersMode(string mode) { TimersMode = mode; Recompute(); }
        public void SetRemindersMode(string mode) { RemindersMode = mode; Recompute(); }

        private void CheckClickOutside()
        {
            if (!Expanded || Editing) return;
            if (Native.GetAsyncKeyState(Native.VK_LBUTTON) >= 0) return;
            Native.GetCursorPos(out var p);
            var topLeft = shape.PointToScreen(new Point(0, 0));
            var dpi = VisualTreeHelper.GetDpi(this);
            var rect = new Rect(topLeft.X - 4, topLeft.Y - 4, shape.ActualWidth * dpi.DpiScaleX + 8, shape.ActualHeight * dpi.DpiScaleY + 8);
            if (!rect.Contains(new Point(p.X, p.Y))) Collapse();
        }

        // MARK: Keyboard focus for typing (reminders)

        public void BeginEditing()
        {
            if (Editing) return;
            Editing = true;
            Native.MakeToolWindow(Handle, noActivate: false);
            Activate();
        }

        public void EndEditing()
        {
            if (!Editing) return;
            Editing = false;
            Native.MakeToolWindow(Handle, noActivate: true);
            Keyboard.ClearFocus();
        }

        // MARK: Mouse gestures

        private Point? downAt;
        private bool dragging;

        private void OnDown(object sender, MouseButtonEventArgs e)
        {
            downAt = e.GetPosition(shape);
            dragging = false;
            shape.CaptureMouse();
        }

        private void OnMove(object sender, MouseEventArgs e)
        {
            if (downAt is not Point start || e.LeftButton != MouseButtonState.Pressed) return;
            var p = e.GetPosition(shape);
            var d = p - start;
            if (!dragging && d.Length < 8) return;
            dragging = true;
            hoverTimer.Stop();
            double side = start.X >= shape.ActualWidth / 2 ? 1 : -1;
            double outward = side * d.X;
            if (Presentation == Pres.Music)
            {
                double inward = Math.Max(-outward, -d.Y);
                SetDragStretch(Math.Clamp(-inward / 70, -1, 0.35));
            }
            else if (CanRestoreMusic) SetDragStretch(Math.Clamp(outward / 70, -0.35, 1));
        }

        private void OnUp(object sender, MouseButtonEventArgs e)
        {
            shape.ReleaseMouseCapture();
            if (downAt is not Point start) return;
            downAt = null;
            var d = e.GetPosition(shape) - start;
            if (!dragging)
            {
                if (S.ClickToOpen && !Expanded && CanExpand && !IsLevelHud) Expand();
                return;
            }
            dragging = false;
            double side = start.X >= shape.ActualWidth / 2 ? 1 : -1;
            double outward = side * d.X;
            double inward = Math.Max(-outward, -d.Y);
            SetDragStretch(0);
            if (Presentation == Pres.Break && d.Y < -24) { DismissBreak(); return; }
            if (Presentation == Pres.Music && inward >= 40) { Retract(); return; }
            if (CanRestoreMusic && outward >= 40) { Restore(); return; }
            if (d.Y > 34 && Math.Abs(d.X) < d.Y && CanExpand && !Expanded) Expand();
        }

        private void SetDragStretch(double v)
        {
            dragStretch = v;
            Recompute();
        }

        private bool CanRestoreMusic => MusicRetracted && MusicActive && Presentation is Pres.Idle or Pres.Timer or Pres.Pomodoro or Pres.Hidden;

        public void Retract() { MusicRetracted = true; peeking = false; dragStretch = 0; Recompute(); }
        public void Restore() { MusicRetracted = false; dragStretch = 0; Recompute(); }

        private double wheelAccumulator;
        private DateTime lastWheel;

        private void OnWheel(object sender, MouseWheelEventArgs e)
        {
            if (!Hovering) return;
            if (IsLevelHud)
            {
                SetHudLevel((hud.Level ?? 0) + e.Delta / 120.0 * 0.04);
                e.Handled = true;
                return;
            }
            if (Expanded)
            {
                // Lists inside the island scroll normally.
                if (e.OriginalSource is DependencyObject src && FindScroll(src) != null) return;
                e.Handled = true;
                return;
            }
            e.Handled = true;
            if ((DateTime.Now - lastWheel).TotalMilliseconds > 400) wheelAccumulator = 0;
            lastWheel = DateTime.Now;
            wheelAccumulator += Math.Abs(e.Delta);
            if (Presentation == Pres.Break) { if (wheelAccumulator >= 120) DismissBreak(); return; }
            if (!S.ScrollToOpen || !CanExpand) return;
            scrollStretch = Math.Min(1, wheelAccumulator / 240);
            Recompute();
            if (wheelAccumulator >= 120) { wheelAccumulator = 0; scrollStretch = 0; Expand(); }
        }

        private static ScrollViewer FindScroll(DependencyObject d)
        {
            while (d != null)
            {
                if (d is ScrollViewer sv && sv.ScrollableHeight > 0) return sv;
                d = d is Visual || d is System.Windows.Media.Media3D.Visual3D ? VisualTreeHelper.GetParent(d) : LogicalTreeHelper.GetParent(d);
            }
            return null;
        }

        private double hAccumulator;
        private DateTime lastHWheel;

        private void HorizontalScroll(int delta)
        {
            if (IsLevelHud) { SetHudLevel((hud.Level ?? 0) + delta / 120.0 * 0.04); return; }
            if (Expanded) return;
            if ((DateTime.Now - lastHWheel).TotalMilliseconds > 400) hAccumulator = 0;
            lastHWheel = DateTime.Now;
            hAccumulator += delta;
            Native.GetCursorPos(out var p);
            var center = shape.PointToScreen(new Point(shape.ActualWidth / 2, 0));
            double side = p.X >= center.X ? 1 : -1;
            double outward = side * hAccumulator;
            if (Presentation == Pres.Music)
            {
                SetDragStretch(Math.Clamp(outward / 300, -1, 0.35));
                if (outward <= -180) { hAccumulator = 0; Retract(); }
            }
            else if (CanRestoreMusic)
            {
                SetDragStretch(Math.Clamp(outward / 300, -0.35, 1));
                if (outward >= 180) { hAccumulator = 0; Restore(); }
            }
            var reset = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(420) };
            reset.Tick += (_, _) => { reset.Stop(); if ((DateTime.Now - lastHWheel).TotalMilliseconds > 380 && dragStretch != 0) SetDragStretch(0); };
            reset.Start();
        }

        // MARK: Indicators (HUD)

        public void ShowHud(HudEvent e)
        {
            if (Presentation is Pres.Onboarding or Pres.OnboardingDemo) return;
            hud = e;
            hudTimer.Stop();
            if (!Hovering && !adjustingLevel)
            {
                hudTimer.Interval = TimeSpan.FromSeconds(e.Level != null ? 1.5 : 2.6);
                hudTimer.Start();
            }
            if (Presentation == Pres.Hud && hud.Level != null && current is IslandViews.HudView view) { view.Update(hud); Recompute(); return; }
            Recompute();
        }

        public void SetHudLevel(double level)
        {
            if (hud?.Level == null) return;
            level = Math.Clamp(level, 0, 1);
            hud.Level = level;
            if (hud.Type == HudEvent.Kind.Volume) { VolumeService.Shared.SetLevel(level); hud.Glyph = G.VolumeFor(level); }
            else if (hud.Type == HudEvent.Kind.Brightness) BrightnessService.Shared.Set(level);
            if (current is IslandViews.HudView view) view.Update(hud);
        }

        public void SetAdjustingLevel(bool on)
        {
            adjustingLevel = on;
            if (on) hudTimer.Stop();
            else if (!Hovering) { hudTimer.Interval = TimeSpan.FromSeconds(1.2); hudTimer.Start(); }
        }

        // MARK: Notices, breaks, onboarding

        private string noticeKey;
        public string NoticeTitle, NoticeMessage, NoticeAction, NoticeGlyph = G.Shield;
        private Action noticeCallback;

        public void ShowNotice(string key, string title, string message, string action, Action onAction, string glyph = null)
        {
            noticeKey = key; NoticeTitle = title; NoticeMessage = message; NoticeAction = action; noticeCallback = onAction;
            NoticeGlyph = glyph ?? G.Shield;
            Recompute();
        }

        public void ResolveNotice(bool acted)
        {
            var cb = noticeCallback;
            noticeKey = null; noticeCallback = null;
            Recompute();
            if (acted) cb?.Invoke();
        }

        private void StartBreak()
        {
            Collapse();
            BreakCard = true;
            Recompute();
            if (ClockService.Shared.Pomodoro.BreakGlow) BreakGlowRequested?.Invoke(true);
            // The card (and glow) go when the break ends.
            var watch = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(500) };
            watch.Tick += (_, _) =>
            {
                var s = ClockService.Shared.Session;
                if (!BreakCard) { watch.Stop(); return; }
                if (s == null || !s.IsRest) { watch.Stop(); EndBreak(); }
            };
            watch.Start();
        }

        private void EndBreak()
        {
            if (!BreakCard) return;
            BreakCard = false;
            Recompute();
            BreakGlowRequested?.Invoke(false);
        }

        public void DismissBreak() => EndBreak();

        public void StartOnboarding()
        {
            Collapse();
            hud = null;
            OnboardingStep = 0;
            Recompute();
        }

        public void OnboardingGo(int delta)
        {
            if (OnboardingStep is not int step) return;
            int next = step + delta;
            if (next >= Onboarding.StepCount) { FinishOnboarding(); return; }
            if (next < 0) return;
            OnboardingStep = next;
            Recompute();
        }

        public void FinishOnboarding()
        {
            OnboardingStep = null;
            demoShrink = false;
            EndEditing();
            SettingsStore.Update(s => s.DidOnboard = true);
            Recompute();
        }

        /// <summary>Shrinks to the compact look for a moment and springs back, to show a choice.</summary>
        public void Demonstrate(double delay = 0.2)
        {
            var start = new DispatcherTimer { Interval = TimeSpan.FromSeconds(Math.Max(0.01, delay)) };
            start.Tick += (_, _) =>
            {
                start.Stop();
                if (OnboardingStep == null) return;
                demoShrink = true;
                Recompute();
                demoTimer.Stop();
                demoTimer.Interval = TimeSpan.FromSeconds(1.5);
                demoTimer.Start();
            };
            start.Start();
        }

        public void OpenSettings() { Collapse(); OpenSettingsRequested?.Invoke(); }

        // MARK: Intro

        /// <summary>Lifts the island off the top of the screen, ready to drop in.</summary>
        public void HideForIntro()
        {
            IntroActive = true;
            IntroHidden = true;
            Recompute();
            sy.Snap(sy.Target);
            Apply();
        }

        public void DropIn() { if (!IntroHidden) return; IntroHidden = false; Recompute(); }
        public void EndIntro() { IntroActive = false; Recompute(); }

        public void RaiseToTop()
        {
            if (Handle != IntPtr.Zero) Native.SetWindowPos(Handle, Native.HWND_TOPMOST, 0, 0, 0, 0, Native.SWP_NOMOVE | Native.SWP_NOSIZE | Native.SWP_NOACTIVATE);
        }
    }
}
