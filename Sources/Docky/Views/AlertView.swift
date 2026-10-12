import SwiftUI

struct AlertContainerView: View {
    @EnvironmentObject var model: IslandModel
    @EnvironmentObject var clock: ClockStore

    var body: some View {
        ZStack {
            if let alert = clock.alerts.first {
                AlertContent(alert: alert)
                    .id(alert.id)
                    .transition(.island())
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, model.metrics.hasNotch ? model.metrics.band : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            if clock.alerts.count > 1 {
                Text("+\(clock.alerts.count - 1)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 6)
                    .frame(height: 16)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
                    .padding(.top, (model.metrics.hasNotch ? model.metrics.band : 0) + 10)
                    .padding(.trailing, 22)
            }
        }
    }
}

struct AlertContent: View {
    @EnvironmentObject var model: IslandModel
    @EnvironmentObject var clock: ClockStore
    let alert: IslandAlert

    var body: some View {
        HStack(spacing: 14) {
            RingingIcon(symbol: symbol, tint: tint, ringing: ringing)
            VStack(alignment: .leading, spacing: 1) {
                Text(caption)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                Text(headline)
                    .font(.system(size: headlineSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 8)
            actions
        }
    }

    private var ringing: Bool {
        switch alert {
        case .reminder, .breakOver: return false
        default: return true
        }
    }

    private var symbol: String {
        switch alert {
        case .alarm: return "alarm.fill"
        case .timerDone: return "timer"
        case .reminder: return "bell.fill"
        case .breakOver: return "brain.head.profile"
        }
    }

    private var tint: Color {
        switch alert {
        case .alarm, .timerDone: return .orange
        case .reminder: return Color(red: 1.0, green: 0.78, blue: 0.2)
        case .breakOver: return PomodoroColors.focus
        }
    }

    private var caption: String {
        switch alert {
        case .alarm(let a, _): return a.label.isEmpty ? "Alarm" : a.label
        case .timerDone(let t): return t.label.isEmpty ? "Timer · \(IslandFormat.durationTitle(t.duration))" : t.label
        case .reminder: return "Reminder"
        case .breakOver(let round): return "Pomodoro · \(round) done"
        }
    }

    private var headline: String {
        switch alert {
        case .alarm(_, let date):
            let c = Calendar.current.dateComponents([.hour, .minute], from: date)
            let t = IslandFormat.time(hour: c.hour ?? 0, minute: c.minute ?? 0, use24Hour: model.p.use24Hour)
            return t.suffix.isEmpty ? t.time : "\(t.time) \(t.suffix)"
        case .timerDone: return "Done"
        case .reminder(let r): return r.title
        case .breakOver: return "Break's over"
        }
    }

    private var headlineSize: CGFloat {
        switch alert {
        case .reminder, .breakOver: return 18
        default: return 26
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 8) {
            switch alert {
            case .alarm:
                CapsuleButton(title: "Snooze", tint: .orange) { clock.snooze(alert) }
                IconButton(symbol: "xmark", size: 14, weight: .bold, tint: .white, background: .white.opacity(0.16), diameter: 38) {
                    clock.dismissAlert(alert)
                }
                .help("Stop")
            case .timerDone:
                IconButton(symbol: "arrow.clockwise", size: 14, weight: .bold, tint: .orange, background: .orange.opacity(0.22), diameter: 38) {
                    clock.repeatTimer(alert)
                }
                .help("Repeat")
                IconButton(symbol: "xmark", size: 14, weight: .bold, tint: .white, background: .white.opacity(0.16), diameter: 38) {
                    clock.dismissAlert(alert)
                }
                .help("Stop")
            case .reminder(let r):
                CapsuleButton(title: "Later", tint: tint) { clock.snooze(alert) }
                IconButton(symbol: "checkmark", size: 14, weight: .bold, tint: .black, background: tint, diameter: 38) {
                    clock.completeReminder(r.id)
                }
                .help("Mark as Done")
            case .breakOver:
                CapsuleButton(title: "Start Focus", symbol: "play.fill", tint: PomodoroColors.focus, filled: true) {
                    clock.startPomodoro()
                }
                IconButton(symbol: "xmark", size: 14, weight: .bold, tint: .white, background: .white.opacity(0.16), diameter: 38) {
                    clock.stopPomodoro()
                }
                .help("End Pomodoro")
            }
        }
    }
}

/// The alert glyph, wiggling like a ringing bell while the alert sounds.
struct RingingIcon: View {
    let symbol: String
    let tint: Color
    let ringing: Bool
    @State private var phase = false

    var body: some View {
        ZStack {
            Circle().fill(tint.opacity(0.2))
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(tint)
                .rotationEffect(.degrees(ringing ? (phase ? 14 : -14) : 0), anchor: .top)
        }
        .frame(width: 46, height: 46)
        .onAppear {
            guard ringing else { return }
            withAnimation(.easeInOut(duration: 0.11).repeatForever(autoreverses: true)) { phase = true }
        }
    }
}

/// A request card ("Docky needs Accessibility access…") with one action and a dismiss button.
struct NoticeView: View {
    @EnvironmentObject var model: IslandModel

    var body: some View {
        if let notice = model.notice {
            let tint = Color(red: 0.32, green: 0.6, blue: 1.0)
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(tint.opacity(0.2))
                    Image(systemName: notice.symbol)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(tint)
                }
                .frame(width: 46, height: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text(notice.title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(notice.message)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                CapsuleButton(title: notice.actionTitle, tint: tint, filled: true) { model.resolveNotice(acted: true) }
                IconButton(symbol: "xmark", size: 12, weight: .bold, tint: .white.opacity(0.8), background: .white.opacity(0.14), diameter: 30) {
                    model.resolveNotice(acted: false)
                }
                .help("Not Now")
            }
            .padding(.horizontal, 22)
            .padding(.top, model.metrics.hasNotch ? model.metrics.band : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
