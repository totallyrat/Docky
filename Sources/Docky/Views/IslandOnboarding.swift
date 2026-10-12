import AppKit
import SwiftUI

private typealias K = DockyPrefs.Key
private let store = DockyPrefs.store

/// Setup walkthrough that happens inside the island. Choices are written straight to the
/// shared preferences, and the island demonstrates them on itself as you pick.
struct IslandOnboardingView: View {
    @EnvironmentObject var model: IslandModel
    let step: Int

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("DOCKY SETUP")
                    .font(.system(size: 10, weight: .bold))
                    .kerning(1.2)
                    .foregroundStyle(.white.opacity(0.35))
                Spacer()
                HStack(spacing: 5) {
                    ForEach(0..<IslandModel.onboardingStepCount, id: \.self) { i in
                        Capsule()
                            .fill(Color.white.opacity(i <= step ? 0.9 : 0.18))
                            .frame(width: i == step ? 18 : 6, height: 6)
                    }
                }
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: step)
            }
            .padding(.top, model.metrics.hasNotch ? model.metrics.band + 2 : 18)

            ZStack(alignment: .top) {
                page
                    .id(step)
                    .transition(.island(anchor: .top))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 12)

            controls
                .padding(.bottom, 20)
        }
        .padding(.horizontal, 26)
    }

    @ViewBuilder
    private var page: some View {
        switch step {
        case 0: WelcomeStep()
        case 1: ShapeStep()
        case 2: MotionStep()
        case 3: GestureStep()
        case 4: FeatureStep()
        case 5: PermissionStep()
        default: DoneStep()
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            if step == 0 {
                Button("Skip Setup") { model.finishOnboarding() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
            } else if step < IslandModel.onboardingStepCount - 1 {
                IslandSetupButton(title: "Back", prominent: false) { model.onboardingGo(-1) }
            }
            Spacer()
            IslandSetupButton(title: primaryTitle, prominent: true) { model.onboardingGo(1) }
        }
    }

    private var primaryTitle: String {
        switch step {
        case 0: return "Let's Go"
        case IslandModel.onboardingStepCount - 1: return "Done"
        default: return "Continue"
        }
    }
}

struct IslandSetupButton: View {
    let title: String
    let prominent: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(prominent ? Color.black : Color.white.opacity(0.85))
                .padding(.horizontal, prominent ? 20 : 15)
                .frame(height: 32)
                .background(Capsule().fill(prominent ? Color.white : Color.white.opacity(hovering ? 0.18 : 0.11)))
                .brightness(prominent && hovering ? -0.05 : 0)
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle(scale: 0.93))
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
    }
}

private struct StepTitle: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text(subtitle)
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SetupToggle: View {
    let symbol: String
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 18)
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(1)
            Spacer(minLength: 4)
            IslandToggle(isOn: $isOn)
                .scaleEffect(0.85)
        }
        .frame(height: 26)
    }
}

// MARK: Steps

private struct WelcomeStep: View {
    @State private var wave = false

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 84, height: 84)
                .shadow(color: Color(red: 0.6, green: 0.45, blue: 1).opacity(0.6), radius: 22)
                .rotationEffect(.degrees(wave ? -4 : 4))
                .animation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true), value: wave)
            StepTitle(title: "Hi, I'm Docky",
                      subtitle: "Your Mac's Dynamic Island. I'll show music, timers, reminders and more — right here. Let's set me up together; it takes a minute.")
        }
        .padding(.top, 6)
        .onAppear { wave = true }
    }
}

private struct ShapeStep: View {
    @EnvironmentObject var model: IslandModel
    @AppStorage(K.style, store: store) private var style: IslandStyle = .automatic
    @AppStorage(K.islandScale, store: store) private var scale = 1.0

    var body: some View {
        VStack(spacing: 14) {
            StepTitle(title: "Pick my shape", subtitle: "Choose how I sit at the top of your screen and how big I am. I'll show you each change.")
            VStack(spacing: 12) {
                HStack {
                    Text("Style").font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white.opacity(0.75))
                    Spacer()
                    SetupSegments(options: IslandStyle.allCases.map { ($0.title, $0.rawValue) }, selection: Binding(
                        get: { style.rawValue },
                        set: { style = IslandStyle(rawValue: $0) ?? .automatic; model.demonstrate(after: 0.5) }))
                }
                HStack(spacing: 10) {
                    Text("Size").font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white.opacity(0.75))
                    Spacer()
                    Image(systemName: "capsule.fill").font(.system(size: 8)).foregroundStyle(.white.opacity(0.4))
                    Slider(value: $scale, in: 0.8...1.3, step: 0.05) { editing in
                        if !editing { model.demonstrate() }
                    }
                    .frame(width: 220)
                    Image(systemName: "capsule.fill").font(.system(size: 14)).foregroundStyle(.white.opacity(0.4))
                }
                HStack {
                    Spacer()
                    Button {
                        model.demonstrate(after: 0)
                    } label: {
                        Label("Show Me", systemImage: "eye.fill")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.06)))
        }
    }
}

