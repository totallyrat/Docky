import SwiftUI

private let reminderTint = Color(red: 1.0, green: 0.78, blue: 0.2)
private let alarmTint = Color.orange

struct RemindersTab: View {
    enum Segment: String, CaseIterable { case reminders = "Reminders", alarms = "Alarms" }

    @EnvironmentObject var model: IslandModel
    @EnvironmentObject var clock: ClockStore
    @State private var segment: Segment = .reminders
    @State private var composing = false
    @Namespace private var namespace

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                HStack(spacing: 2) {
                    ForEach(Segment.allCases, id: \.self) { s in
                        let selected = s == segment
                        Button {
                            withAnimation(model.spring) { segment = s; composing = false }
                        } label: {
                            HStack(spacing: 5) {
                                Text(s.rawValue)
                                let count = s == .reminders ? clock.reminders.filter { !$0.isCompleted }.count : clock.alarms.filter(\.isEnabled).count
                                if count > 0 {
                                    Text("\(count)")
                                        .font(.system(size: 10, weight: .bold))
                                        .monospacedDigit()
                                        .padding(.horizontal, 5)
                                        .frame(height: 15)
                                        .background(Capsule().fill(Color.white.opacity(selected ? 0.2 : 0.1)))
                                }
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(selected ? Color.white : Color.white.opacity(0.45))
                            .padding(.horizontal, 11)
                            .frame(height: 26)
                            .background {
                                if selected {
                                    Capsule().fill(Color.white.opacity(0.13)).matchedGeometryEffect(id: "seg", in: namespace)
                                }
                            }
                            .contentShape(Capsule())
                        }
                        .buttonStyle(PressableStyle(scale: 0.94))
                    }
                }
                Spacer()
                if !composing {
                    IconButton(symbol: "plus", size: 13, tint: segment == .reminders ? reminderTint : alarmTint,
                               background: (segment == .reminders ? reminderTint : alarmTint).opacity(0.2), diameter: 28) {
                        withAnimation(model.spring) { composing = true }
                    }
                    .transition(.scale.combined(with: .opacity))
                    .help(segment == .reminders ? "New Reminder" : "New Alarm")
                }
            }

            ZStack(alignment: .top) {
                if composing {
                    Group {
                        if segment == .reminders {
                            ReminderComposer(onClose: close)
                        } else {
                            AlarmComposer(onClose: close)
                        }
                    }
                    .transition(.island(anchor: .top))
                } else if segment == .reminders {
                    ReminderList().transition(.island(anchor: .top))
                } else {
                    AlarmList().transition(.island(anchor: .top))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onAppear(perform: handleComposeRequest)
        .onChange(of: model.composeRequest?.token) { _, _ in handleComposeRequest() }
    }

    private func close() {
        model.isEditing = false
        withAnimation(model.spring) { composing = false }
    }

    private func handleComposeRequest() {
        guard let request = model.composeRequest, request.tab == .reminders else { return }
        model.composeRequest = nil
        segment = .reminders
        withAnimation(model.spring) { composing = true }
    }
}

// MARK: - Reminders

struct ReminderList: View {
    @EnvironmentObject var clock: ClockStore

    var body: some View {
        let open = clock.reminders.filter { !$0.isCompleted }
        let completed = clock.reminders.count - open.count
        if open.isEmpty {
            EmptyState(symbol: "checklist", title: "No Reminders", subtitle: completed > 0 ? "\(completed) completed" : "Tap + to add one.")
        } else {
            VStack(spacing: 4) {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 2) {
                        ForEach(open) { reminder in
                            ReminderRow(reminder: reminder)
                                .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .top)),
                                                        removal: .opacity.combined(with: .scale(scale: 0.95))))
                        }
                    }
                    .animation(.spring(response: 0.4, dampingFraction: 0.86), value: open.map(\.id))
                }
                if completed > 0 {
                    HStack {
                        Text("\(completed) completed")
                        Button("Clear") { withAnimation { clock.clearCompleted() } }
                            .buttonStyle(.plain)
                            .foregroundStyle(reminderTint.opacity(0.9))
                        Spacer()
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.35))
                    .padding(.leading, 6)
                }
            }
        }
    }
}

struct ReminderRow: View {
    @EnvironmentObject var model: IslandModel
    @EnvironmentObject var clock: ClockStore
    let reminder: IslandReminder

    @State private var checked = false
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Button(action: complete) {
                ZStack {
                    Circle().strokeBorder(checked ? reminderTint : Color.white.opacity(0.35), lineWidth: 1.6)
                    Circle().fill(reminderTint).padding(3.5).scaleEffect(checked ? 1 : 0.01).opacity(checked ? 1 : 0)
                }
                .frame(width: 20, height: 20)
                .contentShape(Circle())
            }
            .buttonStyle(PressableStyle(scale: 0.8))

