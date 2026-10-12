using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Windows;
using System.Windows.Threading;
using Docky.Core;
using Microsoft.Win32;
using Windows.Devices.Bluetooth;
using Windows.Devices.Enumeration;

namespace Docky.Services
{
    /// <summary>What the island shows when the system changes something.</summary>
    public sealed class HudEvent
    {
        public enum Kind { Volume, Brightness, Focus, Device, Charging, Drive, Unlock }
        public Kind Type;
        public string Glyph;
        public string Title = "";
        public string Detail = "";
        public double? Level;
        public System.Windows.Media.Color Tint = System.Windows.Media.Colors.White;
    }

    /// <summary>Power, Bluetooth, drives, Focus assist, fullscreen apps and lock/unlock.</summary>
    public sealed class SystemMonitor
    {
        public static SystemMonitor Shared { get; } = new();
        public event Action<HudEvent> Event;
        /// <summary>A fullscreen app is in front (raised on change).</summary>
        public event Action<bool> FullscreenChanged;
        public bool FullscreenActive { get; private set; }

        private readonly DispatcherTimer poll = new() { Interval = TimeSpan.FromSeconds(1.5) };
        private bool? lastOnAC;
        private int? lastFocusProfile;
        private HashSet<string> lastDrives = new();
        private DeviceWatcher bluetooth;
        private bool bluetoothReady;
        private readonly Dictionary<string, string> btNames = new();
        private DateTime started;
        private IntPtr ownWindow;

        public void Start(IntPtr islandWindow)
        {
            ownWindow = islandWindow;
            started = DateTime.Now;
            lastOnAC = OnAC();
            lastDrives = Drives();
            lastFocusProfile = FocusProfile();
            poll.Tick += (_, _) => Poll();
            poll.Start();
            SystemEvents.SessionSwitch += (_, e) =>
            {
                if (e.Reason == SessionSwitchReason.SessionUnlock)
                    Raise(new HudEvent { Type = HudEvent.Kind.Unlock, Glyph = G.Unlock, Title = "Welcome back", Detail = DateTime.Now.ToString("ddd d MMM"), Tint = Theme.Blue });
            };
            StartBluetooth();
        }

        private bool WarmedUp => (DateTime.Now - started).TotalSeconds > 3;
        private static void OnUI(Action a) => Application.Current?.Dispatcher.BeginInvoke(a);
        private void Raise(HudEvent e) => OnUI(() => Event?.Invoke(e));

        private void Poll()
        {
            var s = SettingsStore.Current;

            // Plugged in
            bool ac = OnAC();
            if (lastOnAC == false && ac && s.HudCharging)
            {
                int pct = (int)Math.Round(System.Windows.Forms.SystemInformation.PowerStatus.BatteryLifePercent * 100);
                Raise(new HudEvent { Type = HudEvent.Kind.Charging, Glyph = G.Bolt, Title = "Charging", Detail = pct + "%", Tint = pct <= 20 ? Theme.Orange : Theme.Green });
            }
            lastOnAC = ac;

            // Drives
            var drives = Drives();
            if (s.HudDevices && WarmedUp)
            {
                foreach (var d in drives.Except(lastDrives))
                    Raise(new HudEvent { Type = HudEvent.Kind.Drive, Glyph = G.Drive, Title = d, Detail = "Connected", Tint = Theme.Blue });
                foreach (var d in lastDrives.Except(drives))
                    Raise(new HudEvent { Type = HudEvent.Kind.Drive, Glyph = G.Drive, Title = d, Detail = "Ejected" });
            }
            lastDrives = drives;

            // Focus assist / Do not disturb
            var profile = FocusProfile();
            if (profile != null && lastFocusProfile != null && profile != lastFocusProfile && s.HudFocus && WarmedUp)
            {
                bool on = profile > 0;
                string name = profile == 2 ? "Alarms only" : "Do not disturb";
                Raise(new HudEvent { Type = HudEvent.Kind.Focus, Glyph = G.Moon, Title = on ? name : "Do not disturb", Detail = on ? "On" : "Off", Tint = on ? Theme.Purple : System.Windows.Media.Colors.White });
            }
            if (profile != null) lastFocusProfile = profile;

            // Fullscreen apps
            bool full = s.HideInFullscreen && ForegroundIsFullscreen();
            if (full != FullscreenActive)
            {
                FullscreenActive = full;
                FullscreenChanged?.Invoke(full);
            }
        }

