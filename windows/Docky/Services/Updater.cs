using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Threading;
using Docky.Core;

namespace Docky.Services
{
    /// <summary>
    /// Keeps Docky up to date from the latest GitHub release. New versions download quietly in
    /// the background; the island then offers to restart, or the update goes in when Docky quits.
    /// Installing: the downloaded exe is started with --apply-update, waits for this process to
    /// exit, copies itself over the old exe and starts it again.
    /// </summary>
    public sealed class Updater
    {
        public static Updater Shared { get; } = new();
        public const string Repo = "totallyrat/Docky";
        public const string ReleasesPage = "https://github.com/" + Repo + "/releases/latest";
        private const string LatestApi = "https://api.github.com/repos/" + Repo + "/releases/latest";

        public static Version Current
        {
            get
            {
                var v = typeof(Updater).Assembly.GetName().Version ?? new Version(0, 0, 0);
                return new Version(v.Major, v.Minor, Math.Max(0, v.Build));
            }
        }

        /// <summary>For Settings: e.g. "Checking for updates…" or "Docky 1.0.2 is ready to install."</summary>
        public string Status { get; private set; } = "";
        public bool Checking { get; private set; }
        public string ReadyVersion { get; private set; }
        public event Action StatusChanged;
        /// <summary>Raised on the UI thread when a new version is downloaded and checked.</summary>
        public event Action<string> Ready;

        private string readyPath;
        private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromHours(6) };
        private static readonly HttpClient http = CreateClient();

        private static HttpClient CreateClient()
        {
            var c = new HttpClient { Timeout = TimeSpan.FromMinutes(10) };
            c.DefaultRequestHeaders.UserAgent.ParseAdd($"Docky/{Current} (Windows)");
            c.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json");
            return c;
        }

        private static string Folder
        {
            get { var d = Path.Combine(SettingsStore.Folder, "Updates"); Directory.CreateDirectory(d); return d; }
        }

        private void SetStatus(string s)
        {
            Status = s;
            StatusChanged?.Invoke();
        }

        public void Start()
        {
            CleanUp();
            // A download from last time that never got installed: offer it again.
            var pending = Directory.GetFiles(Folder, "Docky-*.exe")
                .Select(p => (path: p, version: ParseVersion(Path.GetFileNameWithoutExtension(p)[6..])))
                .Where(x => x.version != null && x.version > Current)
                .OrderByDescending(x => x.version).FirstOrDefault();
            if (pending.path != null) MarkReady(pending.version.ToString(3), pending.path, delay: 8);

            var first = new DispatcherTimer { Interval = TimeSpan.FromSeconds(25) };
            first.Tick += (_, _) => { first.Stop(); if (SettingsStore.Current.AutoUpdate) _ = Check(); };
            first.Start();
            timer.Tick += (_, _) => { if (SettingsStore.Current.AutoUpdate) _ = Check(); };
            timer.Start();
        }

        public static Version ParseVersion(string s)
        {
            s = (s ?? "").Trim().TrimStart('v', 'V');
            var parts = s.Split('.').Select(p => int.TryParse(new string(p.TakeWhile(char.IsDigit).ToArray()), out int n) ? n : 0).ToList();
            if (parts.Count == 0) return null;
            while (parts.Count < 3) parts.Add(0);
            return new Version(parts[0], parts[1], parts[2]);
        }

