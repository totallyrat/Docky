using System;
using System.IO;
using System.Linq;
using System.Threading;
using System.Windows;
using System.Windows.Threading;
using Docky.Core;
using Docky.Island;
using Docky.Services;
using Docky.Shell;

namespace Docky
{
    public sealed class App : Application
    {
        private readonly string[] args;
        private Mutex instance;
        private EventWaitHandle openSignal;
        public IslandWindow Island { get; private set; }
        public IntroPlayer Intro { get; } = new();
        public BreakGlow Glow { get; } = new();
        private SettingsWindow settings;
        private Tray tray;
        private bool hookRunning;
        private DispatcherTimer previewTimer;
        private static Settings S => SettingsStore.Current;

        public App(string[] args) { this.args = args; }

        protected override void OnStartup(StartupEventArgs e)
        {
            base.OnStartup(e);
            ShutdownMode = ShutdownMode.OnExplicitShutdown;
            DispatcherUnhandledException += (_, ex) => { Log(ex.Exception); ex.Handled = true; };
            AppDomain.CurrentDomain.UnhandledException += (_, ex) => Log(ex.ExceptionObject as Exception);

            // CI: check GitHub, download the latest release and install it over this exe.
            int selfTest = Array.IndexOf(args, "--update-selftest");
            if (selfTest >= 0)
            {
                string log = Path.Combine(selfTest + 1 < args.Length ? args[selfTest + 1] : Environment.CurrentDirectory, "update.log");
                void Write(string line) { try { File.AppendAllText(log, $"{DateTime.Now:HH:mm:ss} {line}\n"); } catch { } }
                Write($"running {Updater.Current} from {Environment.ProcessPath}");
                Updater.Shared.StatusChanged += () => Write("status: " + Updater.Shared.Status);
                Updater.Shared.Ready += v => { Write($"ready {v}; installing: {Updater.Shared.Install(relaunch: true)}"); Shutdown(0); };
                Dispatcher.BeginInvoke(new Action(async () =>
                {
                    await Updater.Shared.Check();
                    if (Updater.Shared.ReadyVersion == null) { Write("no update installed"); Shutdown(3); }
                }));
                return;
            }

            int demo = Array.IndexOf(args, "--demo");
            if (demo >= 0)
            {
                string dir = demo + 1 < args.Length ? args[demo + 1] : Path.Combine(Environment.CurrentDirectory, "demo");
                StartServices(demo: true);
                CreateIsland();
                _ = new Demo(this, dir).Run();
                return;
            }

            // One Docky at a time; launching it again opens Settings in the running one.
            instance = new Mutex(true, @"Local\Docky.Island", out bool first);
            // Just updated: the old copy may take a moment to finish quitting.
            if (!first && args.Contains("--updated"))
            {
                try { first = instance.WaitOne(TimeSpan.FromSeconds(10)); } catch (AbandonedMutexException) { first = true; }
            }
            openSignal = new EventWaitHandle(false, EventResetMode.AutoReset, @"Local\Docky.OpenSettings");
            if (!first)
            {
                openSignal.Set();
                Shutdown();
                return;
            }
            var listener = new Thread(() =>
            {
                while (openSignal.WaitOne()) Dispatcher.BeginInvoke(new Action(() => ShowSettings()));
            }) { IsBackground = true };
            listener.Start();

            StartServices(demo: false);
            CreateIsland();
            tray = new Tray(() => ShowSettings(), RunSetup, PlayIntro, StartPomodoro, CheckForUpdates, Quit);
            SettingsStore.ApplyStartup();

            // Updates from GitHub: downloaded quietly, then the island offers a restart.
            Updater.Shared.Ready += version => Island.ShowNotice("update", $"Docky {version} is ready",
                "Restart Docky to update. It only takes a second.", "Restart", InstallUpdateNow, G.Download);
            Updater.Shared.Start();

            if (S.PlayIntro) Intro.Play(Island, AfterIntro);
            else AfterIntro();
        }

        private void AfterIntro()
        {
            if (!S.DidOnboard) Island.StartOnboarding();
        }

        private void StartServices(bool demo)
        {
            ClockService.Shared.Start();
            VolumeService.Shared.Start();
            BrightnessService.Shared.Start();
            if (!demo)
            {
                _ = MediaService.Shared.StartAsync();
                CalendarService.Shared.Start();
                ShelfService.Shared.Start();
            }
        }

