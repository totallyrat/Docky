using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Media;
using System.Text.Json;
using System.Windows.Threading;
using Docky.Core;

namespace Docky.Services
{
    public sealed class IslandTimer
    {
        public Guid Id { get; set; } = Guid.NewGuid();
        public string Label { get; set; } = "";
        public double Duration { get; set; }
        public DateTime? EndDate { get; set; }
        public double? PausedRemaining { get; set; }
        public bool IsRunning => EndDate != null;
        public double Remaining => EndDate is DateTime e ? Math.Max(0, (e - DateTime.Now).TotalSeconds) : PausedRemaining ?? Duration;
        public double Progress => Duration > 0 ? Math.Clamp(Remaining / Duration, 0, 1) : 0;
        public string Title => Label.Length > 0 ? Label : DurationTitle(Duration);

        public static string DurationTitle(double seconds)
        {
            int t = (int)Math.Round(seconds), h = t / 3600, m = t % 3600 / 60, s = t % 60;
            var parts = new List<string>();
            if (h > 0) parts.Add(h + " hr");
            if (m > 0) parts.Add(m + " min");
            if (s > 0) parts.Add(s + " sec");
            return parts.Count == 0 ? "0 sec" : string.Join(" ", parts);
        }
    }

    public sealed class IslandAlarm
    {
        public Guid Id { get; set; } = Guid.NewGuid();
        public int Hour { get; set; }
        public int Minute { get; set; }
        public string Label { get; set; } = "";
        public bool Enabled { get; set; } = true;
        public List<int> RepeatDays { get; set; } = new(); // 0 = Sunday … 6 = Saturday
        public DateTime? SnoozeUntil { get; set; }
        public string LastFiredKey { get; set; }

        public string RepeatSummary
        {
            get
            {
                if (RepeatDays.Count == 0) return "Once";
                if (RepeatDays.Count == 7) return "Every day";
                var set = RepeatDays.ToHashSet();
                if (set.SetEquals(new[] { 1, 2, 3, 4, 5 })) return "Weekdays";
                if (set.SetEquals(new[] { 0, 6 })) return "Weekends";
                var names = System.Globalization.CultureInfo.CurrentCulture.DateTimeFormat.AbbreviatedDayNames;
                return string.Join(" ", RepeatDays.OrderBy(d => d).Select(d => names[d]));
            }
        }

        public DateTime? NextFire()
        {
            if (SnoozeUntil is DateTime s && s > DateTime.Now) return s;
            if (!Enabled) return null;
            for (int i = 0; i <= 7; i++)
            {
                var day = DateTime.Today.AddDays(i);
                var t = day.AddHours(Hour).AddMinutes(Minute);
                if (t <= DateTime.Now) continue;
                if (RepeatDays.Count == 0 || RepeatDays.Contains((int)t.DayOfWeek)) return t;
            }
            return null;
        }
    }

    public sealed class IslandReminder
    {
        public Guid Id { get; set; } = Guid.NewGuid();
        public string Title { get; set; } = "";
        public DateTime? Due { get; set; }
        public bool Completed { get; set; }
        public bool Fired { get; set; }
        public DateTime Created { get; set; } = DateTime.Now;
    }

    public sealed class PomodoroConfig
    {
        public int WorkMinutes { get; set; } = 25;
        public int BreakMinutes { get; set; } = 5;
        public int LongBreakMinutes { get; set; } = 15;
        public int RoundsBeforeLongBreak { get; set; } = 4;
        public bool AutoStartFocus { get; set; } = false;
        public bool BreakGlow { get; set; } = true;
    }

    public sealed class PomodoroSession
    {
        public bool IsRest { get; set; }
        public double Duration { get; set; }
        public DateTime? EndDate { get; set; }
        public double? PausedRemaining { get; set; }
        public int CompletedRounds { get; set; }
        public bool IsLongBreak { get; set; }
        public bool IsRunning => EndDate != null;
        public double Remaining => EndDate is DateTime e ? Math.Max(0, (e - DateTime.Now).TotalSeconds) : PausedRemaining ?? Duration;
        public double Progress => Duration > 0 ? Math.Clamp(Remaining / Duration, 0, 1) : 0;
    }

