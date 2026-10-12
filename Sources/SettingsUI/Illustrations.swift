import AppKit
import Combine
import SwiftUI

private typealias K = DockyPrefs.Key
private let store = DockyPrefs.store

private struct PreviewBlur: ViewModifier {
    var progress: Double
    func body(content: Content) -> some View {
        content.blur(radius: 6 * progress).scaleEffect(1 - 0.15 * progress).opacity(1 - progress)
    }
}

private extension AnyTransition {
    static var previewIsland: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: PreviewBlur(progress: 1), identity: PreviewBlur(progress: 0))
                .animation(.spring(response: 0.42, dampingFraction: 0.86).delay(0.06)),
            removal: .modifier(active: PreviewBlur(progress: 1), identity: PreviewBlur(progress: 0))
                .animation(.easeOut(duration: 0.14))
        )
    }
}

private var hardwareHasNotch: Bool {
    NSScreen.screens.contains { $0.safeAreaInsets.top > 0 }
}

/// A desktop in miniature: wallpaper, menu bar and an island cycling through its states
/// with the spring the user picked.
struct IslandPreview: View {
    @AppStorage(K.animationFeel, store: store) private var feel: AnimationFeel = .smooth
    @AppStorage(K.islandScale, store: store) private var scale = 1.0
    @AppStorage(K.style, store: store) private var style: IslandStyle = .automatic
    @AppStorage(K.compactShowsTitle, store: store) private var showsTitle = true

    @State private var stage = 0
    private let ticker = Timer.publish(every: 1.9, on: .main, in: .common).autoconnect()
    private let k: CGFloat = 0.72

    var body: some View {
        let notch = style == .notch || (style == .automatic && hardwareHasNotch)
        let s = CGFloat(scale)
        let H: CGFloat = notch ? 22 : FloatingGeometry.height * s * k
        let size: CGSize = {
            switch stage {
            case 0: return CGSize(width: notch ? 120 : FloatingGeometry.idleWidth * s * k, height: H)
            case 1: return CGSize(width: notch ? 200 : (showsTitle ? FloatingGeometry.musicWidth : FloatingGeometry.musicWidthNoTitle) * s * k, height: H)
            default: return CGSize(width: FloatingGeometry.expandedWidth * k, height: 210 * k)
            }
        }()
        let radius: CGFloat = stage == 2 ? 24 : (notch ? 8 : H / 2)

        ZStack(alignment: .top) {
            Wallpaper()
            MenuBarStrip(dimCenter: !notch)
            ZStack(alignment: .top) {
                UnevenRoundedRectangle(topLeadingRadius: notch ? 0 : radius, bottomLeadingRadius: radius,
                                       bottomTrailingRadius: radius, topTrailingRadius: notch ? 0 : radius,
                                       style: .continuous)
                    .fill(Color.black)
                    .shadow(color: .black.opacity(stage == 2 ? 0.45 : 0), radius: 14, y: 6)
                Group {
                    if stage == 1 {
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                                .fill(LinearGradient(colors: [.pink, .orange], startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: H * 0.68, height: H * 0.68)
                            if showsTitle && !notch {
                                Text("Midnight City · M83")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.85))
                                    .frame(maxWidth: .infinity)
                            } else {
                                Spacer()
                            }
                            MiniBars(color: .pink).frame(width: H * 0.6, height: H * 0.45)
                        }
                        .padding(.horizontal, 6)
                        .frame(width: size.width, height: size.height)
                        .transition(.previewIsland)
                    } else if stage == 2 {
                        ExpandedMini()
                            .frame(width: size.width, height: size.height)
                            .transition(.previewIsland)
                    }
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: notch ? 0 : radius, bottomLeadingRadius: radius,
                                              bottomTrailingRadius: radius, topTrailingRadius: notch ? 0 : radius,
                                              style: .continuous))
            .padding(.top, notch ? 0 : FloatingGeometry.topOffset * k)
        }
        .frame(height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(14)
        .animation(.spring(response: feel.response, dampingFraction: feel.damping), value: stage)
        .animation(.spring(response: feel.response, dampingFraction: feel.damping), value: scale)
        .onReceive(ticker) { _ in stage = (stage + 1) % 3 }
    }
}