        private static bool OnAC()
        {
            try { return System.Windows.Forms.SystemInformation.PowerStatus.PowerLineStatus == System.Windows.Forms.PowerLineStatus.Online; }
            catch { return true; }
        }

        private static HashSet<string> Drives()
        {
            try
            {
                return DriveInfo.GetDrives()
                    .Where(d => d.DriveType == DriveType.Removable && d.IsReady)
                    .Select(d => string.IsNullOrWhiteSpace(d.VolumeLabel) ? d.Name.TrimEnd('\\') : d.VolumeLabel)
                    .ToHashSet();
            }
            catch { return new HashSet<string>(); }
        }

        private static int? FocusProfile()
        {
            try
            {
                ulong state = Native.WNF_SHEL_QUIETHOURS_ACTIVE_PROFILE_CHANGED;
                var buffer = new byte[4];
                uint size = 4;
                if (Native.NtQueryWnfStateData(ref state, IntPtr.Zero, IntPtr.Zero, out _, buffer, ref size) != 0 || size < 4) return null;
                return BitConverter.ToInt32(buffer, 0);
            }
            catch { return null; }
        }

        private bool ForegroundIsFullscreen()
        {
            var fg = Native.GetForegroundWindow();
            if (fg == IntPtr.Zero || fg == ownWindow || fg == Native.GetShellWindow() || fg == Native.GetDesktopWindow()) return false;
            var cls = new StringBuilder(64);
            Native.GetClassName(fg, cls, 64);
            var c = cls.ToString();
            if (c == "Progman" || c == "WorkerW" || c == "Shell_TrayWnd") return false;
            if (!Native.GetWindowRect(fg, out var r)) return false;
            var info = new Native.MONITORINFO { cbSize = System.Runtime.InteropServices.Marshal.SizeOf<Native.MONITORINFO>() };
            if (!Native.GetMonitorInfo(Native.MonitorFromWindow(fg, 2), ref info)) return false;
            var m = info.rcMonitor;
            return r.Left <= m.Left && r.Top <= m.Top && r.Right >= m.Right && r.Bottom >= m.Bottom;
        }

        private void StartBluetooth()
        {
            try
            {
                string selector = BluetoothDevice.GetDeviceSelectorFromConnectionStatus(BluetoothConnectionStatus.Connected);
                bluetooth = DeviceInformation.CreateWatcher(selector);
                bluetooth.Added += (_, info) =>
                {
                    btNames[info.Id] = info.Name;
                    if (bluetoothReady && SettingsStore.Current.HudDevices)
                        Raise(new HudEvent { Type = HudEvent.Kind.Device, Glyph = GlyphFor(info.Name), Title = info.Name, Detail = "Connected", Tint = Theme.Blue });
                };
                bluetooth.Removed += (_, update) =>
                {
                    if (!btNames.TryGetValue(update.Id, out var name)) return;
                    btNames.Remove(update.Id);
                    if (bluetoothReady && SettingsStore.Current.HudDevices)
                        Raise(new HudEvent { Type = HudEvent.Kind.Device, Glyph = GlyphFor(name), Title = name, Detail = "Disconnected" });
                };
                bluetooth.Updated += (_, _) => { };
                bluetooth.EnumerationCompleted += (_, _) => bluetoothReady = true;
                bluetooth.Start();
            }
            catch { }
        }

        private static string GlyphFor(string name)
        {
            var n = (name ?? "").ToLowerInvariant();
            if (n.Contains("airpods") || n.Contains("buds") || n.Contains("headphone") || n.Contains("wh-") || n.Contains("beats")) return G.Headphones;
            return G.Bluetooth;
        }
    }
}
