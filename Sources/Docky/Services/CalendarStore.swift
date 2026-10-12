import AppKit
import Combine
import EventKit
import SwiftUI

struct CalEvent: Identifiable, Equatable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var color: Color
    var calendar: String
    var location: String?
    var joinURL: URL?

    func isHappening(at date: Date = Date()) -> Bool { !isAllDay && start <= date && date < end }
}

/// Reads events from every calendar in the macOS Calendar app — iCloud, Google, Exchange,
/// Outlook… whatever accounts are added there.
final class CalendarStore: ObservableObject {
    enum Access { case unknown, granted, denied }

    @Published private(set) var access: Access = .unknown
    @Published private(set) var days: [Date] = []
    @Published private(set) var events: [Date: [CalEvent]] = [:]
    @Published var selectedDay = Calendar.current.startOfDay(for: Date())

    private let store = EKEventStore()
    private var observer: NSObjectProtocol?
    private var dayTimer: Timer?

    init() {
        refreshAccess()
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            self?.reload()
        }
        // Roll over to a new day at midnight (and refresh "Now" badges every minute).
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        dayTimer = t
        reload()
    }

    private func refreshAccess() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: access = .granted
        case .notDetermined: access = .unknown
        default: access = .denied
        }
    }

    func requestAccess() {
        if access == .denied {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        store.requestFullAccessToEvents { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.refreshAccess()
                self?.reload()
            }
        }
    }

    private func tick() {
        let today = Calendar.current.startOfDay(for: Date())
        if days.first != today {
            if selectedDay < today { selectedDay = today }
            reload()
        } else {
            objectWillChange.send()
        }
    }

    func reload() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        days = (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: today) }
        guard access == .granted, let end = cal.date(byAdding: .day, value: 7, to: today) else {
            events = [:]
            return
        }
        let predicate = store.predicateForEvents(withStart: today, end: end, calendars: nil)
        var byDay: [Date: [CalEvent]] = [:]
        for e in store.events(matching: predicate) {
            let item = CalEvent(id: e.eventIdentifier ?? UUID().uuidString, title: e.title ?? "Untitled",
                                start: e.startDate, end: e.endDate, isAllDay: e.isAllDay,
                                color: Color(nsColor: e.calendar.color ?? .systemBlue),
                                calendar: e.calendar.title, location: e.location?.isEmpty == false ? e.location : nil,
                                joinURL: Self.meetingURL(e))
            // Multi-day events appear on every day they cover.
            var day = max(today, cal.startOfDay(for: e.startDate))
            while day < e.endDate && day < end {
                byDay[day, default: []].append(item)
                guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }
        for key in byDay.keys {
            byDay[key]?.sort { a, b in
                if a.isAllDay != b.isAllDay { return a.isAllDay }
                return a.start < b.start
            }
        }
        events = byDay
    }

    /// Finds a video-call link in the event (Zoom, Meet, Teams, Webex, FaceTime).
    private static func meetingURL(_ e: EKEvent) -> URL? {
        let hosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com", "facetime.apple.com", "whereby.com"]
        let candidates = [e.url?.absoluteString, e.location, e.notes].compactMap { $0 }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        for text in candidates {
            for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let url = match.url, let host = url.host, hosts.contains(where: { host.hasSuffix($0) }) { return url }
            }
        }
        return nil
    }

    func open(_ event: CalEvent) {
        if let url = URL(string: "ical://ekevent/\(event.id)?method=show&options=more"), NSWorkspace.shared.open(url) { return }
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.openApplication(at: app, configuration: .init())
        }
    }

    func openCalendarApp() {
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.openApplication(at: app, configuration: .init())
        }
    }

    static func openInternetAccounts() {
        let urls = ["x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension",
                    "x-apple.systempreferences:com.apple.preferences.internetaccounts"]
        for s in urls { if let u = URL(string: s), NSWorkspace.shared.open(u) { return } }
    }
}