        private void CreateIsland()
        {
            Island = new IslandWindow();
            Island.Show();
            SystemMonitor.Shared.Start(Island.Handle);
            Island.OpenSettingsRequested += () => ShowSettings();
            Island.BreakGlowRequested += on => { if (on) Glow.Show(); else Glow.Hide(); };
            Glow.Raise = Island.RaiseToTop;

            VolumeService.Shared.ExternalChange += () => { if (S.HudVolume) Island.ShowHud(VolumeEvent()); };
            BrightnessService.Shared.Changed += level =>
            {
                if (!S.HudBrightness) return;
                if (Island.Hud?.Type == HudEvent.Kind.Brightness && Math.Abs((Island.Hud.Level ?? 0) - level) < 0.011) return;
                Island.ShowHud(new HudEvent { Type = HudEvent.Kind.Brightness, Glyph = G.Brightness, Title = "Brightness", Level = level });
            };

            KeyboardHook.Shared.OnVolumeKey = vk =>
            {
                var vol = VolumeService.Shared;
                if (!S.ReplaceVolumeOverlay || !S.HudVolume || !vol.Available) return false;
                Dispatcher.BeginInvoke(new Action(() =>
                {
                    if (vk == 0xAF) vol.Step(true);
                    else if (vk == 0xAE) vol.Step(false);
                    else vol.ToggleMute();
                    Island.ShowHud(VolumeEvent());
                }));
                return true;
            };
            UpdateHook();
            SettingsStore.Changed += UpdateHook;
        }

        private void UpdateHook()
        {
            bool want = S.ReplaceVolumeOverlay && S.HudVolume;
            if (want == hookRunning) return;
            if (want) KeyboardHook.Shared.Start(); else KeyboardHook.Shared.Stop();
            hookRunning = want;
        }

        public static HudEvent VolumeEvent()
        {
            var vol = VolumeService.Shared;
            double level = vol.Muted ? 0 : vol.Level;
            return new HudEvent { Type = HudEvent.Kind.Volume, Glyph = G.VolumeFor(level, vol.Muted), Title = "Volume", Level = level };
        }

        // MARK: Actions

        public AppActions Actions => new()
        {
            PlayIntro = PlayIntro,
            RunSetup = RunSetup,
            PreviewBreakGlow = PreviewGlow,
            CheckForUpdates = () => _ = Updater.Shared.Check(),
            InstallUpdate = InstallUpdateNow,
            Quit = Quit,
        };

        public SettingsWindow ShowSettings(string page = null)
        {
            if (settings == null)
            {
                settings = new SettingsWindow(Actions);
                settings.Closed += (_, _) => settings = null;
                settings.Show();
            }
            else
            {
                if (settings.WindowState == WindowState.Minimized) settings.WindowState = WindowState.Normal;
                settings.Activate();
            }
            if (page != null) settings.ShowPage(page);
            return settings;
        }

        private void PlayIntro()
        {
            if (Intro.IsPlaying) return;
            Intro.Play(Island, null);
        }

        private void RunSetup()
        {
            settings?.Close();
            Island.StartOnboarding();
        }

        private void StartPomodoro()
        {
            if (ClockService.Shared.Session == null) ClockService.Shared.StartPomodoro();
            Island.Expand(Tab.Timers);
            Island.SetTimersMode("pomodoro");
        }

        private void PreviewGlow()
        {
            Glow.Show();
            previewTimer?.Stop();
            previewTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(6) };
            previewTimer.Tick += (_, _) =>
            {
                previewTimer.Stop();
                if (!Island.BreakCard) Glow.Hide();
            };
            previewTimer.Start();
        }

        private void CheckForUpdates()
        {
            ShowSettings("General");
            _ = Updater.Shared.Check();
        }

        private void InstallUpdateNow()
        {
            ClockService.Shared.Save();
            if (!Updater.Shared.Install(relaunch: true)) return;
            KeyboardHook.Shared.Stop();
            tray?.Dispose();
            Shutdown();
        }

        public void Quit()
        {
            // A downloaded update that wasn't installed yet goes in now, ready for next time.
            if (Updater.Shared.HasUpdate) Updater.Shared.Install(relaunch: false);
            ClockService.Shared.Save();
            KeyboardHook.Shared.Stop();
            tray?.Dispose();
            Shutdown();
        }

        protected override void OnExit(ExitEventArgs e)
        {
            KeyboardHook.Shared.Stop();
            tray?.Dispose();
            base.OnExit(e);
        }

        public static void Log(Exception ex)
        {
            if (ex == null) return;
            try { File.AppendAllText(Path.Combine(SettingsStore.Folder, "errors.log"), $"[{DateTime.Now:u}] {ex}\n\n"); } catch { }
            Demo.Current?.Fail(ex);
        }
    }

    public static class Program
    {
        [STAThread]
        public static int Main(string[] args)
        {
            // Started from a freshly downloaded update: replace the old exe and restart it.
            if (args.Length >= 4 && args[0] == "--apply-update")
                return Updater.ApplyFromDownloaded(args[1], args[2], args[3]);
            var app = new App(args);
            return app.Run();
        }
    }
}
