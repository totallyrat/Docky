import SwiftUI

/// Volume, brightness, Focus, device and charging indicators, shown in the compact island.
struct HUDView: View {
    @EnvironmentObject var model: IslandModel
    @State private var dragStart: Double?

    var body: some View {
        if let e = model.hud {
            let H = model.metrics.band
            levelDrag(enabled: e.level != nil, content: CompactWings {
                icon(e, size: H * 0.42)
                    .frame(width: H * 0.72)
            } center: {
                if let level = e.level {
                    LevelSlider(level: level)
                } else {
                    Text(e.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } trailing: {
                if let level = e.level {
                    Text("\(Int((level * 100).rounded()))")
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.75))
                        .contentTransition(.numericText(value: level))
                        .animation(.snappy(duration: 0.2), value: level)
                        .frame(width: 26, alignment: .trailing)
                } else {
                    Text(e.detail)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(color(e.tint))
                        .lineLimit(1)
                        .fixedSize()
                        .contentTransition(.opacity)
                }
            })
        }
    }

    /// Click-dragging anywhere on a volume/brightness indicator nudges the level:
    /// up or right to raise it, down or left to lower it.
    @ViewBuilder
    private func levelDrag<V: View>(enabled: Bool, content: V) -> some View {
        if enabled {
            content
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { g in
                            if dragStart == nil {
                                dragStart = model.hud?.level ?? 0
                                model.setAdjustingLevel(true)
                            }
                            let delta = Double(g.translation.width - g.translation.height) / 160
                            model.setHUDLevel((dragStart ?? 0) + delta)
                        }
                        .onEnded { _ in
                            dragStart = nil
                            model.setAdjustingLevel(false)
                        }
                )
        } else {
            content
        }
    }

    @ViewBuilder
    private func icon(_ e: HUDEvent, size: CGFloat) -> some View {
        let base = Image(systemName: e.symbol, variableValue: e.kind == .volume ? e.level : nil)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(e.kind == .volume || e.kind == .brightness ? Color.white : color(e.tint))
            .contentTransition(.symbolEffect(.replace))
        if e.level == nil {
            base.symbolEffect(.bounce, value: e.token)
        } else {
            base
        }
    }

    private func color(_ tint: HUDEvent.Tint) -> Color {
        switch tint {
        case .white: return .white.opacity(0.7)
        case .green: return Color(red: 0.2, green: 0.85, blue: 0.4)
        case .purple: return Color(red: 0.62, green: 0.5, blue: 1.0)
        case .blue: return Color(red: 0.35, green: 0.65, blue: 1.0)
        case .orange: return .orange
        case .red: return .red
        }
    }
}

struct LevelBar: View {
    let level: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.18))
                Capsule()
                    .fill(Color.white)
                    .frame(width: max(6, geo.size.width * min(1, max(0, level))))
                    .opacity(level <= 0.001 ? 0 : 1)
            }
            .animation(.interactiveSpring(response: 0.18, dampingFraction: 0.9), value: level)
        }
    }
}

/// The indicator's bar as a real slider: click anywhere on it to jump there, drag to slide.
/// It thickens under the pointer, like the scrubber in Now Playing.
struct LevelSlider: View {
    @EnvironmentObject var model: IslandModel
    let level: Double

    var body: some View {
        GeometryReader { geo in
            LevelBar(level: level)
                .frame(height: model.isHovering ? 9 : 6)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            model.setAdjustingLevel(true)
                            model.setHUDLevel(Double(g.location.x / max(1, geo.size.width)))
                        }
                        .onEnded { _ in model.setAdjustingLevel(false) }
                )
                .animation(.spring(response: 0.28, dampingFraction: 0.8), value: model.isHovering)
        }
    }
}
