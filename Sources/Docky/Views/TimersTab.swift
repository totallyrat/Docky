import SwiftUI

struct TimersTab: View {
    @EnvironmentObject var model: IslandModel
    @EnvironmentObject var clock: ClockStore

    @Namespace private var modeNS

    var body: some View {
        VStack(spacing: 10) {
            modeBar
            ZStack(alignment: .top) {
                if model.timersMode == .pomodoro {
                    PomodoroPanel().transition(.island(anchor: .top))
                } else {
                    timers.transition(.island(anchor: .top))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private var modeBar: some View {
        HStack(spacing: 2) {
            ForEach([IslandModel.TimersMode.timers, .pomodoro], id: \.self) { mode in
                let selected = model.timersMode == mode
                Button {
                    withAnimation(model.spring) { model.timersMode = mode }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: mode == .timers ? "timer" : "brain.head.profile")
                            .font(.system(size: 11, weight: .semibold))
                        Text(mode == .timers ? "Timers" : "Pomodoro")
                            .font(.system(size: 12, weight: .semibold))
                        if mode == .pomodoro, clock.pomodoro != nil {
                            Circle().fill(PomodoroColors.focus).frame(width: 5, height: 5)
                        }
                    }
                    .foregroundStyle(selected ? Color.white : Color.white.opacity(0.45))
                    .padding(.horizontal, 11)
                    .frame(height: 26)
                    .background {
                        if selected {
                            Capsule().fill(Color.white.opacity(0.13)).matchedGeometryEffect(id: "timersMode", in: modeNS)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(PressableStyle(scale: 0.94))
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var timers: some View {
        let composing = clock.timers.isEmpty || model.timerComposerOpen
        ZStack(alignment: .top) {
            if composing {
                TimerComposer(onDone: { model.timerComposerOpen = false }, canCancel: !clock.timers.isEmpty)
                    .transition(.island(anchor: .top))
            } else {
                TimerList(onNew: { model.timerComposerOpen = true })
                    .transition(.island(anchor: .top))
            }
        }
    }
}

private let presets: [(String, TimeInterval)] = [
    ("1 min", 60), ("5 min", 300), ("10 min", 600), ("15 min", 900), ("30 min", 1800), ("1 hr", 3600),
]

struct TimerComposer: View {
    @EnvironmentObject var clock: ClockStore
    var onDone: () -> Void
    var canCancel: Bool

    @State private var hours = 0
    @State private var minutes = 5
    @State private var seconds = 0

    private var total: TimeInterval { TimeInterval(hours * 3600 + minutes * 60 + seconds) }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 0) {
                HStack(spacing: 2) {
                    DialField(value: $hours, range: 0...23, unit: "h", fontSize: 38, tint: .orange)
                    colon
                    DialField(value: $minutes, range: 0...59, unit: "m", fontSize: 38, tint: .orange)
                    colon
                    DialField(value: $seconds, range: 0...59, unit: "s", fontSize: 38, tint: .orange)
                }
                Spacer(minLength: 8)
                VStack(spacing: 8) {
                    Button {
                        clock.draftDuration = total
                        clock.startTimer(duration: total)
                        onDone()
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(Color.black)
                            .frame(width: 52, height: 52)
                            .background(Circle().fill(Color.orange))
                    }
                    .buttonStyle(PressableStyle())
                    .disabled(total < 1)
                    .opacity(total < 1 ? 0.4 : 1)
                    .help("Start")

                    if canCancel {
                        Button("Cancel", action: onDone)
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
            HStack(spacing: 6) {
                ForEach(presets, id: \.1) { preset in
                    ChipButton(title: preset.0, tint: .orange) {
                        clock.startTimer(duration: preset.1)
                        onDone()
                    }
                }
            }
        }
        .padding(.top, 2)
        .onAppear {
            let d = Int(clock.draftDuration)
            hours = d / 3600
            minutes = (d % 3600) / 60
            seconds = d % 60
        }
    }

    private var colon: some View {
        Text(":")
            .font(.system(size: 32, weight: .semibold, design: .rounded))
            .foregroundStyle(.orange.opacity(0.6))
            .padding(.bottom, 4)
    }
}

struct TimerList: View {
    @EnvironmentObject var clock: ClockStore
    var onNew: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 6) {
                    ForEach(clock.timers) { timer in
                        TimerRow(timer: timer)
                            .transition(.asymmetric(insertion: .scale(scale: 0.9).combined(with: .opacity),
                                                    removal: .scale(scale: 0.9).combined(with: .opacity)))
                    }
                }
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: clock.timers.map(\.id))
            }
            .frame(height: CGFloat(min(clock.timers.count, 3)) * TimerRow.pitch - 6)

            HStack(spacing: 6) {
                ForEach(presets.prefix(3), id: \.1) { preset in
                    ChipButton(title: preset.0, tint: .orange) { clock.startTimer(duration: preset.1) }
                }
                Spacer()
                CapsuleButton(title: "New Timer", symbol: "plus", tint: .orange, action: onNew)
            }
        }
    }
}

struct TimerRow: View {
    static let pitch: CGFloat = 58
    @EnvironmentObject var clock: ClockStore
    let timer: IslandTimer
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !timer.isRunning)) { ctx in
                ProgressRing(progress: timer.progress(at: ctx.date), color: .orange, lineWidth: 3.5)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 0) {
                CountdownText(timer: timer, font: .system(size: 22, weight: .semibold), color: timer.isRunning ? .orange : .orange.opacity(0.55))
                Text(timer.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
            }
            Spacer()
            IconButton(symbol: timer.isRunning ? "pause.fill" : "play.fill", size: 14, tint: .orange,
                       background: .orange.opacity(0.22), diameter: 36) {
                clock.toggleTimer(timer.id)
            }
            IconButton(symbol: "xmark", size: 13, tint: .white.opacity(0.8),
                       background: .white.opacity(0.12), diameter: 36) {
                clock.cancelTimer(timer.id)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: TimerRow.pitch - 6)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(hovering ? 0.07 : 0.045)))
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
    }
}
