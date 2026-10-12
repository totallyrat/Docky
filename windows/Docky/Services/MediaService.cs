using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Docky.Core;
using Docky.Island;
using Windows.Media.Control;

namespace Docky.Services
{
    public sealed class MediaInfo
    {
        public string Title = "", Artist = "", Album = "", AppId = "";
        public bool IsPlaying;
        public double Duration, Position;
        public DateTime PositionStamp = DateTime.Now;
        public ImageSource Artwork;
        public Color Accent = Colors.White;

        public string TrackKey => Title + "\u0001" + Artist;

        public double CurrentPosition
        {
            get
            {
                double p = Position + (IsPlaying ? (DateTime.Now - PositionStamp).TotalSeconds : 0);
                return Duration > 0 ? Math.Clamp(p, 0, Duration) : Math.Max(0, p);
            }
        }

        public string AppName => MediaService.FriendlyName(AppId);
    }

    /// <summary>
    /// Now Playing via Windows' Global System Media Transport Controls: every app that shows up
    /// in the Windows media flyout (Spotify, browsers, Media Player…).
    /// </summary>
    public sealed class MediaService
    {
        public static MediaService Shared { get; } = new();

        public MediaInfo Current { get; private set; }
        public DateTime? PausedAt { get; private set; }
        public int TrackChanges { get; private set; }
        public event Action Changed;

        private GlobalSystemMediaTransportControlsSessionManager manager;
        private readonly HashSet<GlobalSystemMediaTransportControlsSession> hooked = new();
        private readonly Dictionary<string, GlobalSystemMediaTransportControlsSessionPlaybackStatus> lastStatus = new();
        private string lastTrack;
        private string lastArtKey;

        public async Task StartAsync()
        {
            try
            {
                manager = await GlobalSystemMediaTransportControlsSessionManager.RequestAsync();
                manager.SessionsChanged += (_, _) => OnUI(HookAll);
                manager.CurrentSessionChanged += (_, _) => OnUI(() => _ = RefreshAsync());
                HookAll();
                await RefreshAsync();
            }
            catch (Exception e) { Debug.WriteLine("Media unavailable: " + e.Message); }
        }

        private static void OnUI(Action a) => Application.Current?.Dispatcher.BeginInvoke(a);

        private void HookAll()
        {
            if (manager == null) return;
            foreach (var s in manager.GetSessions())
            {
                if (!hooked.Add(s)) continue;
                s.PlaybackInfoChanged += (sender, args) => OnUI(() => { CheckAutoPause(sender); _ = RefreshAsync(); });
                s.MediaPropertiesChanged += (_, _) => OnUI(() => _ = RefreshAsync());
                s.TimelinePropertiesChanged += (_, _) => OnUI(() => _ = RefreshAsync());
            }
            _ = RefreshAsync();
        }

        /// <summary>One thing plays at a time: when a session starts playing, pause the others.</summary>
        private void CheckAutoPause(GlobalSystemMediaTransportControlsSession started)
        {
            try
            {
                var status = started.GetPlaybackInfo()?.PlaybackStatus ?? GlobalSystemMediaTransportControlsSessionPlaybackStatus.Closed;
                lastStatus.TryGetValue(started.SourceAppUserModelId, out var previous);
                lastStatus[started.SourceAppUserModelId] = status;
                if (!SettingsStore.Current.AutoPauseOthers) return;
                if (status != GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing ||
                    previous == GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing) return;
                foreach (var other in manager.GetSessions())
                {
                    if (other.SourceAppUserModelId == started.SourceAppUserModelId) continue;
                    if (other.GetPlaybackInfo()?.PlaybackStatus == GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing)
                        _ = other.TryPauseAsync();
                }
            }
            catch { }
        }

        private GlobalSystemMediaTransportControlsSession PickSession()
        {
            var sessions = manager.GetSessions().ToList();
            bool musicOnly = SettingsStore.Current.MusicOnly;
            bool Allowed(GlobalSystemMediaTransportControlsSession s)
            {
                if (!musicOnly) return true;
                double dur = 0;
                try { dur = s.GetTimelineProperties().EndTime.TotalSeconds; } catch { }
                return IsMusic(s.SourceAppUserModelId, dur);
            }
            var current = manager.GetCurrentSession();
            bool Playing(GlobalSystemMediaTransportControlsSession s)
                => s.GetPlaybackInfo()?.PlaybackStatus == GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing;
            if (current != null && Allowed(current) && Playing(current)) return current;
            return sessions.FirstOrDefault(s => Allowed(s) && Playing(s)) ?? (current != null && Allowed(current) ? current : sessions.FirstOrDefault(Allowed));
        }

