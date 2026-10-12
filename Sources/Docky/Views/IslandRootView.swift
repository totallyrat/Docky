import AppKit
import SwiftUI

struct IslandRootView: View {
    @EnvironmentObject var model: IslandModel

    var body: some View {
        let layout = model.layout
        ZStack(alignment: .top) {
            Color.clear
            IslandBody(layout: layout)
                .overlay(alignment: .topTrailing) {
                    if layout.showsBubble {
                        TimerBubble(size: layout.bubbleSize)
                            .offset(x: layout.bubbleSize + model.metrics.bubbleGap)
                            .transition(
                                .asymmetric(
                                    insertion: .offset(x: -layout.bubbleSize).combined(with: .scale(scale: 0.3, anchor: .leading)).combined(with: .opacity),
                                    removal: .offset(x: -layout.bubbleSize).combined(with: .scale(scale: 0.3, anchor: .leading)).combined(with: .opacity)
                                )
                            )
                    }
                }
                .padding(.top, model.metrics.topOffset)
        }
        .frame(width: model.metrics.windowSize.width, height: model.metrics.windowSize.height, alignment: .top)
        .animation(model.spring, value: layout)
        .environment(\.colorScheme, .dark)
    }
}

struct IslandBody: View {
    @EnvironmentObject var model: IslandModel
    let layout: IslandLayout

    var body: some View {
        let shape = IslandShape(bottomRadius: layout.bottomRadius, topRadius: layout.topRadius, flare: model.metrics.flare)
        ZStack(alignment: .top) {
            content
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .top)
        .clipShape(shape)
        .background(
            shape
                .fill(Color.black)
                .shadow(color: .black.opacity(layout.shadow), radius: 22, x: 0, y: 10)
        )
        .contentShape(shape)
        .onDrop(of: ClipboardStore.supportedTypes,
                isTargeted: Binding(get: { model.dropTargeted }, set: { model.setDropTargeted($0) })) { providers in
            model.clipboard.add(providers: providers)
        }
        .opacity(layout.presentation == .hidden ? 0 : 1)
        .scaleEffect(layout.presentation == .hidden ? 0.85 : 1, anchor: .top)
        .offset(y: model.introHidden ? -(layout.size.height + model.metrics.topOffset + 40) : 0)
        .onTapGesture { model.islandClicked() }
        .gesture(
            DragGesture(minimumDistance: 8)
                .onChanged { g in
                    model.compactDragChanged(translation: g.translation, startX: g.startLocation.x, width: layout.size.width)
                }
                .onEnded { g in
                    model.compactDragEnded(translation: g.translation, startX: g.startLocation.x, width: layout.size.width)
                },
            including: (layout.presentation.isCompact || layout.presentation == .breakTime) && !model.isLevelHUD ? .all : .subviews
        )
        .contextMenu {
            Button("Expand") { model.expand() }
            Button("New Timer") { model.expand(tab: .timers) }
            Button("New Reminder") { model.requestCompose(.reminders) }
            Button("Clipboard") { model.expand(tab: .clipboard) }
            if model.p.showCalendar { Button("Calendar") { model.expand(tab: .calendar) } }
            Divider()
            Button("Docky Settings…") { model.openSettings() }
            Button("Quit Docky") { NSApp.terminate(nil) }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch layout.presentation {
        case .hidden, .idle:
            Color.clear
        case .lock(let unlocked):
            LockCompactView(unlocked: unlocked)
                .transition(.island())
        case .music:
            CompactMusicView()
                .transition(.island())
        case .timer:
            CompactTimerView()
                .transition(.island())
        case .hud:
            HUDView()
                .transition(.island())
        case .notice:
            NoticeView()
                .transition(.island(anchor: .top))
        case .pomodoro:
            CompactPomodoroView()
                .transition(.island())
        case .onboarding(let step):
            IslandOnboardingView(step: step)
                .transition(.island(anchor: .top))
        case .onboardingDemo:
            OnboardingDemoView()
                .transition(.island())
        case .breakTime:
            BreakCardView()
                .transition(.island(anchor: .top))
        case .peek:
            PeekView()
                .transition(.island(anchor: .top))
        case .expanded:
            ExpandedView()
                .transition(.island(anchor: .top))
        case .alert:
            AlertContainerView()
                .transition(.island(anchor: .top))
        }
    }
}

// MARK: - Compact states

/// Lays out compact content into the two "wings" either side of the notch (notch style)
/// or across the whole pill (floating style).
struct CompactWings<Leading: View, Center: View, Trailing: View>: View {
    @EnvironmentObject var model: IslandModel
    @ViewBuilder var leading: Leading
    @ViewBuilder var center: Center
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            leading
            if model.metrics.hasNotch {
                Spacer(minLength: model.metrics.notchWidth)
            } else {
                center.frame(maxWidth: .infinity)
            }
            trailing
        }
        .padding(.horizontal, model.metrics.compactSideInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct CompactMusicView: View {
    @EnvironmentObject var model: IslandModel
    @EnvironmentObject var nowPlaying: NowPlayingService

    var body: some View {
        let H = model.metrics.band
        let art = H - model.metrics.compactInset * 2
        let info = nowPlaying.info
        let tint = model.p.tintFromArtwork ? nowPlaying.accent : .white
        CompactWings {
            ArtworkView(image: nowPlaying.artwork, size: art, radius: art * 0.3)
        } center: {
            if model.p.compactShowsTitle, let info {
                MarqueeText(text: info.artist.isEmpty ? info.title : "\(info.title)  ·  \(info.artist)",
                            size: 12.5, weight: .medium,
                            color: .white.opacity(0.85))
                    .frame(height: H)
                    .id(info.trackKey)
                    .transition(.islandSoft)
            } else {
                Color.clear
            }
        } trailing: {
            Group {
                if model.p.showEqualizer {
                    EqualizerView(isPlaying: info?.isPlaying ?? false, color: tint)
                } else {
                    Image(systemName: info?.isPlaying == true ? "play.fill" : "pause.fill")
                        .font(.system(size: H * 0.38, weight: .bold))
                        .foregroundStyle(tint)
                }
            }
            .frame(width: art * 0.95, height: art * 0.66)
            .frame(width: art)
        }
    }
}

struct CompactTimerView: View {
    @EnvironmentObject var model: IslandModel
    @EnvironmentObject var clock: ClockStore

    var body: some View {
        let H = model.metrics.band
        let ring = H - model.metrics.compactInset * 2
        if let timer = clock.activeTimer {
            CompactWings {
                ZStack {
                    TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                        ProgressRing(progress: timer.progress(at: ctx.date), color: .orange, lineWidth: 2.2)
                    }
                    Image(systemName: timer.isRunning ? "timer" : "pause.fill")
                        .font(.system(size: ring * 0.46, weight: .bold))
                        .foregroundStyle(.orange)
                        .contentTransition(.symbolEffect(.replace))
                }
                .frame(width: ring, height: ring)
            } center: {
                Color.clear
            } trailing: {
                CountdownText(timer: timer, font: .system(size: H * 0.44, weight: .semibold), color: .orange)
                    .opacity(timer.isRunning ? 1 : 0.6)
            }
        }
    }
}

struct LockCompactView: View {
    @EnvironmentObject var model: IslandModel
    let unlocked: Bool