/// A compact segmented control that suits the island's dark surface.
private struct SetupSegments: View {
    let options: [(title: String, value: String)]
    @Binding var selection: String
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { selection = option.value }
                } label: {
                    Text(option.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(selected ? Color.black : Color.white.opacity(0.7))
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background {
                            if selected { Capsule().fill(Color.white).matchedGeometryEffect(id: "seg", in: ns) }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.1)))
    }
}

private struct MotionStep: View {
    @EnvironmentObject var model: IslandModel
    @AppStorage(K.animationFeel, store: store) private var feel: AnimationFeel = .smooth

    var body: some View {
        VStack(spacing: 14) {
            StepTitle(title: "How should I move?", subtitle: "Tap one and watch me — every morph uses this spring.")
            HStack(spacing: 10) {
                ForEach(AnimationFeel.allCases) { option in
                    let selected = feel == option
                    Button {
                        feel = option
                        // Give the new preference a moment to reach the island, then show it off.
                        model.demonstrate(after: 0.3)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Image(systemName: icon(option))
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(selected ? Color.black : Color.white.opacity(0.85))
                            Text(option.title)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(selected ? Color.black : .white)
                            Text(detail(option))
                                .font(.system(size: 11))
                                .foregroundStyle(selected ? Color.black.opacity(0.6) : Color.white.opacity(0.5))
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(13)
                        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(selected ? Color.white : Color.white.opacity(0.07)))
                        .scaleEffect(selected ? 1.03 : 1)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle(scale: 0.95))
                    .animation(.spring(response: 0.35, dampingFraction: 0.7), value: selected)
                }
            }
        }
    }

    private func icon(_ f: AnimationFeel) -> String {
        switch f {
        case .smooth: return "water.waves"
        case .snappy: return "bolt.fill"
        case .bouncy: return "circle.dotted.and.circle"
        }
    }

    private func detail(_ f: AnimationFeel) -> String {
        switch f {
        case .smooth: return "Calm and fluid, like iPhone."
        case .snappy: return "Quick and precise."
        case .bouncy: return "Playful, with a little overshoot."
        }
    }
}

private struct GestureStep: View {
    @AppStorage(K.swipeToExpand, store: store) private var swipe = true
    @AppStorage(K.clickToExpand, store: store) private var click = true
    @AppStorage(K.hoverToExpand, store: store) private var hover = false
    @AppStorage(K.haptics, store: store) private var haptics = true

    var body: some View {
        VStack(spacing: 14) {
            StepTitle(title: "Open me your way", subtitle: "Point at me and swipe down with two fingers, or just click. Swipe up to close me again.")
            HStack(alignment: .top, spacing: 18) {
                VStack(spacing: 6) {
                    SetupToggle(symbol: "hand.draw.fill", title: "Swipe down to open", isOn: $swipe)
                    SetupToggle(symbol: "cursorarrow.click", title: "Click to open", isOn: $click)
                }
                VStack(spacing: 6) {
                    SetupToggle(symbol: "cursorarrow.rays", title: "Open on hover", isOn: $hover)
                    SetupToggle(symbol: "waveform.path", title: "Haptic feedback", isOn: $haptics)
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.06)))
        }
    }
}

private struct FeatureStep: View {
    @AppStorage(K.nowPlayingEnabled, store: store) private var nowPlaying = true
    @AppStorage(K.musicOnly, store: store) private var musicOnly = false
    @AppStorage(K.compactShowsTitle, store: store) private var showTitle = true
    @AppStorage(K.showCalendar, store: store) private var calendar = true
    @AppStorage(K.hudVolume, store: store) private var volume = true
    @AppStorage(K.hudBrightness, store: store) private var brightness = true
    @AppStorage(K.hideInFullscreen, store: store) private var fullscreen = true
    @AppStorage(K.playIntro, store: store) private var intro = true