private struct ExpandedMini: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 4) {
                Capsule().fill(Color.white.opacity(0.16)).frame(width: 62, height: 14)
                Circle().fill(Color.white.opacity(0.08)).frame(width: 14, height: 14)
                Circle().fill(Color.white.opacity(0.08)).frame(width: 14, height: 14)
            }
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(colors: [.pink, .orange], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Midnight City").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white)
                    Text("M83").font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
                MiniBars(color: .pink, bars: 5).frame(width: 18, height: 12)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.18))
                    Capsule().fill(Color.white.opacity(0.85)).frame(width: g.size.width * 0.42)
                }
            }
            .frame(height: 3.5)
            HStack(spacing: 26) {
                Image(systemName: "backward.fill").font(.system(size: 12))
                Image(systemName: "pause.fill").font(.system(size: 17))
                Image(systemName: "forward.fill").font(.system(size: 12))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct MiniBars: View {
    var color: Color
    var bars = 4

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
            GeometryReader { g in
                HStack(spacing: 1.5) {
                    ForEach(0..<bars, id: \.self) { i in
                        Capsule().fill(color).frame(width: 2, height: barHeight(i, ctx.date, g.size.height))
                    }
                }
                .frame(width: g.size.width, height: g.size.height)
            }
        }
    }

    private func barHeight(_ i: Int, _ date: Date, _ maxHeight: CGFloat) -> CGFloat {
        let t = date.timeIntervalSinceReferenceDate
        let fi = Double(i)
        let v = 0.5 + 0.5 * sin(t * (5 + fi * 1.4) + fi * 1.9)
        return max(2, maxHeight * CGFloat(0.25 + 0.75 * v))
    }
}

private struct Wallpaper: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.16, green: 0.18, blue: 0.36), Color(red: 0.42, green: 0.22, blue: 0.45)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(Color(red: 1, green: 0.55, blue: 0.4).opacity(0.55)).frame(width: 260).blur(radius: 60).offset(x: 180, y: 90)
            Circle().fill(Color(red: 0.3, green: 0.55, blue: 1).opacity(0.5)).frame(width: 240).blur(radius: 60).offset(x: -200, y: 60)
        }
    }
}

private struct MenuBarStrip: View {
    var dimCenter: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "apple.logo").font(.system(size: 10))
            Text("Finder").font(.system(size: 10, weight: .bold))
            Text("File").font(.system(size: 10))
            Text("Edit").font(.system(size: 10))
            Text("View").font(.system(size: 10))
            Spacer()
            Image(systemName: "wifi").font(.system(size: 9.5))
            Image(systemName: "battery.75percent").font(.system(size: 10))
            Text("Wed 9:41").font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, 12)
        .frame(height: 22)
        .background(Color.white.opacity(0.1))
    }
}

/// Two fingers sliding down a trackpad while the island opens.
struct GestureIllustration: View {
    @AppStorage(K.animationFeel, store: store) private var feel: AnimationFeel = .smooth
    @State private var phase = false
    private let ticker = Timer.publish(every: 1.6, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 40) {
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: phase ? 20 : 9, style: .continuous)
                    .fill(Color.black)
                    .frame(width: phase ? 200 : 96, height: phase ? 92 : 18)
                    .shadow(color: .black.opacity(phase ? 0.3 : 0), radius: 10, y: 5)
            }
            .frame(width: 210, height: 110, alignment: .top)

            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.07))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
                .frame(width: 150, height: 100)
                .overlay {
                    HStack(spacing: 14) {
                        Circle().fill(Color.accentColor.opacity(0.75)).frame(width: 16, height: 16)
                        Circle().fill(Color.accentColor.opacity(0.75)).frame(width: 16, height: 16)
                    }
                    .offset(y: phase ? 22 : -22)
                    .opacity(phase ? 0.25 : 1)
                }
        }
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
        .animation(.spring(response: feel.response, dampingFraction: feel.damping), value: phase)
        .onReceive(ticker) { _ in phase.toggle() }
    }
}

/// The island on a blurred lock screen, locking and unlocking.
struct LockIllustration: View {
    var enabled: Bool
    @State private var unlocked = false
    private let ticker = Timer.publish(every: 1.8, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack(alignment: .top) {
            Wallpaper().blur(radius: 18).overlay(Color.black.opacity(0.15))
            VStack(spacing: 2) {
                Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide))).font(.system(size: 13, weight: .semibold))
                Text(Date.now.formatted(date: .omitted, time: .shortened).replacingOccurrences(of: " AM", with: "").replacingOccurrences(of: " PM", with: ""))
                    .font(.system(size: 58, weight: .bold, design: .rounded))
            }
            .foregroundStyle(.white.opacity(0.92))
            .padding(.top, 52)

            Capsule()
                .fill(Color.black)
                .frame(width: FloatingGeometry.lockWidth * 0.72, height: FloatingGeometry.height * 0.72)
                .overlay {
                    Image(systemName: unlocked ? "lock.open.fill" : "lock.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .contentTransition(.symbolEffect(.replace.offUp))
                        .symbolEffect(.bounce, value: unlocked)
                }
                .padding(.top, 6)
                .opacity(enabled ? 1 : 0)
                .scaleEffect(enabled ? 1 : 0.8, anchor: .top)
        }
        .frame(height: 200)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(14)
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: enabled)
        .onReceive(ticker) { _ in withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { unlocked.toggle() } }
    }
}