    public sealed class IslandAlert
    {
        public enum Kind { Timer, Alarm, Reminder, BreakOver }
        public Kind Type;
        public string Key;
        public IslandTimer Timer;
        public IslandAlarm Alarm;
        public IslandReminder Reminder;
        public DateTime FiredAt = DateTime.Now;
        public int Round;
    }

    /// <summary>Everything time-based in the island, persisted to %APPDATA%\Docky\clock.json.</summary>
    public sealed class ClockService
    {
        public static ClockService Shared { get; } = new();

        public List<IslandTimer> Timers { get; private set; } = new();
        public List<IslandAlarm> Alarms { get; private set; } = new();
        public List<IslandReminder> Reminders { get; private set; } = new();
        public PomodoroConfig Pomodoro { get; private set; } = new();
        public PomodoroSession Session { get; private set; }
        public List<IslandAlert> Alerts { get; } = new();

        public event Action Changed;
        public event Action BreakStarted;

        private readonly DispatcherTimer ticker = new() { Interval = TimeSpan.FromMilliseconds(500) };
        private SoundPlayer player;
        private string playingKey;

        private sealed class Snapshot
        {
            public List<IslandTimer> Timers { get; set; } = new();
            public List<IslandAlarm> Alarms { get; set; } = new();
            public List<IslandReminder> Reminders { get; set; } = new();
            public PomodoroConfig Pomodoro { get; set; } = new();
            public PomodoroSession Session { get; set; }
        }

        private static string FilePath => Path.Combine(SettingsStore.Folder, "clock.json");

        public void Start()
        {
            Load();
            ticker.Tick += (_, _) => Tick();
            ticker.Start();
        }

        private void Load()
        {
            try
            {
                if (!File.Exists(FilePath)) return;
                var s = JsonSerializer.Deserialize<Snapshot>(File.ReadAllText(FilePath));
                if (s == null) return;
                Timers = s.Timers ?? new();
                Alarms = s.Alarms ?? new();
                Reminders = s.Reminders ?? new();
                Pomodoro = s.Pomodoro ?? new();
                Session = s.Session;
            }
            catch { }
        }

        public void Save()
        {
            try
            {
                var s = new Snapshot { Timers = Timers, Alarms = Alarms, Reminders = Reminders, Pomodoro = Pomodoro, Session = Session };
                File.WriteAllText(FilePath, JsonSerializer.Serialize(s, SettingsStore.Json));
            }
            catch { }
        }

        private void Notify() { Save(); Changed?.Invoke(); }

        public IslandTimer ActiveTimer => Timers.Where(t => t.IsRunning).OrderBy(t => t.Remaining).FirstOrDefault() ?? Timers.FirstOrDefault();

        public (IslandAlarm alarm, DateTime when)? NextAlarm =>
            Alarms.Select(a => (a, a.NextFire())).Where(x => x.Item2 != null).OrderBy(x => x.Item2)
                  .Select(x => ((IslandAlarm, DateTime)?)(x.a, x.Item2.Value)).FirstOrDefault();

        // Timers
        public void StartTimer(double seconds, string label = "")
        {
            if (seconds < 1) return;
            Timers.Add(new IslandTimer { Duration = seconds, Label = label, EndDate = DateTime.Now.AddSeconds(seconds) });
            Notify();
        }

        public void ToggleTimer(IslandTimer t)
        {
            if (t.EndDate is DateTime e) { t.PausedRemaining = Math.Max(0, (e - DateTime.Now).TotalSeconds); t.EndDate = null; }
            else { t.EndDate = DateTime.Now.AddSeconds(t.PausedRemaining ?? t.Duration); t.PausedRemaining = null; }
            Notify();
        }

        public void CancelTimer(IslandTimer t) { Timers.Remove(t); Notify(); }

        // Alarms & reminders
        public void AddAlarm(IslandAlarm a) { Alarms.Add(a); Alarms = Alarms.OrderBy(x => x.Hour * 60 + x.Minute).ToList(); Notify(); }
        public void DeleteAlarm(IslandAlarm a) { Alarms.Remove(a); Notify(); }
        public void SetAlarm(IslandAlarm a, bool enabled) { a.Enabled = enabled; if (!enabled) a.SnoozeUntil = null; Notify(); }

