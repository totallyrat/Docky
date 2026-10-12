using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Docky.Core;
using Docky.Island;
using Docky.Services;

namespace Docky.Shell
{
    /// <summary>
    /// `Docky.exe --demo &lt;folder&gt;` walks through every state with made-up data and saves a
    /// screenshot of each, then quits. Used by CI as a smoke test and for visual checks.
    /// </summary>
    public sealed class Demo
    {
        public static Demo Current { get; private set; }
        private readonly App app;
        private readonly string dir;
        private readonly List<string> log = new();
        private bool failed;
        private IslandWindow Island => app.Island;

        public Demo(App app, string dir)
        {
            this.app = app;
            this.dir = dir;
            Current = this;
            Directory.CreateDirectory(dir);
        }

        public void Fail(Exception ex)
        {
            failed = true;
            Note("ERROR " + ex);
        }

        private void Note(string s)
        {
            log.Add($"{DateTime.Now:HH:mm:ss.fff} {s}");
            try { File.WriteAllLines(Path.Combine(dir, "log.txt"), log); } catch { }
        }

        public async Task Run()
        {
            var watchdog = new DispatcherTimer { Interval = TimeSpan.FromMinutes(5) };
            watchdog.Tick += (_, _) => { Note("TIMEOUT"); Application.Current.Shutdown(2); };
            watchdog.Start();
            try
            {
                SettingsStore.Current.HideInFullscreen = false;
                SettingsStore.Current.PlayIntro = false;
                SettingsStore.Current.DidOnboard = true;
                SettingsStore.Current.ReplaceVolumeOverlay = false;
                Note($"screen {SystemParameters.PrimaryScreenWidth}x{SystemParameters.PrimaryScreenHeight} dpi {VisualTreeHelper.GetDpi(Island).DpiScaleX} render tier {RenderCapability.Tier >> 16}");
                ShowBackdrop();
                await Steps();
            }
            catch (Exception ex) { Fail(ex); }
            Note(failed ? "FAILED" : "OK");
            Application.Current.Shutdown(failed ? 1 : 0);
        }

