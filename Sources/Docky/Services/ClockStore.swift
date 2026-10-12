import AppKit
import Combine

struct IslandTimer: Identifiable, Codable, Equatable {
    var id = UUID()
    var label: String = ""
    var duration: TimeInterval
    /// Set while running.
    var endDate: Date?
    /// Set while paused.
    var pausedRemaining: TimeInterval?

    var isRunning: Bool { endDate != nil }

    func remaining(at now: Date = Date()) -> TimeInterval {
        if let endDate { return max(0, endDate.timeIntervalSince(now)) }
        return pausedRemaining ?? duration
    }

    func progress(at now: Date = Date()) -> Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, remaining(at: now) / duration))
    }

    var title: String { label.isEmpty ? IslandFormat.durationTitle(duration) : label }
}

struct IslandAlarm: Identifiable, Codable, Equatable {
    var id = UUID()
    var hour: Int
    var minute: Int
    var label: String = ""
    var isEnabled = true
    /// Calendar weekdays (1 = Sunday … 7 = Saturday). Empty means "once".
    var repeatDays: [Int] = []
    var snoozeUntil: Date?
    var lastFiredKey: String?

    var repeatSummary: String {
        let days = Set(repeatDays)
        if days.isEmpty { return "Once" }
        if days.count == 7 { return "Every day" }
        if days == [2, 3, 4, 5, 6] { return "Weekdays" }
        if days == [1, 7] { return "Weekends" }
        let symbols = Calendar.current.shortWeekdaySymbols
        return repeatDays.sorted().map { symbols[$0 - 1] }.joined(separator: " ")
    }

    func nextFireDate(after date: Date = Date()) -> Date? {
        if let snoozeUntil, snoozeUntil > date { return snoozeUntil }
        guard isEnabled else { return nil }
        let cal = Calendar.current
        for offset in 0...7 {
            guard let day = cal.date(byAdding: .day, value: offset, to: date),
                  let candidate = cal.date(bySettingHour: hour, minute: minute, second: 0, of: day),
                  candidate > date
            else { continue }
            if repeatDays.isEmpty || repeatDays.contains(cal.component(.weekday, from: candidate)) {
                return candidate
            }
        }
        return nil
    }
}

struct IslandReminder: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var dueDate: Date?
    var isCompleted = false
    var hasFired = false
    var createdAt = Date()
}

/// Pomodoro preferences: everything is adjustable.
struct PomodoroConfig: Codable, Equatable {
    var workMinutes = 25
    var breakMinutes = 5
    var longBreakMinutes = 15
    /// A long break after this many focus sessions (0 = never).
    var roundsBeforeLongBreak = 4
    /// Start the next focus session automatically when a break ends.
    var autoStartFocus = false
    /// Show the warm glow around the screen when a break starts.
    var breakGlow = true
}

struct PomodoroSession: Codable, Equatable {
    enum Phase: String, Codable { case focus, rest }
    var phase: Phase
    var duration: TimeInterval
    var endDate: Date?
    var pausedRemaining: TimeInterval?
    /// Focus sessions finished so far.
    var completedRounds = 0
    var isLongBreak = false

    var isRunning: Bool { endDate != nil }

    func remaining(at now: Date = Date()) -> TimeInterval {
        if let endDate { return max(0, endDate.timeIntervalSince(now)) }
        return pausedRemaining ?? duration
    }

    func progress(at now: Date = Date()) -> Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, remaining(at: now) / duration))
    }
}

enum IslandAlert: Identifiable, Equatable {
    case timerDone(IslandTimer)
    case alarm(IslandAlarm, firedAt: Date)
    case reminder(IslandReminder)
    case breakOver(round: Int)

    var id: String {
        switch self {
        case .breakOver(let round): return "pomodoro-break-over-\(round)"
        case .timerDone(let t): return "timer-\(t.id)"
        case .alarm(let a, let date): return "alarm-\(a.id)-\(date.timeIntervalSince1970)"
        case .reminder(let r): return "reminder-\(r.id)"
        }
    }
}

/// Owns everything time-based that lives inside the island.
final class ClockStore: ObservableObject {
    @Published var timers: [IslandTimer] = [] { didSet { scheduleSave() } }
    @Published var alarms: [IslandAlarm] = [] { didSet { scheduleSave() } }
    @Published var reminders: [IslandReminder] = [] { didSet { scheduleSave() } }
    @Published private(set) var alerts: [IslandAlert] = []

    /// The last custom duration entered, so the composer remembers it.
    @Published var draftDuration: TimeInterval = 5 * 60

    private let prefs: PreferencesStore
    private let sound = AlertSoundPlayer()
    private var ticker: Timer?
    private var saveWork: DispatchWorkItem?
    private var loading = false