        public void AddReminder(string title, DateTime? due)
        {
            title = (title ?? "").Trim();
            if (title.Length == 0) return;
            Reminders.Add(new IslandReminder { Title = title, Due = due });
            Reminders = Reminders.OrderBy(r => r.Due ?? DateTime.MaxValue).ThenBy(r => r.Created).ToList();
            Notify();
        }

        public void CompleteReminder(IslandReminder r)
        {
            r.Completed = true;
            Alerts.RemoveAll(a => a.Reminder == r);
            RefreshSound();
            Notify();
        }

        public void DeleteReminder(IslandReminder r) { Reminders.Remove(r); Notify(); }
        public void ClearCompleted() { Reminders.RemoveAll(r => r.Completed); Notify(); }

        // Pomodoro
        public void StartPomodoro()
        {
            double focus = Math.Max(1, Pomodoro.WorkMinutes) * 60;
            Session = new PomodoroSession { Duration = focus, EndDate = DateTime.Now.AddSeconds(focus), CompletedRounds = Session?.CompletedRounds ?? 0 };
            Alerts.RemoveAll(a => a.Type == IslandAlert.Kind.BreakOver);
            RefreshSound();
            Notify();
        }

        /// <summary>Demo/testing: a short Pomodoro measured in seconds.</summary>
        public void StartPomodoroSeconds(double focus, double rest)
        {
            debugRest = rest;
            Session = new PomodoroSession { Duration = focus, EndDate = DateTime.Now.AddSeconds(focus) };
            Notify();
        }
        private double? debugRest;

        public void TogglePomodoro()
        {
            if (Session == null) return;
            if (Session.EndDate is DateTime e) { Session.PausedRemaining = Math.Max(0, (e - DateTime.Now).TotalSeconds); Session.EndDate = null; }
            else { Session.EndDate = DateTime.Now.AddSeconds(Session.PausedRemaining ?? Session.Duration); Session.PausedRemaining = null; }
            Notify();
        }

        public void SkipPomodoro() { if (Session != null) Advance(); }

        public void StopPomodoro()
        {
            Session = null;
            Alerts.RemoveAll(a => a.Type == IslandAlert.Kind.BreakOver);
            RefreshSound();
            Notify();
        }

        private void Advance()
        {
            var s = Session;
            var c = Pomodoro;
            if (!s.IsRest)
            {
                int rounds = s.CompletedRounds + 1;
                bool longBreak = c.RoundsBeforeLongBreak > 0 && rounds % c.RoundsBeforeLongBreak == 0;
                double rest = debugRest ?? Math.Max(1, longBreak ? c.LongBreakMinutes : c.BreakMinutes) * 60;
                Session = new PomodoroSession { IsRest = true, Duration = rest, EndDate = DateTime.Now.AddSeconds(rest), CompletedRounds = rounds, IsLongBreak = longBreak };
                PlayOnce("Chime");
                Notify();
                BreakStarted?.Invoke();
            }
            else
            {
                double focus = Math.Max(1, c.WorkMinutes) * 60;
                if (c.AutoStartFocus)
                {
                    Session = new PomodoroSession { Duration = focus, EndDate = DateTime.Now.AddSeconds(focus), CompletedRounds = s.CompletedRounds };
                    PlayOnce("Chime");
                }
                else
                {
                    Session = new PomodoroSession { Duration = focus, PausedRemaining = focus, CompletedRounds = s.CompletedRounds };
                    Present(new IslandAlert { Type = IslandAlert.Kind.BreakOver, Key = "break-over-" + s.CompletedRounds, Round = s.CompletedRounds });
                }
                Notify();
            }
        }

        // Alerts
        public void Dismiss(IslandAlert a) { Alerts.Remove(a); RefreshSound(); Changed?.Invoke(); }