    var body: some View {
        let H = model.metrics.band
        let icon = Image(systemName: unlocked ? "lock.open.fill" : "lock.fill")
            .font(.system(size: H * 0.42, weight: .semibold))
            .foregroundStyle(.white)
            .contentTransition(.symbolEffect(.replace.offUp))
            .symbolEffect(.bounce, value: unlocked)
            .frame(width: H, height: H)

        if model.metrics.hasNotch {
            HStack { icon; Spacer() }
                .padding(.horizontal, model.metrics.compactSideInset - 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            icon.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The detached circle that carries a running timer while music owns the island.
struct TimerBubble: View {
    @EnvironmentObject var model: IslandModel
    @EnvironmentObject var clock: ClockStore
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(Color.black)
            if let session = clock.pomodoro {
                let tint = PomodoroColors.color(for: session.phase)
                TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                    ProgressRing(progress: session.progress(at: ctx.date), color: tint, lineWidth: 2)
                        .padding(size * 0.2)
                }
                Image(systemName: PomodoroColors.symbol(for: session.phase))
                    .font(.system(size: size * 0.24, weight: .bold))
                    .foregroundStyle(tint)
            } else if let timer = clock.activeTimer {
                TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                    ProgressRing(progress: timer.progress(at: ctx.date), color: .orange, lineWidth: 2)
                        .padding(size * 0.2)
                }
                Image(systemName: "timer")
                    .font(.system(size: size * 0.26, weight: .bold))
                    .foregroundStyle(.orange)
            }
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .onTapGesture { model.expand(tab: .timers) }
    }
}

/// Brief, wider look at a newly started track.
struct PeekView: View {
    @EnvironmentObject var model: IslandModel
    @EnvironmentObject var nowPlaying: NowPlayingService

    var body: some View {
        let tint = model.p.tintFromArtwork ? nowPlaying.accent : .white
        HStack(spacing: 12) {
            ArtworkView(image: nowPlaying.artwork, size: 44, radius: 11)
            VStack(alignment: .leading, spacing: 1) {
                MarqueeText(text: nowPlaying.info?.title ?? "", size: 14, weight: .semibold, alignment: .leading)
                    .frame(height: 18)
                Text(nowPlaying.info?.artist ?? "")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            EqualizerView(isPlaying: nowPlaying.info?.isPlaying ?? false, color: tint, bars: 5)
                .frame(width: 26, height: 18)
        }
        .padding(.horizontal, 20)
        .padding(.top, model.metrics.hasNotch ? model.metrics.band : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
