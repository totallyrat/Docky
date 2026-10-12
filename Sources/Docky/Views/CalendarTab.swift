import AppKit
import SwiftUI

private let todayRed = Color(red: 1.0, green: 0.27, blue: 0.27)

struct CalendarTab: View {
    @EnvironmentObject var model: IslandModel
    @EnvironmentObject var calendar: CalendarStore

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(calendar.days, id: \.self) { day in
                    DayCell(day: day)
                }
                Spacer(minLength: 4)
                IconButton(symbol: "arrow.up.forward.app", size: 12, tint: .white.opacity(0.6)) { calendar.openCalendarApp() }
                    .help("Open Calendar")
            }
            ZStack(alignment: .top) {
                if calendar.access != .granted {
                    ConnectCalendar()
                        .transition(.island())
                } else {
                    let items = calendar.events[calendar.selectedDay] ?? []
                    if items.isEmpty {
                        EmptyState(symbol: "calendar", title: "Nothing Scheduled",
                                   subtitle: Calendar.current.isDateInToday(calendar.selectedDay) ? "The rest of today is yours." : "A free day.")
                            .transition(.island())
                    } else {
                        ScrollView(.vertical, showsIndicators: false) {
                            VStack(spacing: 2) {
                                ForEach(items) { EventRow(event: $0) }
                            }
                        }
                        .id(calendar.selectedDay)
                        .transition(.island(anchor: .top))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(.spring(response: 0.38, dampingFraction: 0.86), value: calendar.selectedDay)
        }
        .onAppear { calendar.reload() }
    }
}

private struct DayCell: View {
    @EnvironmentObject var calendar: CalendarStore
    let day: Date

    var body: some View {
        let cal = Calendar.current
        let today = cal.isDateInToday(day)
        let selected = cal.isDate(day, inSameDayAs: calendar.selectedDay)
        let hasEvents = !(calendar.events[day] ?? []).isEmpty
        Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) { calendar.selectedDay = day }
        } label: {
            VStack(spacing: 3) {
                Text(day.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(today ? todayRed : Color.white.opacity(0.4))
                Text("\(cal.component(.day, from: day))")
                    .font(.system(size: 14, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(selected ? Color.white : (today ? todayRed : Color.white.opacity(0.85)))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(selected ? (today ? todayRed : Color.white.opacity(0.2)) : Color.clear))
                Circle()
                    .fill(Color.white.opacity(hasEvents ? 0.5 : 0))
                    .frame(width: 4, height: 4)
            }
            .frame(width: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.9))
    }
}

private struct EventRow: View {
    @EnvironmentObject var model: IslandModel
    @EnvironmentObject var calendar: CalendarStore
    let event: CalEvent
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Capsule()
                .fill(event.color)
                .frame(width: 4, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1)
                Text([timeText, event.location ?? event.calendar].joined(separator: "  ·  "))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if event.isHappening() {
                Text("Now")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 7)
                    .frame(height: 18)
                    .background(Capsule().fill(Color(red: 0.2, green: 0.85, blue: 0.4)))
            }
            if let url = event.joinURL {
                IconButton(symbol: "video.fill", size: 12, tint: .black, background: Color(red: 0.2, green: 0.85, blue: 0.4), diameter: 28) {
                    NSWorkspace.shared.open(url)
                }
                .help("Join")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(hovering ? 0.07 : 0)))
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
        .onTapGesture { calendar.open(event) }
    }

    private var timeText: String {
        if event.isAllDay { return "All day" }
        let cal = Calendar.current
        func fmt(_ d: Date) -> String {
            let c = cal.dateComponents([.hour, .minute], from: d)
            let t = IslandFormat.time(hour: c.hour ?? 0, minute: c.minute ?? 0, use24Hour: model.p.use24Hour)
            return t.suffix.isEmpty ? t.time : "\(t.time) \(t.suffix)"
        }
        return "\(fmt(event.start)) – \(fmt(event.end))"
    }
}

private struct ConnectCalendar: View {
    @EnvironmentObject var calendar: CalendarStore

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: "calendar.badge.plus")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(todayRed)
            Text("Connect Your Calendars")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            Text("Shows Apple Calendar events, including Google, iCloud and Exchange accounts.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.42))
                .multilineTextAlignment(.center)
            HStack(spacing: 8) {
                CapsuleButton(title: calendar.access == .denied ? "Open Privacy Settings" : "Allow Access", tint: todayRed, filled: true) {
                    calendar.requestAccess()
                }
                CapsuleButton(title: "Add Google Account", symbol: "plus", tint: .white) {
                    CalendarStore.openInternetAccounts()
                }
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