    private struct Snapshot: Codable {
        var timers: [IslandTimer]
        var alarms: [IslandAlarm]
        var reminders: [IslandReminder]
        var draftDuration: TimeInterval?
        var pomodoroConfig: PomodoroConfig?
        var pomodoro: PomodoroSession?
    }

    @Published var pomodoroConfig = PomodoroConfig() { didSet { scheduleSave() } }
    @Published private(set) var pomodoro: PomodoroSession? { didSet { scheduleSave() } }
    /// Bumped each time a focus session ends and a break begins (drives the glow).
    @Published private(set) var breakStartedCount = 0

    // MARK: Pomodoro

    func startPomodoro() {
        let focus = TimeInterval(max(1, pomodoroConfig.workMinutes) * 60)
        pomodoro = PomodoroSession(phase: .focus, duration: focus, endDate: Date().addingTimeInterval(focus),
                                   completedRounds: pomodoro?.completedRounds ?? 0)
        alerts.removeAll { if case .breakOver = $0 { return true }; return false }
        refreshSound()
    }

    func togglePomodoro() {
        guard var s = pomodoro else { return }
        if let end = s.endDate {
            s.pausedRemaining = max(0, end.timeIntervalSinceNow)
            s.endDate = nil
        } else {
            s.endDate = Date().addingTimeInterval(s.pausedRemaining ?? s.duration)
            s.pausedRemaining = nil
        }
        pomodoro = s
    }

    /// Jumps straight to the next phase.
    func skipPomodoroPhase() {
        guard let s = pomodoro else { return }
        advancePomodoro(from: s, now: Date())
    }

    #if DOCKY_DEBUG
    var debugRestSeconds: TimeInterval?
    func debugStartPomodoro(focus: TimeInterval, rest: TimeInterval) {
        debugRestSeconds = rest
        pomodoro = PomodoroSession(phase: .focus, duration: focus, endDate: Date().addingTimeInterval(focus))
    }
    #endif

    func stopPomodoro() {
        pomodoro = nil
        alerts.removeAll { if case .breakOver = $0 { return true }; return false }
        refreshSound()
    }

    private func advancePomodoro(from s: PomodoroSession, now: Date) {
        let c = pomodoroConfig
        switch s.phase {
        case .focus:
            let rounds = s.completedRounds + 1
            let long = c.roundsBeforeLongBreak > 0 && rounds % c.roundsBeforeLongBreak == 0
            var rest = TimeInterval(max(1, long ? c.longBreakMinutes : c.breakMinutes) * 60)
            #if DOCKY_DEBUG
            if let debugRestSeconds { rest = debugRestSeconds }
            #endif
            pomodoro = PomodoroSession(phase: .rest, duration: rest, endDate: now.addingTimeInterval(rest),
                                       completedRounds: rounds, isLongBreak: long)
            breakStartedCount += 1
            sound.playOnce("Chime")
        case .rest:
            let focus = TimeInterval(max(1, c.workMinutes) * 60)
            if c.autoStartFocus {
                pomodoro = PomodoroSession(phase: .focus, duration: focus, endDate: now.addingTimeInterval(focus),
                                           completedRounds: s.completedRounds)
                sound.playOnce("Chime")
            } else {
                pomodoro = PomodoroSession(phase: .focus, duration: focus, endDate: nil, pausedRemaining: focus,
                                           completedRounds: s.completedRounds)
                present(.breakOver(round: s.completedRounds))
            }
        }
    }

    init(prefs: PreferencesStore) {
        self.prefs = prefs
        load()
    }

    func start() {
        ticker?.invalidate()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        ticker = t
        tick()
    }

    var activeTimer: IslandTimer? {
        timers.filter(\.isRunning).min { $0.remaining() < $1.remaining() } ?? timers.first
    }

    var nextAlarm: (alarm: IslandAlarm, date: Date)? {
        alarms.compactMap { a in a.nextFireDate().map { (a, $0) } }.min { $0.1 < $1.1 }
    }

    // MARK: Timers

    func startTimer(duration: TimeInterval, label: String = "") {
        guard duration >= 1 else { return }
        timers.append(IslandTimer(label: label, duration: duration, endDate: Date().addingTimeInterval(duration)))
    }

    func toggleTimer(_ id: UUID) {
        guard let i = timers.firstIndex(where: { $0.id == id }) else { return }
        var t = timers[i]
        if let end = t.endDate {
            t.pausedRemaining = max(0, end.timeIntervalSinceNow)
            t.endDate = nil
        } else {
            t.endDate = Date().addingTimeInterval(t.pausedRemaining ?? t.duration)
            t.pausedRemaining = nil
        }
        timers[i] = t
    }

    func cancelTimer(_ id: UUID) {
        timers.removeAll { $0.id == id }
    }

