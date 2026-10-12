using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Docky.Core;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;

namespace Docky.Services
{
    public sealed class CalEvent
    {
        public string Title = "";
        public DateTime Start, End;
        public bool AllDay;
        public string Location;
        public string JoinUrl;
        public Color Color = Theme.Blue;
        public bool Now => !AllDay && Start <= DateTime.Now && DateTime.Now < End;
    }

    /// <summary>
    /// Calendar events from iCal (.ics) links — Google Calendar's "secret address in iCal format",
    /// Outlook's published calendar link, iCloud public calendars… No sign-in needed.
    /// </summary>
    public sealed class CalendarService
    {
        public static CalendarService Shared { get; } = new();
        public event Action Changed;
        public List<CalEvent> Events { get; private set; } = new();
        public string LastError { get; private set; }
        private readonly DispatcherTimer refresh = new() { Interval = TimeSpan.FromMinutes(15) };
        private static readonly HttpClient http = new() { Timeout = TimeSpan.FromSeconds(20) };
        private static readonly Color[] palette = { Theme.Blue, Theme.Pink, Theme.Orange, Theme.Green, Theme.Purple };

        public void Start()
        {
            refresh.Tick += (_, _) => _ = ReloadAsync();
            refresh.Start();
            _ = ReloadAsync();
        }

        public void Inject(List<CalEvent> events) { Events = events; Changed?.Invoke(); }

        public IEnumerable<CalEvent> On(DateTime day)
            => Events.Where(e => e.Start.Date <= day.Date && (e.End > day.Date || e.Start.Date == day.Date))
                     .OrderBy(e => e.AllDay ? 0 : 1).ThenBy(e => e.Start);

        public async Task ReloadAsync()
        {
            var urls = SettingsStore.Current.CalendarUrls.Where(u => !string.IsNullOrWhiteSpace(u)).ToList();
            var all = new List<CalEvent>();
            LastError = null;
            for (int i = 0; i < urls.Count; i++)
            {
                try
                {
                    var url = urls[i].Trim();
                    if (url.StartsWith("webcal://", StringComparison.OrdinalIgnoreCase)) url = "https://" + url[9..];
                    var text = await http.GetStringAsync(url);
                    all.AddRange(Parse(text, palette[i % palette.Length]));
                }
                catch (Exception e) { LastError = e.Message; }
            }
            var from = DateTime.Today;
            var to = from.AddDays(8);
            Application.Current?.Dispatcher.BeginInvoke(new Action(() =>
            {
                Events = all.Where(e => e.End > from && e.Start < to).OrderBy(e => e.Start).ToList();
                Changed?.Invoke();
            }));
        }

        // A deliberately small iCalendar reader: single events plus simple daily/weekly repeats.
        private static IEnumerable<CalEvent> Parse(string ics, Color color)
        {
            var lines = Unfold(ics);
            var result = new List<CalEvent>();
            Dictionary<string, string> current = null;
            foreach (var line in lines)
            {
                if (line == "BEGIN:VEVENT") { current = new(StringComparer.OrdinalIgnoreCase); continue; }
                if (line == "END:VEVENT" && current != null)
                {
                    result.AddRange(Expand(current, color));
                    current = null;
                    continue;
                }
                if (current == null) continue;
                int colon = line.IndexOf(':');
                if (colon <= 0) continue;
                var name = line[..colon];
                var value = line[(colon + 1)..];
                var key = name.Split(';')[0];
                current[key] = value;
                current[key + "#params"] = name;
            }
            return result;
        }

        private static List<string> Unfold(string ics)
        {
            var raw = ics.Replace("\r\n", "\n").Split('\n');
            var lines = new List<string>();
            foreach (var l in raw)
            {
                if ((l.StartsWith(" ") || l.StartsWith("\t")) && lines.Count > 0) lines[^1] += l[1..];
                else lines.Add(l.TrimEnd());
            }
            return lines;
        }

