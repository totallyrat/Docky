import SwiftUI

enum PomodoroColors {
    static let focus = Color(red: 1.0, green: 0.42, blue: 0.33)
    static let rest = Color(red: 0.36, green: 0.86, blue: 0.62)

    static func color(for phase: PomodoroSession.Phase) -> Color { phase == .focus ? focus : rest }
    static func symbol(for phase: PomodoroSession.Phase) -> String { phase == .focus ? "brain.head.profile" : "leaf.fill" }
}

/// Live "4:59" for a Pomodoro phase, with rolling digits.
struct PomodoroCountdown: View {
    let session: PomodoroSession
    var size: CGFloat
    var color: Color

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
            let remaining = session.remaining(at: ctx.date)
            Text(IslandFormat.clock(remaining, roundUp: true))
                .font(.system(size: size, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(color)
                .contentTransition(.numericText(countsDown: true))
                .animation(.snappy(duration: 0.3), value: Int(remaining.rounded(.up)))
        }
    }
}

/// The compact island while a Pomodoro runs: phase ring on the left, time on the right.
struct CompactPomodoroView: View {
    @EnvironmentObject var model: IslandModel
    @EnvironmentObject var clock: ClockStore

    var body: some View {
        let H = model.metrics.band
        let ring = H - model.metrics.compactInset * 2
        if let s = clock.pomodoro {
            let tint = PomodoroColors.color(for: s.phase)
            CompactWings {
                ZStack {
                    TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                        ProgressRing(progress: s.progress(at: ctx.date), color: tint, lineWidth: 2.2)
                    }
                    Image(systemName: s.isRunning ? PomodoroColors.symbol(for: s.phase) : "pause.fill")
                        .font(.system(size: ring * 0.42, weight: .bold))
                        .foregroundStyle(tint)
                        .contentTransition(.symbolEffect(.replace))
                }
                .frame(width: ring, height: ring)
            } center: {
                Color.clear
            } trailing: {
                PomodoroCountdown(session: s, size: H * 0.44, color: tint)
                    .opacity(s.isRunning ? 1 : 0.6)
            }
        }
    }
}

/// "Time for a break" — shown with the warm glow until you swipe up or the break ends.
struct BreakCardView: View {
    @EnvironmentObject var model: IslandModel
    @EnvironmentObject var clock: ClockStore
    @State private var breathe = false

    var body: some View {
        let tint = PomodoroColors.rest
        let warm = Color(red: 1.0, green: 0.7, blue: 0.45)
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(warm.opacity(0.22))
                    .scaleEffect(breathe ? 1.08 : 0.94)
                Image(systemName: "cup.and.saucer.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(warm)
            }
            .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text("Time for a break")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                if let s = clock.pomodoro {
                    HStack(spacing: 4) {
                        Text(s.isLongBreak ? "Long break" : "Back to focus in")
                        PomodoroCountdown(session: s, size: 12, color: tint)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                }
            }
            Spacer(minLength: 6)
            CapsuleButton(title: "Skip", tint: tint) { clock.skipPomodoroPhase() }
                .help("End the break and start focusing")
            IconButton(symbol: "chevron.up", size: 13, weight: .bold, tint: .white.opacity(0.85), background: .white.opacity(0.14), diameter: 32) {
                model.dismissBreakMoment()
            }
            .help("Put away (or swipe up)")
        }
        .padding(.horizontal, 22)
        .padding(.top, model.metrics.hasNotch ? model.metrics.band : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) { breathe = true }
        }
    }
}

/// The Pomodoro side of the Timers tab: set it up, then watch the rounds go by.
struct PomodoroPanel: View {
    @EnvironmentObject var clock: ClockStore

    var body: some View {
        if let s = clock.pomodoro {
            running(s)
        } else {
            setup
        }
    }

    private var setup: some View {
        let config = Binding(get: { clock.pomodoroConfig }, set: { clock.pomodoroConfig = $0 })
        return VStack(spacing: 10) {
            HStack(alignment: .center, spacing: 6) {
                labeledDial("Focus", value: config.workMinutes, range: 1...180, tint: PomodoroColors.focus)
                labeledDial("Break", value: config.breakMinutes, range: 1...60, tint: PomodoroColors.rest)
                labeledDial("Long", value: config.longBreakMinutes, range: 1...90, tint: PomodoroColors.rest.opacity(0.85))
                labeledDial("Rounds", value: config.roundsBeforeLongBreak, range: 0...12, tint: .white.opacity(0.85), unit: nil)
                Spacer(minLength: 4)
                Button {
                    clock.startPomodoro()
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Color.black)
                        .frame(width: 52, height: 52)
                        .background(Circle().fill(PomodoroColors.focus))
                }
                .buttonStyle(PressableStyle())
                .help("Start focusing")
            }
            HStack(spacing: 6) {
                ChipButton(title: "Auto-start focus", tint: PomodoroColors.focus, selected: clock.pomodoroConfig.autoStartFocus) {
                    clock.pomodoroConfig.autoStartFocus.toggle()
                }
                ChipButton(title: "Break glow", tint: Color(red: 1.0, green: 0.7, blue: 0.45), selected: clock.pomodoroConfig.breakGlow) {
                    clock.pomodoroConfig.breakGlow.toggle()
                }
                Spacer()
                Text(summary)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    private var summary: String {
        let c = clock.pomodoroConfig
        return c.roundsBeforeLongBreak > 0 ? "Long break every \(c.roundsBeforeLongBreak)" : "No long breaks"
    }

    private func labeledDial(_ label: String, value: Binding<Int>, range: ClosedRange<Int>, tint: Color, unit: String? = "m") -> some View {
        VStack(spacing: 0) {
            DialField(value: value, range: range, unit: unit, fontSize: 26, tint: tint, format: "%d")
            Text(label.uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.4))
        }
    }

    private func running(_ s: PomodoroSession) -> some View {
        let tint = PomodoroColors.color(for: s.phase)
        let rounds = max(clock.pomodoroConfig.roundsBeforeLongBreak, 1)
        let done = s.completedRounds % rounds
        return HStack(spacing: 14) {
            ZStack {
                TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !s.isRunning)) { ctx in
                    ProgressRing(progress: s.progress(at: ctx.date), color: tint, lineWidth: 5)
                }
                Image(systemName: PomodoroColors.symbol(for: s.phase))
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 60, height: 60)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.phase == .focus ? "Focus" : (s.isLongBreak ? "Long break" : "Break"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                PomodoroCountdown(session: s, size: 28, color: .white)
                HStack(spacing: 4) {
                    ForEach(0..<min(rounds, 12), id: \.self) { i in
                        Circle()
                            .fill(i < done || (s.phase == .rest && i == done - 1) ? PomodoroColors.focus : Color.white.opacity(0.18))
                            .frame(width: 6, height: 6)
                    }
                }
            }
            Spacer()
            IconButton(symbol: s.isRunning ? "pause.fill" : "play.fill", size: 14, tint: tint, background: tint.opacity(0.22), diameter: 38) {
                clock.togglePomodoro()
            }
            .help(s.isRunning ? "Pause" : "Resume")
            IconButton(symbol: "forward.end.fill", size: 13, tint: .white.opacity(0.85), background: .white.opacity(0.12), diameter: 38) {
                clock.skipPomodoroPhase()
            }
            .help(s.phase == .focus ? "Start the break now" : "End the break")
            IconButton(symbol: "xmark", size: 13, tint: .white.opacity(0.8), background: .white.opacity(0.12), diameter: 38) {
                clock.stopPomodoro()
            }
            .help("Stop Pomodoro")
        }
    }
}