    // MARK: Alarms

    func addAlarm(_ alarm: IslandAlarm) {
        alarms.append(alarm)
        alarms.sort { ($0.hour, $0.minute) < ($1.hour, $1.minute) }
    }

    func setAlarm(_ id: UUID, enabled: Bool) {
        guard let i = alarms.firstIndex(where: { $0.id == id }) else { return }
        alarms[i].isEnabled = enabled
        if !enabled { alarms[i].snoozeUntil = nil }
    }

    func deleteAlarm(_ id: UUID) {
        alarms.removeAll { $0.id == id }
    }

    // MARK: Reminders

    func addReminder(title: String, due: Date?) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        reminders.append(IslandReminder(title: trimmed, dueDate: due))
        sortReminders()
    }

    func completeReminder(_ id: UUID) {
        guard let i = reminders.firstIndex(where: { $0.id == id }) else { return }
        reminders[i].isCompleted = true
        alerts.removeAll { if case .reminder(let r) = $0 { return r.id == id }; return false }
        refreshSound()
    }

    func uncompleteReminder(_ id: UUID) {
        guard let i = reminders.firstIndex(where: { $0.id == id }) else { return }
        reminders[i].isCompleted = false
    }

    func deleteReminder(_ id: UUID) {
        reminders.removeAll { $0.id == id }
    }

    func clearCompleted() {
        reminders.removeAll(where: \.isCompleted)
    }

    private func sortReminders() {
        reminders.sort { a, b in
            switch (a.dueDate, b.dueDate) {
            case let (x?, y?): return x < y
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return a.createdAt < b.createdAt
            }
        }
    }

    // MARK: Alerts

    func dismissAlert(_ alert: IslandAlert) {
        alerts.removeAll { $0.id == alert.id }
        refreshSound()
    }

    func snooze(_ alert: IslandAlert) {
        let minutes = prefs.values.snoozeMinutes
        switch alert {
        case .alarm(let a, _):
            if let i = alarms.firstIndex(where: { $0.id == a.id }) {
                alarms[i].snoozeUntil = Date().addingTimeInterval(TimeInterval(minutes * 60))
            }
        case .reminder(let r):
            if let i = reminders.firstIndex(where: { $0.id == r.id }) {
                reminders[i].dueDate = Date().addingTimeInterval(TimeInterval(minutes * 60))
                reminders[i].hasFired = false
                sortReminders()
            }
        case .timerDone, .breakOver:
            break
        }
        dismissAlert(alert)
    }

    func repeatTimer(_ alert: IslandAlert) {
        if case .timerDone(let t) = alert {
            startTimer(duration: t.duration, label: t.label)
        }
        dismissAlert(alert)
    }

    /// Fires a demo alarm (used by Docky Settings' "Test Alarm" button).
    func fireTestAlarm() {
        let now = Calendar.current.dateComponents([.hour, .minute], from: Date())
        present(.alarm(IslandAlarm(hour: now.hour ?? 7, minute: now.minute ?? 0, label: "Test Alarm"), firedAt: Date()))
    }

    private func present(_ alert: IslandAlert) {
        guard !alerts.contains(where: { $0.id == alert.id }) else { return }
        alerts.append(alert)
        refreshSound()
    }

    private func refreshSound() {
        guard let top = alerts.first else {
            sound.stop()
            return
        }
        let p = prefs.values
        switch top {
        case .alarm: sound.play(p.alarmSound, loop: true, maxDuration: 10 * 60, key: top.id)
        case .timerDone: sound.play(p.timerSound, loop: true, maxDuration: 2 * 60, key: top.id)
        case .reminder: sound.play(p.reminderSound, loop: false, maxDuration: 10, key: top.id)
        case .breakOver: sound.play("Chime", loop: false, maxDuration: 10, key: top.id)
        }
    }

    // MARK: Ticking

    private func tick() {
        let now = Date()

        // Pomodoro
        if let s = pomodoro, s.isRunning, s.remaining(at: now) <= 0 {
            advancePomodoro(from: s, now: now)
        }

        // Timers
        let finished = timers.filter { $0.isRunning && $0.remaining(at: now) <= 0 }
        if !finished.isEmpty {
            timers.removeAll { t in finished.contains { $0.id == t.id } }
            finished.forEach { present(.timerDone($0)) }
        }

        // Alarms
        let cal = Calendar.current
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: now)
        let minuteKey = "\(c.year!)-\(c.month!)-\(c.day!)-\(c.hour!)-\(c.minute!)"
        for i in alarms.indices {
            var a = alarms[i]
            if let snooze = a.snoozeUntil, snooze <= now {
                a.snoozeUntil = nil
                alarms[i] = a
                present(.alarm(a, firedAt: now))
                continue
            }
            guard a.isEnabled, a.hour == c.hour, a.minute == c.minute, a.lastFiredKey != minuteKey else { continue }
            if !a.repeatDays.isEmpty && !a.repeatDays.contains(c.weekday!) { continue }
            a.lastFiredKey = minuteKey
            if a.repeatDays.isEmpty { a.isEnabled = false }
            alarms[i] = a
            present(.alarm(a, firedAt: now))
        }

        // Reminders
        for i in reminders.indices {
            let r = reminders[i]
            guard !r.isCompleted, !r.hasFired, let due = r.dueDate, due <= now else { continue }
            reminders[i].hasFired = true
            present(.reminder(reminders[i]))
        }
    }

    // MARK: Persistence

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Docky", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("clock.json")
    }

    private func load() {
        loading = true
        defer { loading = false }
        guard let data = try? Data(contentsOf: Self.fileURL),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return }
        timers = snap.timers
        alarms = snap.alarms
        reminders = snap.reminders
        draftDuration = snap.draftDuration ?? draftDuration
        pomodoroConfig = snap.pomodoroConfig ?? pomodoroConfig
        pomodoro = snap.pomodoro
    }

    private func scheduleSave() {
        guard !loading else { return }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func save() {
        let snap = Snapshot(timers: timers, alarms: alarms, reminders: reminders, draftDuration: draftDuration,
                            pomodoroConfig: pomodoroConfig, pomodoro: pomodoro)
        guard let data = try? JSONEncoder().encode(snap) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}

/// Plays (and repeats) alert sounds.
final class AlertSoundPlayer {
    private var sound: NSSound?
    private var repeater: Timer?
    private var stopper: DispatchWorkItem?
    private var currentKey: String?

    func play(_ name: String, loop: Bool, maxDuration: TimeInterval, key: String) {
        guard key != currentKey else { return }
        stop()
        currentKey = key
        guard let url = DockySounds.url(for: name), let s = NSSound(contentsOf: url, byReference: true) else { return }
        sound = s
        s.play()
        if loop {
            let gap = max(0.4, s.duration + 0.5)
            let t = Timer(timeInterval: gap, repeats: true) { [weak self] _ in
                guard let self, let s = self.sound else { return }
                if !s.isPlaying { s.play() }
            }
            RunLoop.main.add(t, forMode: .common)
            repeater = t
        }
        let work = DispatchWorkItem { [weak self] in self?.silence() }
        stopper = work
        DispatchQueue.main.asyncAfter(deadline: .now() + maxDuration, execute: work)
    }

    /// Stops audio but remembers the key so the same alert doesn't start ringing again.
    private func silence() {
        repeater?.invalidate()
        repeater = nil
        sound?.stop()
        sound = nil
    }

    /// A one-off sound that doesn't interrupt (or get stopped by) alert ringing.
    private var oneShot: NSSound?
    func playOnce(_ name: String) {
        guard let url = DockySounds.url(for: name) else { return }
        oneShot = NSSound(contentsOf: url, byReference: true)
        oneShot?.play()
    }

    func stop() {
        silence()
        stopper?.cancel()
        stopper = nil
        currentKey = nil
    }
}

enum IslandFormat {
    static func clock(_ seconds: TimeInterval, roundUp: Bool = false) -> String {
        let total = max(0, Int(roundUp ? seconds.rounded(.up) : seconds.rounded(.down)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func durationTitle(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        var parts: [String] = []
        if h > 0 { parts.append("\(h) hr") }
        if m > 0 { parts.append("\(m) min") }
        if s > 0 { parts.append("\(s) sec") }
        return parts.isEmpty ? "0 sec" : parts.joined(separator: " ")
    }

    static func time(hour: Int, minute: Int, use24Hour: Bool) -> (time: String, suffix: String) {
        if use24Hour { return (String(format: "%d:%02d", hour, minute), "") }
        let h12 = hour % 12 == 0 ? 12 : hour % 12
        return (String(format: "%d:%02d", h12, minute), hour < 12 ? "AM" : "PM")
    }

    static func relativeDue(_ date: Date, use24Hour: Bool) -> String {
        let cal = Calendar.current
        let c = cal.dateComponents([.hour, .minute], from: date)
        let t = time(hour: c.hour ?? 0, minute: c.minute ?? 0, use24Hour: use24Hour)
        let clock = t.suffix.isEmpty ? t.time : "\(t.time) \(t.suffix)"
        if cal.isDateInToday(date) { return "Today, \(clock)" }
        if cal.isDateInTomorrow(date) { return "Tomorrow, \(clock)" }
        if cal.isDateInYesterday(date) { return "Yesterday, \(clock)" }
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return "\(f.string(from: date)), \(clock)"
    }
}
