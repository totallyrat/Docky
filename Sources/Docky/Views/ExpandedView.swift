import AppKit
import SwiftUI

struct ExpandedView: View {
    @EnvironmentObject var model: IslandModel

    var body: some View {
        VStack(spacing: 0) {
            ExpandedHeader()
                .frame(height: model.headerRowHeight)
                .padding(.top, model.expandedTopInset)
                .padding(.bottom, 14)
            ZStack(alignment: .top) {
                switch model.tab {
                case .nowPlaying:
                    NowPlayingTab().transition(.island(anchor: .top))
                case .timers:
                    TimersTab().transition(.island(anchor: .top))
                case .reminders:
                    RemindersTab().transition(.island(anchor: .top))
                case .clipboard:
                    ClipboardTab().transition(.island(anchor: .top))
                case .calendar:
                    CalendarTab().transition(.island(anchor: .top))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, model.expandedSideInset)
        .padding(.bottom, model.expandedBottomInset)
        .frame(width: model.layout.size.width, height: model.layout.size.height, alignment: .top)
    }
}

struct ExpandedHeader: View {
    @EnvironmentObject var model: IslandModel
    @EnvironmentObject var clock: ClockStore

    var body: some View {
        HStack(spacing: 8) {
            TabSwitcher(selection: Binding(get: { model.tab }, set: { t in model.tab = t }),
                        iconsOnly: true)
            Spacer(minLength: 0)
            if !model.metrics.hasNotch, let next = clock.nextAlarm {
                let t = IslandFormat.time(hour: Calendar.current.component(.hour, from: next.date),
                                          minute: Calendar.current.component(.minute, from: next.date),
                                          use24Hour: model.p.use24Hour)
                HStack(spacing: 4) {
                    Image(systemName: "alarm.fill").font(.system(size: 10, weight: .bold))
                    Text("\(t.time)\(t.suffix.isEmpty ? "" : " " + t.suffix)").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                }
                .foregroundStyle(.white.opacity(0.45))
                .transition(.opacity)
            }
            IconButton(symbol: "gearshape.fill", size: 12, tint: .white.opacity(0.6)) {
                model.openSettings()
            }
        }
        .padding(.trailing, -6)
    }
}

struct TabSwitcher: View {
    @EnvironmentObject var model: IslandModel
    @Binding var selection: IslandTab
    var iconsOnly: Bool

    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(model.visibleTabs) { tab in
                let selected = tab == selection
                Button {
                    withAnimation(model.spring) { selection = tab }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 11.5, weight: .semibold))
                        if selected && !iconsOnly {
                            Text(tab.title)
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                                .fixedSize()
                                .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .leading)))
                        }
                    }
                    .foregroundStyle(selected ? Color.white : Color.white.opacity(0.45))
                    .padding(.horizontal, selected && !iconsOnly ? 12 : 9)
                    .frame(height: 27)
                    .background {
                        if selected {
                            Capsule()
                                .fill(Color.white.opacity(0.15))
                                .matchedGeometryEffect(id: "tab", in: namespace)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(PressableStyle(scale: 0.92))
                .help(tab.title)
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.05)))
    }
}

// MARK: - Now Playing

struct NowPlayingTab: View {
    @EnvironmentObject var model: IslandModel
    @EnvironmentObject var nowPlaying: NowPlayingService

    var body: some View {
        if let info = nowPlaying.info {
            playing(info)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "music.note")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.3))
                Text("Not Playing")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                Text("Play something in Music, Spotify, Podcasts or a browser.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, 10)
        }
    }

    private func playing(_ info: NowPlayingInfo) -> some View {
        let tint = model.p.tintFromArtwork ? nowPlaying.accent : .white
        return VStack(spacing: 12) {
            HStack(spacing: 14) {
                ArtworkView(image: nowPlaying.artwork, size: 62, radius: 14)
                    .overlay(alignment: .bottomTrailing) {
                        if let icon = nowPlaying.appIcon {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 22, height: 22)
                                .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                                .offset(x: 6, y: 6)
                                .help(nowPlaying.appName)
                        }
                    }
                VStack(alignment: .leading, spacing: 3) {
                    MarqueeText(text: info.title, size: 15, weight: .semibold, alignment: .leading)
                        .frame(height: 19)
                    Text(info.artist.isEmpty ? nowPlaying.appName : info.artist)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                EqualizerView(isPlaying: info.isPlaying, color: tint, bars: 5)
                    .frame(width: 28, height: 20)
            }

            ScrubBar(info: info, tint: tint) { nowPlaying.seek(to: $0) }

            HStack(spacing: 34) {
                IconButton(symbol: "backward.fill", size: 19) { nowPlaying.previous() }
                IconButton(symbol: info.isPlaying ? "pause.fill" : "play.fill", size: 26, diameter: 48) {
                    nowPlaying.togglePlayPause()
                }
                IconButton(symbol: "forward.fill", size: 19) { nowPlaying.next() }
            }
        }
    }
}

/// Elapsed / remaining with a draggable bar that thickens under the cursor.
struct ScrubBar: View {
    let info: NowPlayingInfo
    let tint: Color
    let onSeek: (Double) -> Void

    @State private var hovering = false
    @State private var dragFraction: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            let duration = max(info.duration, 0.01)
            let position = dragFraction.map { $0 * duration } ?? info.position(at: ctx.date)
            let fraction = info.duration > 0 ? min(1, max(0, position / duration)) : 0
            HStack(spacing: 10) {
                Text(IslandFormat.clock(position))
                    .frame(width: 42, alignment: .trailing)
                GeometryReader { geo in
                    let active = hovering || dragFraction != nil
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.18))
                        Capsule()
                            .fill(active ? tint : Color.white.opacity(0.85))
                            .frame(width: max(active ? 7 : 5, geo.size.width * fraction))
                    }
                    .frame(height: active ? 8 : 5)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { g in
                                guard info.duration > 0 else { return }
                                dragFraction = min(1, max(0, g.location.x / geo.size.width))
                            }
                            .onEnded { _ in
                                if let f = dragFraction, info.duration > 0 { onSeek(f * info.duration) }
                                dragFraction = nil
                            }
                    )
                    .animation(.spring(response: 0.3, dampingFraction: 0.75), value: active)
                }
                .frame(height: 16)
                .onHover { h in hovering = h }
                Text(info.duration > 0 ? "-" + IslandFormat.clock(max(0, info.duration - position)) : "--:--")
                    .frame(width: 42, alignment: .leading)
            }
            .font(.system(size: 11, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.5))
        }
    }
}