        private async Task Steps()
        {
            var clock = ClockService.Shared;
            await Shot("01-idle");

            MediaService.Shared.Inject(Track());
            await Shot("02-music");

            Island.Expand(Tab.NowPlaying);
            await Shot("03-now-playing");

            clock.StartTimer(300);
            clock.StartTimer(25 * 60, "Pasta");
            Island.SelectTab(Tab.Timers);
            Island.SetTimersMode("timers");
            Island.Rebuild();
            await Shot("04-timers");

            Island.SetTimersMode("pomodoro");
            await Shot("05-pomodoro-setup");
            clock.StartPomodoro();
            Island.Rebuild();
            await Shot("06-pomodoro-running");
            clock.StopPomodoro();

            clock.AddReminder("Call mom", DateTime.Today.AddHours(18));
            clock.AddReminder("Buy oat milk", null);
            clock.AddReminder("Send the report", DateTime.Today.AddDays(1).AddHours(9));
            Island.SelectTab(Tab.Reminders);
            Island.SetRemindersMode("reminders");
            Island.Rebuild();
            await Shot("07-reminders");

            clock.AddAlarm(new IslandAlarm { Hour = 7, Minute = 30, Label = "Wake up", RepeatDays = new List<int> { 1, 2, 3, 4, 5 } });
            clock.AddAlarm(new IslandAlarm { Hour = 9, Minute = 0, Enabled = false });
            Island.SetRemindersMode("alarms");
            await Shot("08-alarms");

            SettingsStore.Current.CalendarUrls.Add("demo");
            var now = DateTime.Now;
            CalendarService.Shared.Inject(new List<CalEvent>
            {
                new() { Title = "Design review", Start = now.AddMinutes(-20), End = now.AddMinutes(25), JoinUrl = "https://example.com", Color = Theme.Blue },
                new() { Title = "Lunch with Sam", Start = now.AddHours(2), End = now.AddHours(3), Location = "Café Linné", Color = Theme.Orange },
                new() { Title = "Gym", Start = now.AddHours(5), End = now.AddHours(6), Color = Theme.Green },
                new() { Title = "Release day", Start = DateTime.Today.AddDays(2), End = DateTime.Today.AddDays(3), AllDay = true, Color = Theme.Pink },
            });
            Island.SelectTab(Tab.Calendar);
            await Shot("09-calendar");

            ShelfService.Shared.Add(DemoFiles());
            Island.SelectTab(Tab.Clipboard);
            await Shot("10-clipboard");

            Island.Collapse();
            await Task.Delay(500);
            Island.ShowHud(new HudEvent { Type = HudEvent.Kind.Volume, Glyph = G.VolumeFor(0.62), Title = "Volume", Level = 0.62 });
            await Shot("11-volume", settle: 500);
            await Task.Delay(1600);
            Island.ShowHud(new HudEvent { Type = HudEvent.Kind.Device, Glyph = G.Headphones, Title = "AirPods Pro", Detail = "Connected", Tint = Theme.Blue });
            await Shot("12-device", settle: 600);
            await Task.Delay(2600);

            clock.FireTestAlarm();
            await Shot("13-alarm");
            foreach (var a in clock.Alerts.ToList()) clock.Dismiss(a);
            await Task.Delay(600);

            // Pomodoro break: a 2 s "focus", then the break card and the warm glow.
            clock.StartPomodoroSeconds(2, 40);
            await Shot("14-pomodoro-compact", settle: 900);
            await Task.Delay(2600);
            await Shot("15-break-full", full: true, settle: 1800);
            await Shot("15-break-island");
            Island.DismissBreak();
            await Shot("16-after-break-full", full: true, settle: 1600);
            clock.StopPomodoro();
            MediaService.Shared.Inject(new MediaInfo());

            // Setup inside the island
            Island.StartOnboarding();
            for (int step = 0; step < Onboarding.StepCount; step++)
            {
                await Shot($"20-setup-{step}", settle: 1000);
                if (step == 2)
                {
                    Island.Demonstrate(0);
                    await Shot("21-setup-demo", settle: 450);
                    await Task.Delay(1500);
                }
                if (step < Onboarding.StepCount - 1) Island.OnboardingGo(1);
            }
            Island.FinishOnboarding();
            await Task.Delay(800);

            // The intro, sampled over time.
            int frames = 0;
            void Count(object s, EventArgs e) => frames++;
            CompositionTarget.Rendering += Count;
            var sw = Stopwatch.StartNew();
            bool introDone = false;
            app.Intro.Play(Island, () => introDone = true);
            Note($"intro setup took {sw.Elapsed.TotalMilliseconds:0} ms");
            sw.Restart();
            foreach (var at in new[] { 0.3, 0.6, 0.9, 1.2, 1.6, 2.3, 3.2, 5.4 })
            {
                double wait = at * 1000 - sw.Elapsed.TotalMilliseconds;
                if (wait > 0) await Task.Delay((int)wait);
                Capture(Path.Combine(dir, $"30-intro-{at:0.0}s.png"), null);
            }
            while (!introDone && sw.Elapsed.TotalSeconds < 12) await Task.Delay(100);
            CompositionTarget.Rendering -= Count;
            Note($"intro: {frames} frames in {sw.Elapsed.TotalSeconds:0.0}s (lite {app.Intro.Lite})");

            // The same again without screenshots, to measure frame pacing.
            frames = 0;
            introDone = false;
            CompositionTarget.Rendering += Count;
            sw.Restart();
            app.Intro.Play(Island, () => introDone = true);
            while (!introDone && sw.Elapsed.TotalSeconds < 12) await Task.Delay(100);
            CompositionTarget.Rendering -= Count;
            Note($"intro (no captures): {frames} frames in {sw.Elapsed.TotalSeconds:0.0}s = {frames / sw.Elapsed.TotalSeconds:0} fps (lite {app.Intro.Lite})");

            frames = 0;
            app.Glow.Show();
            await Task.Delay(1800);
            CompositionTarget.Rendering += Count;
            sw.Restart();
            await Task.Delay(3000);
            CompositionTarget.Rendering -= Count;
            Note($"break glow: {frames / sw.Elapsed.TotalSeconds:0} frames/s while breathing");
            app.Glow.Hide();
            await Task.Delay(1400);

            // Settings
            foreach (var page in new[] { "General", "Island", "Now Playing", "Indicators", "Timers & Pomodoro", "Calendar", "About" })
            {
                var win = app.ShowSettings(page);
                await Task.Delay(900);
                var rect = new Rect(win.Left, win.Top, win.ActualWidth, win.ActualHeight);
                Capture(Path.Combine(dir, $"40-settings-{page.Replace(" & ", "-").Replace(' ', '-').ToLowerInvariant()}.png"), rect);
            }
            Note("done");
        }

        // MARK: Capture

        private async Task Shot(string name, bool full = false, int settle = 1100)
        {
            await Task.Delay(settle);
            Rect? rect = full ? null : new Rect(Island.Left, Island.Top, IslandWindow.WinW, 360);
            Capture(Path.Combine(dir, name + ".png"), rect);
            var hud = Island.Hud;
            Note($"{name}: {Island.Presentation} {Island.TargetSize.Width:0}x{Island.TargetSize.Height:0}" + (hud != null ? $" hud={hud.Type} '{hud.Title}' '{hud.Detail}'" : ""));
        }