        public void Snooze(IslandAlert a)
        {
            int minutes = SettingsStore.Current.SnoozeMinutes;
            if (a.Alarm != null) a.Alarm.SnoozeUntil = DateTime.Now.AddMinutes(minutes);
            if (a.Reminder != null) { a.Reminder.Due = DateTime.Now.AddMinutes(minutes); a.Reminder.Fired = false; }
            Dismiss(a);
            Save();
        }

        public void RepeatTimer(IslandAlert a)
        {
            if (a.Timer != null) StartTimer(a.Timer.Duration, a.Timer.Label);
            Dismiss(a);
        }

        public void FireTestAlarm()
            => Present(new IslandAlert { Type = IslandAlert.Kind.Alarm, Key = "test-" + DateTime.Now.Ticks, Alarm = new IslandAlarm { Hour = DateTime.Now.Hour, Minute = DateTime.Now.Minute, Label = "Test Alarm" } });

        private void Present(IslandAlert a)
        {
            if (Alerts.Any(x => x.Key == a.Key)) return;
            Alerts.Add(a);
            RefreshSound();
            Changed?.Invoke();
        }

        private void Tick()
        {
            var now = DateTime.Now;
            bool changed = false;

            if (Session != null && Session.IsRunning && Session.Remaining <= 0) Advance();

            foreach (var t in Timers.Where(t => t.IsRunning && t.Remaining <= 0).ToList())
            {
                Timers.Remove(t);
                Present(new IslandAlert { Type = IslandAlert.Kind.Timer, Key = "timer-" + t.Id, Timer = t });
                changed = true;
            }

            string minuteKey = now.ToString("yyyy-MM-dd-HH-mm");
            foreach (var a in Alarms)
            {
                if (a.SnoozeUntil is DateTime s && s <= now)
                {
                    a.SnoozeUntil = null;
                    Present(new IslandAlert { Type = IslandAlert.Kind.Alarm, Key = "alarm-" + a.Id + now.Ticks, Alarm = a });
                    changed = true;
                    continue;
                }
                if (!a.Enabled || a.Hour != now.Hour || a.Minute != now.Minute || a.LastFiredKey == minuteKey) continue;
                if (a.RepeatDays.Count > 0 && !a.RepeatDays.Contains((int)now.DayOfWeek)) continue;
                a.LastFiredKey = minuteKey;
                if (a.RepeatDays.Count == 0) a.Enabled = false;
                Present(new IslandAlert { Type = IslandAlert.Kind.Alarm, Key = "alarm-" + a.Id + minuteKey, Alarm = a });
                changed = true;
            }

            foreach (var r in Reminders.Where(r => !r.Completed && !r.Fired && r.Due is DateTime d && d <= now))
            {
                r.Fired = true;
                Present(new IslandAlert { Type = IslandAlert.Kind.Reminder, Key = "reminder-" + r.Id, Reminder = r });
                changed = true;
            }
            if (changed) Notify();
        }

        // Sounds

        private void RefreshSound()
        {
            var top = Alerts.FirstOrDefault();
            if (top == null) { StopSound(); return; }
            if (top.Key == playingKey) return;
            StopSound();
            playingKey = top.Key;
            var s = SettingsStore.Current;
            switch (top.Type)
            {
                case IslandAlert.Kind.Alarm: Play(s.AlarmSound, loop: true); break;
                case IslandAlert.Kind.Timer: Play(s.TimerSound, loop: true); break;
                default: Play("Chime", loop: false); break;
            }
        }

        private void StopSound()
        {
            try { player?.Stop(); } catch { }
            player = null;
            playingKey = null;
        }

        public static System.IO.Stream SoundStream(string name)
        {
            var asm = typeof(ClockService).Assembly;
            return asm.GetManifestResourceStream("Sounds." + name + ".wav") ?? asm.GetManifestResourceStream("Sounds.Chime.wav");
        }

        private void Play(string name, bool loop)
        {
            try
            {
                player = new SoundPlayer(SoundStream(name));
                if (loop) player.PlayLooping(); else player.Play();
            }
            catch { }
        }

        public void PlayOnce(string name)
        {
            try { new SoundPlayer(SoundStream(name)).Play(); } catch { }
        }
    }
}