        public async Task RefreshAsync()
        {
            if (manager == null) return;
            GlobalSystemMediaTransportControlsSession session = null;
            try { session = PickSession(); } catch { }
            if (session == null)
            {
                if (Current != null) { Current = null; Changed?.Invoke(); }
                return;
            }
            try
            {
                var props = await session.TryGetMediaPropertiesAsync();
                var playback = session.GetPlaybackInfo();
                var timeline = session.GetTimelineProperties();
                var info = new MediaInfo
                {
                    Title = props?.Title ?? "",
                    Artist = props?.Artist ?? "",
                    Album = props?.AlbumTitle ?? "",
                    AppId = session.SourceAppUserModelId ?? "",
                    IsPlaying = playback?.PlaybackStatus == GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing,
                    Duration = Math.Max(0, (timeline.EndTime - timeline.StartTime).TotalSeconds),
                    Position = timeline.Position.TotalSeconds,
                    PositionStamp = timeline.LastUpdatedTime.LocalDateTime > DateTime.MinValue ? timeline.LastUpdatedTime.LocalDateTime : DateTime.Now,
                };
                if (info.PositionStamp > DateTime.Now || (DateTime.Now - info.PositionStamp).TotalHours > 12) info.PositionStamp = DateTime.Now;

                string artKey = info.TrackKey + "|" + info.AppId;
                if (artKey == lastArtKey && Current != null)
                {
                    info.Artwork = Current.Artwork;
                    info.Accent = Current.Accent;
                }
                else if (props?.Thumbnail != null)
                {
                    try
                    {
                        using var stream = await props.Thumbnail.OpenReadAsync();
                        using var net = stream.AsStream();
                        var ms = new System.IO.MemoryStream();
                        await net.CopyToAsync(ms);
                        ms.Position = 0;
                        var bmp = new BitmapImage();
                        bmp.BeginInit();
                        bmp.CacheOption = BitmapCacheOption.OnLoad;
                        bmp.StreamSource = ms;
                        bmp.EndInit();
                        bmp.Freeze();
                        info.Artwork = bmp;
                        info.Accent = Imaging.Accent(bmp);
                        lastArtKey = artKey;
                    }
                    catch { }
                }
                Apply(info);
            }
            catch { }
        }

        private void Apply(MediaInfo next)
        {
            bool hasContent = next.Title.Length > 0 || next.Artist.Length > 0;
            if (!hasContent) { Current = null; Changed?.Invoke(); return; }
            var previous = Current;
            if (lastTrack != null && lastTrack != next.TrackKey && next.IsPlaying) TrackChanges++;
            lastTrack = next.TrackKey;
            if (next.IsPlaying) PausedAt = null;
            else if (previous?.IsPlaying == true) PausedAt = DateTime.Now;
            else if (PausedAt == null) PausedAt = DateTime.MinValue;
            Current = next;
            Changed?.Invoke();
        }

        /// <summary>Lets demo mode show a track without any media apps.</summary>
        public void Inject(MediaInfo info) { Apply(info); }

        // Controls

        private GlobalSystemMediaTransportControlsSession Target()
        {
            if (manager == null || Current == null) return null;
            return manager.GetSessions().FirstOrDefault(s => s.SourceAppUserModelId == Current.AppId) ?? manager.GetCurrentSession();
        }

        public void TogglePlayPause()
        {
            if (Current != null)
            {
                Current.Position = Current.CurrentPosition;
                Current.PositionStamp = DateTime.Now;
                Current.IsPlaying = !Current.IsPlaying;
                PausedAt = Current.IsPlaying ? null : DateTime.Now;
                Changed?.Invoke();
            }
            _ = Target()?.TryTogglePlayPauseAsync();
        }

        public void Next() => _ = Target()?.TrySkipNextAsync();
        public void Previous() => _ = Target()?.TrySkipPreviousAsync();

        public void Seek(double seconds)
        {
            if (Current != null) { Current.Position = seconds; Current.PositionStamp = DateTime.Now; Changed?.Invoke(); }
            _ = Target()?.TryChangePlaybackPositionAsync(TimeSpan.FromSeconds(seconds).Ticks);
        }

        // Classification & names

        private static readonly string[] MusicApps =
        {
            "spotify", "applemusic", "applemusicwin", "zunemusic", "tidal", "deezer", "amazon music", "amazonmusic",
            "youtube music", "youtubemusic", "musicbee", "foobar2000", "aimp", "winamp", "qobuz", "cider",
        };

        public static bool IsMusic(string appId, double duration)
        {
            var id = (appId ?? "").ToLowerInvariant();
            if (MusicApps.Any(id.Contains)) return true;
            return duration >= 60 && duration <= 300;
        }

        public static string FriendlyName(string appId)
        {
            var id = (appId ?? "").ToLowerInvariant();
            if (id.Contains("spotify")) return "Spotify";
            if (id.Contains("applemusic")) return "Apple Music";
            if (id.Contains("zunemusic")) return "Media Player";
            if (id.Contains("chrome")) return "Chrome";
            if (id.Contains("msedge") || id.Contains("edge")) return "Edge";
            if (id.Contains("firefox") || id == "308046b0af4a39cb") return "Firefox";
            if (id.Contains("opera")) return "Opera";
            if (id.Contains("brave")) return "Brave";
            if (id.Contains("vlc")) return "VLC";
            if (id.Contains("arc")) return "Arc";
            var name = appId ?? "";
            if (name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) name = name[..^4];
            int bang = name.IndexOf('!');
            if (bang > 0) name = name[..bang];
            int us = name.IndexOf('_');
            if (us > 0) name = name[..us];
            int dot = name.LastIndexOf('.');
            if (dot >= 0 && dot < name.Length - 1) name = name[(dot + 1)..];
            return name;
        }
    }
}
