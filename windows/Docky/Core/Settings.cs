using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Docky.Core
{
    /// <summary>Every user preference. Saved as JSON in %APPDATA%\Docky\settings.json.</summary>
    public sealed class Settings
    {
        // Island
        public double IslandScale { get; set; } = 1.0;
        public string AnimationFeel { get; set; } = "smooth"; // smooth | snappy | bouncy
        public bool HoverGrow { get; set; } = true;
        public bool HideWhenIdle { get; set; } = false;
        public bool HideInFullscreen { get; set; } = true;
        public bool ShowTimerBubble { get; set; } = true;
        public bool PlayIntro { get; set; } = true;
        public bool LaunchAtStartup { get; set; } = false;
        public bool Use24Hour { get; set; } = false;

        // Gestures
        public bool ScrollToOpen { get; set; } = true;
        public bool ClickToOpen { get; set; } = true;
        public bool HoverToOpen { get; set; } = false;
        public double HoverDelay { get; set; } = 0.6;
        public double CollapseDelay { get; set; } = 0.35;

        // Now Playing
        public bool NowPlayingEnabled { get; set; } = true;
        public bool MusicOnly { get; set; } = false;
        public bool ShowTitle { get; set; } = true;
        public bool TintFromArtwork { get; set; } = true;
        public bool TrackChangePeek { get; set; } = true;
        public bool AutoPauseOthers { get; set; } = true;
        public double PausedLinger { get; set; } = 30;

        // Indicators
        public bool HudVolume { get; set; } = true;
        public bool HudBrightness { get; set; } = true;
        public bool HudFocus { get; set; } = true;
        public bool HudDevices { get; set; } = true;
        public bool HudCharging { get; set; } = true;
        public bool ReplaceVolumeOverlay { get; set; } = true;

        // Calendar
        public bool ShowCalendar { get; set; } = true;
        public List<string> CalendarUrls { get; set; } = new();

        // Alerts
        public string AlarmSound { get; set; } = "Radar";
        public string TimerSound { get; set; } = "Chime";
        public int SnoozeMinutes { get; set; } = 9;

        public bool DidOnboard { get; set; } = false;

        [JsonIgnore]
        public (double response, double damping) Spring => AnimationFeel switch
        {
            "snappy" => (0.36, 0.86),
            "bouncy" => (0.58, 0.66),
            _ => (0.52, 0.80),
        };
    }

    public static class SettingsStore
    {
        public static Settings Current { get; private set; } = Load();
        public static event Action Changed;

        public static string Folder
        {
            get
            {
                var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Docky");
                Directory.CreateDirectory(dir);
                return dir;
            }
        }

        private static string FilePath => Path.Combine(Folder, "settings.json");

        public static readonly JsonSerializerOptions Json = new() { WriteIndented = true };

        private static Settings Load()
        {
            try
            {
                if (File.Exists(FilePath))
                    return JsonSerializer.Deserialize<Settings>(File.ReadAllText(FilePath), Json) ?? new Settings();
            }
            catch { }
            return new Settings();
        }

        /// <summary>Apply a change, persist it and notify everything listening.</summary>
        public static void Update(Action<Settings> change)
        {
            change(Current);
            Save();
            Changed?.Invoke();
        }

        public static void Save()
        {
            try { File.WriteAllText(FilePath, JsonSerializer.Serialize(Current, Json)); } catch { }
        }

        /// <summary>Starts Docky with Windows via the per-user Run key.</summary>
        public static void ApplyStartup()
        {
            try
            {
                using var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run", true);
                if (key == null) return;
                if (Current.LaunchAtStartup) key.SetValue("Docky", "\"" + Environment.ProcessPath + "\"");
                else key.DeleteValue("Docky", false);
            }
            catch { }
        }
    }
}