        private static IEnumerable<CalEvent> Expand(Dictionary<string, string> v, Color color)
        {
            if (!v.TryGetValue("DTSTART", out var startRaw)) yield break;
            bool allDay = startRaw.Length == 8;
            var start = ParseDate(startRaw, v.GetValueOrDefault("DTSTART#params"));
            var end = v.TryGetValue("DTEND", out var endRaw) ? ParseDate(endRaw, v.GetValueOrDefault("DTEND#params")) : start.AddHours(allDay ? 24 : 1);
            if (start == DateTime.MinValue) yield break;
            string title = Unescape(v.GetValueOrDefault("SUMMARY") ?? "Untitled");
            string location = Unescape(v.GetValueOrDefault("LOCATION") ?? "");
            string join = FindJoin(string.Join(" ", v.GetValueOrDefault("URL"), location, Unescape(v.GetValueOrDefault("DESCRIPTION") ?? "")));
            var duration = end - start;

            CalEvent Make(DateTime s) => new()
            {
                Title = title, Start = s, End = s + duration, AllDay = allDay,
                Location = location.Length > 0 ? location : null, JoinUrl = join, Color = color,
            };

            var rrule = v.GetValueOrDefault("RRULE");
            if (string.IsNullOrEmpty(rrule)) { yield return Make(start); yield break; }

            var parts = rrule.Split(';').Select(p => p.Split('=')).Where(p => p.Length == 2).ToDictionary(p => p[0].ToUpperInvariant(), p => p[1]);
            string freq = parts.GetValueOrDefault("FREQ", "");
            int interval = int.TryParse(parts.GetValueOrDefault("INTERVAL"), out var iv) ? Math.Max(1, iv) : 1;
            int count = int.TryParse(parts.GetValueOrDefault("COUNT"), out var c) ? c : int.MaxValue;
            DateTime until = parts.TryGetValue("UNTIL", out var u) ? ParseDate(u, null) : DateTime.MaxValue;
            var byDay = parts.GetValueOrDefault("BYDAY")?.Split(',').Select(DayOf).Where(d => d != null).Select(d => d.Value).ToHashSet();
            var windowEnd = DateTime.Today.AddDays(9);
            int emitted = 0;
            var cursor = start;
            for (int guard = 0; guard < 2000 && cursor < windowEnd && cursor <= until && emitted < count; guard++)
            {
                if (freq == "WEEKLY" && byDay != null && byDay.Count > 0)
                {
                    var weekStart = cursor.Date.AddDays(-(int)cursor.DayOfWeek);
                    foreach (var d in byDay.OrderBy(x => x))
                    {
                        var occ = weekStart.AddDays((int)d) + start.TimeOfDay;
                        if (occ < start || occ > until || emitted >= count) continue;
                        emitted++;
                        if (occ + duration > DateTime.Today.AddDays(-1)) yield return Make(occ);
                    }
                    cursor = cursor.AddDays(7 * interval);
                    continue;
                }
                emitted++;
                if (cursor + duration > DateTime.Today.AddDays(-1)) yield return Make(cursor);
                cursor = freq switch
                {
                    "DAILY" => cursor.AddDays(interval),
                    "WEEKLY" => cursor.AddDays(7 * interval),
                    "MONTHLY" => cursor.AddMonths(interval),
                    "YEARLY" => cursor.AddYears(interval),
                    _ => windowEnd,
                };
            }
        }

        private static DayOfWeek? DayOf(string s)
        {
            s = Regex.Replace(s ?? "", "[^A-Z]", "");
            return s switch
            {
                "SU" => DayOfWeek.Sunday, "MO" => DayOfWeek.Monday, "TU" => DayOfWeek.Tuesday, "WE" => DayOfWeek.Wednesday,
                "TH" => DayOfWeek.Thursday, "FR" => DayOfWeek.Friday, "SA" => DayOfWeek.Saturday, _ => null,
            };
        }