        public async Task Check()
        {
            if (Checking) return;
            if (ReadyVersion != null) { SetStatus($"Docky {ReadyVersion} is ready to install."); return; }
            Checking = true;
            SetStatus("Checking for updates…");
            try
            {
                using var doc = JsonDocument.Parse(await http.GetStringAsync(LatestApi));
                var root = doc.RootElement;
                var version = ParseVersion(root.GetProperty("tag_name").GetString());
                bool draft = root.TryGetProperty("draft", out var d) && d.GetBoolean();
                bool pre = root.TryGetProperty("prerelease", out var p) && p.GetBoolean();
                if (version == null || version <= Current || draft || pre) { SetStatus("You're up to date."); return; }

                var asset = root.GetProperty("assets").EnumerateArray()
                    .FirstOrDefault(a => a.GetProperty("name").GetString() == "Docky.exe");
                if (asset.ValueKind != JsonValueKind.Object) { SetStatus($"Docky {version.ToString(3)} has no Windows download yet."); return; }
                string url = asset.GetProperty("browser_download_url").GetString();
                long size = asset.GetProperty("size").GetInt64();
                string digest = asset.TryGetProperty("digest", out var dg) && dg.ValueKind == JsonValueKind.String ? dg.GetString() : null;

                string v = version.ToString(3);
                SetStatus($"Downloading Docky {v}…");
                string target = Path.Combine(Folder, $"Docky-{v}.exe");
                string partial = target + ".partial";
                using (var response = await http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead))
                {
                    response.EnsureSuccessStatusCode();
                    await using var input = await response.Content.ReadAsStreamAsync();
                    await using var output = File.Create(partial);
                    await input.CopyToAsync(output);
                }
                if (new FileInfo(partial).Length != size) throw new IOException("The download was incomplete.");
                if (digest != null && digest.StartsWith("sha256:", StringComparison.OrdinalIgnoreCase))
                {
                    string hash;
                    await using (var f = File.OpenRead(partial)) hash = Convert.ToHexString(await SHA256.HashDataAsync(f));
                    if (!string.Equals(hash, digest[7..], StringComparison.OrdinalIgnoreCase)) throw new IOException("The download didn't match its checksum.");
                }
                File.Move(partial, target, overwrite: true);
                MarkReady(v, target);
            }
            catch (Exception ex)
            {
                SetStatus(ex is HttpRequestException or TaskCanceledException ? "Couldn't reach GitHub." : ex.Message);
            }
            finally { Checking = false; StatusChanged?.Invoke(); }
        }

        private void MarkReady(string version, string path, double delay = 0)
        {
            ReadyVersion = version;
            readyPath = path;
            SetStatus($"Docky {version} is ready to install.");
            if (delay <= 0) { Ready?.Invoke(version); return; }
            var t = new DispatcherTimer { Interval = TimeSpan.FromSeconds(delay) };
            t.Tick += (_, _) => { t.Stop(); Ready?.Invoke(version); };
            t.Start();
        }

        /// <summary>Starts the new exe as the installer; the caller should quit right after.</summary>
        public bool Install(bool relaunch)
        {
            if (readyPath == null || !File.Exists(readyPath)) return false;
            string exe = Environment.ProcessPath;
            if (exe == null || !CanWrite(Path.GetDirectoryName(exe)))
            {
                SetStatus("Docky can't update itself in this folder. Download the new version from GitHub instead.");
                try { Process.Start(new ProcessStartInfo(ReleasesPage) { UseShellExecute = true }); } catch { }
                return false;
            }
            try
            {
                Process.Start(new ProcessStartInfo(readyPath)
                {
                    UseShellExecute = false,
                    ArgumentList = { "--apply-update", exe, Environment.ProcessId.ToString(), relaunch ? "relaunch" : "quiet" },
                });
                SetStatus($"Installing Docky {ReadyVersion}…");
                readyPath = null;
                return true;
            }
            catch (Exception ex)
            {
                SetStatus("Couldn't start the update: " + ex.Message);
                return false;
            }
        }

        public bool HasUpdate => readyPath != null;

        private static bool CanWrite(string dir)
        {
            try
            {
                string probe = Path.Combine(dir, $".docky-write-test-{Guid.NewGuid():N}");
                File.WriteAllText(probe, "");
                File.Delete(probe);
                return true;
            }
            catch { return false; }
        }

        /// <summary>
        /// Runs in the newly downloaded exe: waits for the old Docky to exit, copies this exe over
        /// it and starts it again. Returns the process exit code.
        /// </summary>
        public static int ApplyFromDownloaded(string target, string pidText, string mode)
        {
            try
            {
                if (int.TryParse(pidText, out int pid))
                {
                    try { using var old = Process.GetProcessById(pid); old.WaitForExit(20000); } catch { }
                }
                string self = Environment.ProcessPath;
                bool copied = false;
                for (int attempt = 0; attempt < 60 && !copied; attempt++)
                {
                    try { File.Copy(self, target, overwrite: true); copied = true; }
                    catch { Thread.Sleep(250); }
                }
                if (mode != "quiet") Process.Start(new ProcessStartInfo(target) { UseShellExecute = false, ArgumentList = { "--updated" } });
                return copied ? 0 : 1;
            }
            catch { return 1; }
        }

        /// <summary>Removes downloads for versions that are already installed (including the
        /// installer copy that just ran, once it has exited).</summary>
        private static void CleanUp()
        {
            foreach (var file in Directory.GetFiles(Folder))
            {
                string name = Path.GetFileName(file);
                var v = name.StartsWith("Docky-") ? ParseVersion(name[6..].Replace(".exe.partial", "").Replace(".exe", "")) : null;
                if (v != null && v > Current && !name.EndsWith(".partial")) continue;
                try { File.Delete(file); }
                catch
                {
                    // Still running for a moment after an update: try again shortly.
                    var retry = new DispatcherTimer { Interval = TimeSpan.FromSeconds(15) };
                    retry.Tick += (_, _) => { retry.Stop(); try { File.Delete(file); } catch { } };
                    retry.Start();
                }
            }
        }
    }
}