    var body: some View {
        VStack(spacing: 14) {
            StepTitle(title: "What should I show?", subtitle: "The most-used options. Everything else is in Docky Settings.")
            HStack(alignment: .top, spacing: 18) {
                VStack(spacing: 4) {
                    SetupToggle(symbol: "music.note", title: "Now Playing", isOn: $nowPlaying)
                    SetupToggle(symbol: "music.quarternote.3", title: "Only music", isOn: $musicOnly)
                    SetupToggle(symbol: "textformat", title: "Song title", isOn: $showTitle)
                    SetupToggle(symbol: "calendar", title: "Calendar tab", isOn: $calendar)
                }
                VStack(spacing: 4) {
                    SetupToggle(symbol: "speaker.wave.2.fill", title: "Volume", isOn: $volume)
                    SetupToggle(symbol: "sun.max.fill", title: "Brightness", isOn: $brightness)
                    SetupToggle(symbol: "rectangle.inset.filled", title: "Hide in fullscreen", isOn: $fullscreen)
                    SetupToggle(symbol: "sparkles", title: "Intro at launch", isOn: $intro)
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.06)))
        }
    }
}

private struct PermissionStep: View {
    @EnvironmentObject var model: IslandModel
    @AppStorage(K.launchAtLogin, store: store) private var launchAtLogin = false
    private let refresh = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 12) {
            StepTitle(title: "A few permissions", subtitle: "Each one unlocks something. You can change them later in System Settings.")
            VStack(spacing: 8) {
                row("hand.raised.fill", "Accessibility", "Volume & brightness only in me", key: "ax", command: .requestAccessibility)
                row("calendar", "Calendar", "Your events in the Calendar tab", key: "cal", command: .requestCalendar)
                row("moon.fill", "Focus", "When a Focus turns on or off", key: "focus", command: .requestFocus)
                SetupToggle(symbol: "power", title: "Open Docky when you log in", isOn: $launchAtLogin)
                    .padding(.horizontal, 2)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.06)))
        }
        .onAppear { send(.reportPermissions) }
        .onReceive(refresh) { _ in send(.reportPermissions) }
    }

    private func send(_ command: DockyIPC.Command) {
        DistributedNotificationCenter.default().postNotificationName(
            DockyIPC.command, object: command.rawValue, userInfo: nil, deliverImmediately: true)
    }

    private func row(_ symbol: String, _ title: String, _ detail: String, key: String, command: DockyIPC.Command) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.12)))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                Text(detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            if model.permissions[key] == 1 {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(red: 0.2, green: 0.85, blue: 0.4))
                    .transition(.scale.combined(with: .opacity))
            } else {
                IslandSetupButton(title: "Allow", prominent: true) { send(command) }
                    .scaleEffect(0.88)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: model.permissions[key])
    }
}

private struct DoneStep: View {
    @State private var appear = false

    private let tips: [(String, String)] = [
        ("hand.draw.fill", "Swipe down on me to open"),
        ("tray.and.arrow.down.fill", "Drag files onto me to keep them"),
        ("speaker.wave.2.fill", "Hover the volume and scroll to change it"),
        ("brain.head.profile", "Try Pomodoro in the Timers tab"),
    ]

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            ZStack {
                Circle().fill(Color(red: 0.2, green: 0.85, blue: 0.4).opacity(0.2)).frame(width: 70, height: 70)
                Image(systemName: "checkmark")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(Color(red: 0.2, green: 0.85, blue: 0.4))
                    .scaleEffect(appear ? 1 : 0.3)
            }
            VStack(alignment: .leading, spacing: 10) {
                StepTitle(title: "You're all set", subtitle: "A few things to try:")
                ForEach(Array(tips.enumerated()), id: \.offset) { i, tip in
                    HStack(spacing: 10) {
                        Image(systemName: tip.0)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.75))
                            .frame(width: 18)
                        Text(tip.1).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.85))
                    }
                    .opacity(appear ? 1 : 0)
                    .offset(x: appear ? 0 : 10)
                    .animation(.spring(response: 0.45, dampingFraction: 0.8).delay(0.1 + Double(i) * 0.06), value: appear)
                }
            }
        }
        .onAppear { withAnimation(.spring(response: 0.5, dampingFraction: 0.55)) { appear = true } }
    }
}

/// What the island looks like mid-demo: a compact Now Playing with a waveform.
struct OnboardingDemoView: View {
    @EnvironmentObject var model: IslandModel

    var body: some View {
        let H = model.metrics.band
        let art = H - model.metrics.compactInset * 2
        CompactWings {
            RoundedRectangle(cornerRadius: art * 0.3, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 1, green: 0.35, blue: 0.55), Color(red: 0.55, green: 0.3, blue: 1)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: art, height: art)
        } center: {
            if model.p.compactShowsTitle {
                Text("Looking good")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
            } else {
                Color.clear
            }
        } trailing: {
            EqualizerView(isPlaying: true, color: Color(red: 1, green: 0.45, blue: 0.65))
                .frame(width: art * 0.95, height: art * 0.66)
                .frame(width: art)
        }
    }
}