        private static DateTime ParseDate(string value, string parameters)
        {
            value = value.Trim();
            if (value.Length == 8 && DateTime.TryParseExact(value, "yyyyMMdd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var d)) return d;
            bool utc = value.EndsWith("Z");
            var core = value.TrimEnd('Z');
            if (!DateTime.TryParseExact(core, "yyyyMMdd'T'HHmmss", CultureInfo.InvariantCulture, DateTimeStyles.None, out var t)) return DateTime.MinValue;
            if (utc) return DateTime.SpecifyKind(t, DateTimeKind.Utc).ToLocalTime();
            var tzid = parameters?.Split(';').FirstOrDefault(p => p.StartsWith("TZID=", StringComparison.OrdinalIgnoreCase))?[5..];
            if (tzid != null)
            {
                try
                {
                    var tz = TimeZoneInfo.FindSystemTimeZoneById(tzid);
                    return TimeZoneInfo.ConvertTime(t, tz, TimeZoneInfo.Local);
                }
                catch
                {
                    if (TimeZoneInfo.TryConvertIanaIdToWindowsId(tzid, out var win))
                        try { return TimeZoneInfo.ConvertTime(t, TimeZoneInfo.FindSystemTimeZoneById(win), TimeZoneInfo.Local); } catch { }
                }
            }
            return t;
        }

        private static string Unescape(string s) => s.Replace("\\n", " ").Replace("\\,", ",").Replace("\\;", ";").Replace("\\\\", "\\");

        private static string FindJoin(string text)
        {
            var m = Regex.Match(text ?? "", @"https://[^\s""<>]*(zoom\.us|meet\.google\.com|teams\.microsoft\.com|teams\.live\.com|webex\.com|whereby\.com)[^\s""<>]*", RegexOptions.IgnoreCase);
            return m.Success ? m.Value : null;
        }
    }

    public sealed class ShelfItem
    {
        public string Path { get; set; }
        public DateTime Added { get; set; } = DateTime.Now;
        public string Name => System.IO.Path.GetFileName(Path);
    }

    /// <summary>The Clipboard shelf: files dropped on the island stay until removed.</summary>
    public sealed class ShelfService
    {
        public static ShelfService Shared { get; } = new();
        public List<ShelfItem> Items { get; private set; } = new();
        public event Action Changed;

        private static string FilePath => System.IO.Path.Combine(SettingsStore.Folder, "clipboard.json");
        private static string DroppedFolder
        {
            get { var d = System.IO.Path.Combine(SettingsStore.Folder, "Clipboard"); Directory.CreateDirectory(d); return d; }
        }

        public void Start()
        {
            try
            {
                if (File.Exists(FilePath))
                    Items = (JsonSerializer.Deserialize<List<ShelfItem>>(File.ReadAllText(FilePath)) ?? new())
                        .Where(i => File.Exists(i.Path) || Directory.Exists(i.Path)).ToList();
            }
            catch { }
        }

        private void Save()
        {
            try { File.WriteAllText(FilePath, JsonSerializer.Serialize(Items, SettingsStore.Json)); } catch { }
            Changed?.Invoke();
        }

        public void Add(IEnumerable<string> paths)
        {
            bool any = false;
            foreach (var p in paths)
            {
                if ((!File.Exists(p) && !Directory.Exists(p)) || Items.Any(i => string.Equals(i.Path, p, StringComparison.OrdinalIgnoreCase))) continue;
                Items.Insert(0, new ShelfItem { Path = p });
                any = true;
            }
            if (any) Save();
        }

        /// <summary>Accepts files, text or an image from a drag; returns the stored paths.</summary>
        public List<string> Accept(IDataObject data, bool keep = true)
        {
            var paths = new List<string>();
            if (data.GetDataPresent(DataFormats.FileDrop) && data.GetData(DataFormats.FileDrop) is string[] files) paths.AddRange(files);
            else if (data.GetDataPresent(DataFormats.Bitmap) && data.GetData(DataFormats.Bitmap) is BitmapSource bmp)
            {
                var path = Unique("Image", ".png");
                using (var fs = File.Create(path)) { var enc = new PngBitmapEncoder(); enc.Frames.Add(BitmapFrame.Create(bmp)); enc.Save(fs); }
                paths.Add(path);
            }
            else if (data.GetDataPresent(DataFormats.UnicodeText) && data.GetData(DataFormats.UnicodeText) is string text && text.Length > 0)
            {
                var first = text.Split('\n')[0].Trim();
                var safe = Regex.Replace(first.Length > 40 ? first[..40] : first, @"[\\/:*?""<>|]", "-");
                var path = Unique(safe.Length > 0 ? safe : "Text", ".txt");
                File.WriteAllText(path, text);
                paths.Add(path);
            }
            if (keep) Add(paths);
            return paths;
        }

        private static string Unique(string name, string ext)
        {
            var path = System.IO.Path.Combine(DroppedFolder, name + ext);
            for (int n = 2; File.Exists(path); n++) path = System.IO.Path.Combine(DroppedFolder, $"{name} {n}{ext}");
            return path;
        }

        public void Remove(ShelfItem item)
        {
            Items.Remove(item);
            if (item.Path.StartsWith(DroppedFolder, StringComparison.OrdinalIgnoreCase)) try { File.Delete(item.Path); } catch { }
            Save();
        }

        public void Clear()
        {
            foreach (var i in Items.ToList()) if (i.Path.StartsWith(DroppedFolder, StringComparison.OrdinalIgnoreCase)) try { File.Delete(i.Path); } catch { }
            Items.Clear();
            Save();
        }

        public static ImageSource Thumbnail(string path)
        {
            try
            {
                var ext = System.IO.Path.GetExtension(path).ToLowerInvariant();
                if (ext is ".png" or ".jpg" or ".jpeg" or ".gif" or ".bmp")
                {
                    var b = new BitmapImage();
                    b.BeginInit();
                    b.CacheOption = BitmapCacheOption.OnLoad;
                    b.DecodePixelWidth = 96;
                    b.UriSource = new Uri(path);
                    b.EndInit();
                    b.Freeze();
                    return b;
                }
                using var icon = System.Drawing.Icon.ExtractAssociatedIcon(path);
                if (icon == null) return null;
                var src = System.Windows.Interop.Imaging.CreateBitmapSourceFromHIcon(icon.Handle, Int32Rect.Empty, BitmapSizeOptions.FromEmptyOptions());
                src.Freeze();
                return src;
            }
            catch { return null; }
        }

        /// <summary>Opens the Windows Share sheet for the given files.</summary>
        public static void Share(IntPtr window, List<string> paths)
        {
            if (paths.Count == 0) return;
            try
            {
                var manager = DataTransferManagerInterop.GetForWindow(window);
                void Handler(DataTransferManager sender, DataRequestedEventArgs args)
                {
                    sender.DataRequested -= Handler;
                    var request = args.Request;
                    request.Data.Properties.Title = paths.Count == 1 ? System.IO.Path.GetFileName(paths[0]) : $"{paths.Count} items";
                    var deferral = request.GetDeferral();
                    _ = Task.Run(async () =>
                    {
                        try
                        {
                            var items = new List<IStorageItem>();
                            foreach (var p in paths)
                                items.Add(Directory.Exists(p) ? await StorageFolder.GetFolderFromPathAsync(p) : await StorageFile.GetFileFromPathAsync(p));
                            request.Data.SetStorageItems(items);
                        }
                        finally { deferral.Complete(); }
                    });
                }
                manager.DataRequested += Handler;
                DataTransferManagerInterop.ShowShareUIForWindow(window);
            }
            catch { }
        }
    }
}