            VStack(alignment: .leading, spacing: 1) {
                Text(reminder.title)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(.white.opacity(checked ? 0.4 : 0.95))
                    .strikethrough(checked, color: .white.opacity(0.4))
                    .lineLimit(1)
                if let due = reminder.dueDate {
                    let overdue = due < Date()
                    HStack(spacing: 3) {
                        Image(systemName: "bell.fill").font(.system(size: 8.5, weight: .bold))
                        Text(IslandFormat.relativeDue(due, use24Hour: model.p.use24Hour))
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(overdue ? Color.red.opacity(0.9) : Color.white.opacity(0.45))
                }
            }
            Spacer()
            if hovering {
                IconButton(symbol: "trash", size: 11, tint: .white.opacity(0.5)) {
                    withAnimation { clock.deleteReminder(reminder.id) }
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(hovering ? 0.06 : 0)))
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
    }

    private func complete() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { checked.toggle() }
        guard checked else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            guard checked else { return }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) { clock.completeReminder(reminder.id) }
        }
    }
}

struct ReminderComposer: View {
    enum Due: String, CaseIterable, Identifiable {
        case in15 = "In 15 min", inHour = "In 1 hour", tonight = "Tonight", tomorrow = "Tomorrow", custom = "Custom"
        var id: String { rawValue }
    }

    @EnvironmentObject var model: IslandModel
    @EnvironmentObject var clock: ClockStore
    var onClose: () -> Void

    @State private var title = ""
    @State private var due: Due?
    @State private var customTomorrow = false
    @State private var hour = 9
    @State private var minute = 0
    @State private var pm = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                TextField("New Reminder", text: $title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14.5, weight: .medium))
                    .focused($focused)
                    .onSubmit(save)
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white.opacity(0.09)))
                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(reminderTint.opacity(focused ? 0.6 : 0), lineWidth: 1))
                IconButton(symbol: "xmark", size: 12, tint: .white.opacity(0.7), background: .white.opacity(0.1), diameter: 32, action: onClose)
                    .help("Cancel")
                IconButton(symbol: "arrow.up", size: 14, weight: .bold, tint: .black, background: reminderTint, diameter: 32, action: save)
                    .opacity(title.trimmingCharacters(in: .whitespaces).isEmpty ? 0.4 : 1)
                    .help("Add Reminder")
            }
            HStack(spacing: 5) {
                ForEach(availableOptions) { option in
                    ChipButton(title: option.rawValue, tint: reminderTint, selected: due == option) {
                        withAnimation(model.spring) { due = due == option ? nil : option }
                    }
                }
            }
            if due == .custom {
                HStack(spacing: 10) {
                    VStack(spacing: 4) {
                        ChipButton(title: "Today", tint: reminderTint, selected: !customTomorrow) { customTomorrow = false }
                        ChipButton(title: "Tomorrow", tint: reminderTint, selected: customTomorrow) { customTomorrow = true }
                    }
                    Spacer(minLength: 0)
                    TimeDials(hour: $hour, minute: $minute, pm: $pm, use24Hour: model.p.use24Hour, tint: reminderTint, fontSize: 26)
                    Spacer(minLength: 0)
                }
                .transition(.island(anchor: .top))
            }
        }
        .onAppear {
            model.isEditing = true
            let now = Calendar.current.dateComponents([.hour, .minute], from: Date().addingTimeInterval(3600))
            let h = now.hour ?? 9
            hour = model.p.use24Hour ? h : (h % 12 == 0 ? 12 : h % 12)
            pm = h >= 12
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { focused = true }
        }
    }

    private var availableOptions: [Due] {
        let hour = Calendar.current.component(.hour, from: Date())
        return Due.allCases.filter { $0 != .tonight || hour < 19 }
    }

    private func dueDate() -> Date? {
        let cal = Calendar.current
        let now = Date()
        switch due {
        case nil: return nil
        case .in15: return now.addingTimeInterval(15 * 60)
        case .inHour: return now.addingTimeInterval(3600)
        case .tonight: return cal.date(bySettingHour: 20, minute: 0, second: 0, of: now)
        case .tomorrow:
            return cal.date(byAdding: .day, value: 1, to: now).flatMap { cal.date(bySettingHour: 9, minute: 0, second: 0, of: $0) }
        case .custom:
            let h24 = TimeDials.hour24(hour: hour, pm: pm, use24Hour: model.p.use24Hour)
            let base = customTomorrow ? cal.date(byAdding: .day, value: 1, to: now)! : now
            return cal.date(bySettingHour: h24, minute: minute, second: 0, of: base)
        }
    }

    private func save() {
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        clock.addReminder(title: title, due: dueDate())
        onClose()
    }
}

// MARK: - Alarms

struct AlarmList: View {
    @EnvironmentObject var clock: ClockStore

    var body: some View {
        if clock.alarms.isEmpty {
            EmptyState(symbol: "alarm", title: "No Alarms", subtitle: "Tap + to set one.")
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(clock.alarms) { alarm in
                        AlarmRow(alarm: alarm)
                            .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    }
                }
                .animation(.spring(response: 0.4, dampingFraction: 0.86), value: clock.alarms.map(\.id))
            }
        }
    }
}