        private void Capture(string path, Rect? dips)
        {
            try
            {
                double scale = VisualTreeHelper.GetDpi(Island).DpiScaleX;
                var screen = System.Windows.Forms.Screen.PrimaryScreen.Bounds;
                var r = dips is Rect d
                    ? new System.Drawing.Rectangle((int)(d.X * scale), (int)(d.Y * scale), (int)(d.Width * scale), (int)(d.Height * scale))
                    : screen;
                r.Intersect(screen);
                if (r.Width <= 0 || r.Height <= 0) return;
                using var bmp = new System.Drawing.Bitmap(r.Width, r.Height);
                using (var g = System.Drawing.Graphics.FromImage(bmp))
                {
                    // CAPTUREBLT includes layered (transparent) windows like the island and glows.
                    IntPtr dst = g.GetHdc(), src = GetDC(IntPtr.Zero);
                    BitBlt(dst, 0, 0, r.Width, r.Height, src, r.X, r.Y, 0x00CC0020 | 0x40000000);
                    ReleaseDC(IntPtr.Zero, src);
                    g.ReleaseHdc(dst);
                }
                bmp.Save(path, System.Drawing.Imaging.ImageFormat.Png);
            }
            catch (Exception ex) { Note("capture failed: " + ex.Message); }
        }

        [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern IntPtr GetDC(IntPtr hwnd);
        [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern int ReleaseDC(IntPtr hwnd, IntPtr dc);
        [System.Runtime.InteropServices.DllImport("gdi32.dll")] private static extern bool BitBlt(IntPtr dst, int x, int y, int w, int h, IntPtr src, int sx, int sy, int rop);

        // MARK: Made-up content

        /// <summary>A soft, colourful "wallpaper" so the black island reads like it would on a real desktop.</summary>
        private static void ShowBackdrop()
        {
            var canvas = new System.Windows.Controls.Grid
            {
                Background = new LinearGradientBrush(Color.FromRgb(58, 72, 120), Color.FromRgb(150, 96, 140), 35),
            };
            void Blob(Color c, double x, double y, double r)
            {
                canvas.Children.Add(new System.Windows.Shapes.Ellipse
                {
                    Width = r * 2, Height = r * 2, HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top,
                    Margin = new Thickness(x - r, y - r, 0, 0),
                    Fill = new RadialGradientBrush(Color.FromArgb(150, c.R, c.G, c.B), Color.FromArgb(0, c.R, c.G, c.B)),
                });
            }
            double W = SystemParameters.PrimaryScreenWidth, H = SystemParameters.PrimaryScreenHeight;
            Blob(Color.FromRgb(255, 170, 120), W * 0.2, H * 0.75, H * 0.6);
            Blob(Color.FromRgb(120, 200, 255), W * 0.85, H * 0.2, H * 0.55);
            Blob(Color.FromRgb(200, 140, 255), W * 0.6, H * 0.9, H * 0.5);
            var window = new Window
            {
                WindowStyle = WindowStyle.None, ResizeMode = ResizeMode.NoResize, ShowInTaskbar = false, ShowActivated = false,
                Left = 0, Top = 0, Width = W, Height = H, Content = canvas, Title = "Backdrop",
            };
            window.Show();
            Application.Current.Windows.OfType<IslandWindow>().FirstOrDefault()?.RaiseToTop();
        }

        private static MediaInfo Track()
        {
            var art = Artwork();
            return new MediaInfo
            {
                Title = "Midnight City", Artist = "M83", Album = "Hurry Up, We're Dreaming", AppId = "Spotify.exe",
                IsPlaying = true, Duration = 243, Position = 71, PositionStamp = DateTime.Now, Artwork = art, Accent = Imaging.Accent(art),
            };
        }

        private static BitmapSource Artwork()
        {
            var dv = new DrawingVisual();
            using (var dc = dv.RenderOpen())
            {
                var bg = new LinearGradientBrush(Color.FromRgb(255, 94, 98), Color.FromRgb(120, 60, 200), 45);
                dc.DrawRectangle(bg, null, new Rect(0, 0, 300, 300));
                dc.DrawEllipse(new RadialGradientBrush(Color.FromArgb(230, 255, 220, 140), Color.FromArgb(0, 255, 160, 90)), null, new Point(190, 120), 110, 110);
                dc.DrawEllipse(null, new Pen(new SolidColorBrush(Color.FromArgb(120, 255, 255, 255)), 3), new Point(110, 190), 60, 60);
            }
            var bmp = new RenderTargetBitmap(300, 300, 96, 96, PixelFormats.Pbgra32);
            bmp.Render(dv);
            bmp.Freeze();
            return bmp;
        }

        private static IEnumerable<string> DemoFiles()
        {
            var folder = Path.Combine(Path.GetTempPath(), "DockyDemo");
            Directory.CreateDirectory(folder);
            var notes = Path.Combine(folder, "Meeting notes.txt");
            File.WriteAllText(notes, "Ship the Windows version.");
            var image = Path.Combine(folder, "Sunset.png");
            using (var fs = File.Create(image))
            {
                var enc = new PngBitmapEncoder();
                enc.Frames.Add(BitmapFrame.Create(Artwork()));
                enc.Save(fs);
            }
            var doc = Path.Combine(folder, "Invoice March.pdf");
            File.WriteAllText(doc, "%PDF-1.4\n%demo\n");
            return new[] { doc, notes, image };
        }
    }
}