struct AlarmRow: View {
    @EnvironmentObject var model: IslandModel
    @EnvironmentObject var clock: ClockStore
    let alarm: IslandAlarm
    @State private var hovering = false

    var body: some View {
        let t = IslandFormat.time(hour: alarm.hour, minute: alarm.minute, use24Hour: model.p.use24Hour)
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(t.time).font(.system(size: 30, weight: .light)).monospacedDigit()
                    if !t.suffix.isEmpty { Text(t.suffix).font(.system(size: 15, weight: .regular)) }
                }
                Text(alarm.label.isEmpty ? alarm.repeatSummary : "\(alarm.label), \(alarm.repeatSummary)")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .opacity(alarm.isEnabled || alarm.snoozeUntil != nil ? 1 : 0.45)
            Spacer()
            if let snooze = alarm.snoozeUntil {
                Text("Snoozed · \(IslandFormat.relativeDue(snooze, use24Hour: model.p.use24Hour).components(separatedBy: ", ").last ?? "")")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(alarmTint)
            }
            if hovering {
                IconButton(symbol: "trash", size: 11, tint: .white.opacity(0.5)) {
                    withAnimation { clock.deleteAlarm(alarm.id) }
                }
                .transition(.opacity)
            }
            IslandToggle(isOn: Binding(get: { alarm.isEnabled }, set: { clock.setAlarm(alarm.id, enabled: $0) }))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(hovering ? 0.06 : 0)))
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
    }
}

struct AlarmComposer: View {
    @EnvironmentObject var model: IslandModel
    @EnvironmentObject var clock: ClockStore
    var onClose: () -> Void

    @State private var hour = 7
    @State private var minute = 0
    @State private var pm = false
    @State private var label = ""
    @State private var days: Set<Int> = []
    @FocusState private var labelFocused: Bool

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                TimeDials(hour: $hour, minute: $minute, pm: $pm, use24Hour: model.p.use24Hour, tint: alarmTint, fontSize: 34)
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 8) {
                    TextField("Label", text: $label)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 10)
                        .frame(width: 150, height: 30)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.09)))
                        .focused($labelFocused)
                        .onSubmit(save)
                    HStack(spacing: 4) {
                        let symbols = Calendar.current.veryShortWeekdaySymbols
                        ForEach(1...7, id: \.self) { day in
                            let on = days.contains(day)
                            Button {
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                                    if on { days.remove(day) } else { days.insert(day) }
                                }
                            } label: {
                                Text(symbols[day - 1])
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(on ? Color.black : Color.white.opacity(0.7))
                                    .frame(width: 19, height: 19)
                                    .background(Circle().fill(on ? alarmTint : Color.white.opacity(0.1)))
                            }
                            .buttonStyle(PressableStyle(scale: 0.8))
                        }
                    }
                }
            }
            HStack {
                Button("Cancel", action: onClose)
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
                CapsuleButton(title: "Set Alarm", symbol: "alarm.fill", tint: alarmTint, filled: true, action: save)
            }
        }
        .onChange(of: labelFocused) { _, focused in
            // Typing a label needs the keyboard; editing state also keeps the island open.
            if focused { model.isEditing = true }
        }
    }

    private func save() {
        let h24 = TimeDials.hour24(hour: hour, pm: pm, use24Hour: model.p.use24Hour)
        clock.addAlarm(IslandAlarm(hour: h24, minute: minute, label: label, repeatDays: days.sorted()))
        onClose()
    }
}

// MARK: - Shared pieces

/// Hour : minute dials with an AM/PM switch when using a 12-hour clock.
struct TimeDials: View {
    @Binding var hour: Int
    @Binding var minute: Int
    @Binding var pm: Bool
    var use24Hour: Bool
    var tint: Color
    var fontSize: CGFloat

    static func hour24(hour: Int, pm: Bool, use24Hour: Bool) -> Int {
        if use24Hour { return hour }
        return (hour % 12) + (pm ? 12 : 0)
    }

    var body: some View {
        HStack(spacing: 2) {
            DialField(value: $hour, range: use24Hour ? 0...23 : 1...12, fontSize: fontSize, tint: tint,
                      format: use24Hour ? "%02d" : "%d")
            Text(":")
                .font(.system(size: fontSize * 0.85, weight: .semibold, design: .rounded))
                .foregroundStyle(tint.opacity(0.6))
                .padding(.bottom, 3)
            DialField(value: $minute, range: 0...59, fontSize: fontSize, tint: tint)
            if !use24Hour {
                VStack(spacing: 3) {
                    meridiem("AM", selected: !pm) { pm = false }
                    meridiem("PM", selected: pm) { pm = true }
                }
                .padding(.leading, 6)
            }
        }
    }

    private func meridiem(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { action() }
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(selected ? Color.black : Color.white.opacity(0.55))
                .frame(width: 34, height: 21)
                .background(Capsule().fill(selected ? tint : Color.white.opacity(0.1)))
        }
        .buttonStyle(PressableStyle(scale: 0.88))
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.white.opacity(0.28))
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
            Text(subtitle)
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 8)
    }
}
