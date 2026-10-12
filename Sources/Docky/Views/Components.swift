import AppKit
import SwiftUI

// MARK: - Island shape

/// Floating style: a continuous-corner capsule/rounded rect.
/// Notch style: flush with the top edge with small outward "flares" that melt into the bezel.
struct IslandShape: Shape {
    var bottomRadius: CGFloat
    var topRadius: CGFloat
    var flare: CGFloat

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(bottomRadius, AnimatablePair(topRadius, flare)) }
        set {
            bottomRadius = newValue.first
            topRadius = newValue.second.first
            flare = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let maxR = min(rect.width, rect.height) / 2
        let br = min(bottomRadius, maxR)
        let tr = flare > 0.01 ? 0 : min(topRadius, maxR)

        // Corner geometry: a true circular arc when the radius is half the height (a perfect
        // capsule), easing into an Apple-style continuous corner once there's room for it.
        // `d` is how far along each edge the curve starts; `a` keeps the corner's apparent
        // radius constant so the morph never pops.
        func corner(_ r: CGFloat) -> (d: CGFloat, a: CGFloat) {
            guard r > 0.01 else { return (0, 0) }
            let smoothing = min(1, max(0, (maxR - r) / (0.5 * r)))
            let d = min(maxR, r * (1 + 0.5 * smoothing))
            return (d, (4 * d - 2.343 * r) / 3)
        }
        let (bd, ba) = corner(br)
        let (td, ta) = corner(tr)
        let minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        var p = Path()

        if flare > 0.01 {
            let f = flare, c = flare * 0.4477
            p.move(to: CGPoint(x: minX - f, y: minY))
            p.addCurve(to: CGPoint(x: minX, y: minY + f),
                       control1: CGPoint(x: minX - c, y: minY), control2: CGPoint(x: minX, y: minY + f - c))
            p.addLine(to: CGPoint(x: minX, y: maxY - bd))
            p.addCurve(to: CGPoint(x: minX + bd, y: maxY),
                       control1: CGPoint(x: minX, y: maxY - bd + ba), control2: CGPoint(x: minX + bd - ba, y: maxY))
            p.addLine(to: CGPoint(x: maxX - bd, y: maxY))
            p.addCurve(to: CGPoint(x: maxX, y: maxY - bd),
                       control1: CGPoint(x: maxX - bd + ba, y: maxY), control2: CGPoint(x: maxX, y: maxY - bd + ba))
            p.addLine(to: CGPoint(x: maxX, y: minY + f))
            p.addCurve(to: CGPoint(x: maxX + f, y: minY),
                       control1: CGPoint(x: maxX, y: minY + f - c), control2: CGPoint(x: maxX + c, y: minY))
            p.closeSubpath()
            return p
        }

        p.move(to: CGPoint(x: minX + td, y: minY))
        p.addLine(to: CGPoint(x: maxX - td, y: minY))
        p.addCurve(to: CGPoint(x: maxX, y: minY + td),
                   control1: CGPoint(x: maxX - td + ta, y: minY), control2: CGPoint(x: maxX, y: minY + td - ta))
        p.addLine(to: CGPoint(x: maxX, y: maxY - bd))
        p.addCurve(to: CGPoint(x: maxX - bd, y: maxY),
                   control1: CGPoint(x: maxX, y: maxY - bd + ba), control2: CGPoint(x: maxX - bd + ba, y: maxY))
        p.addLine(to: CGPoint(x: minX + bd, y: maxY))
        p.addCurve(to: CGPoint(x: minX, y: maxY - bd),
                   control1: CGPoint(x: minX + bd - ba, y: maxY), control2: CGPoint(x: minX, y: maxY - bd + ba))
        p.addLine(to: CGPoint(x: minX, y: minY + td))
        p.addCurve(to: CGPoint(x: minX + td, y: minY),
                   control1: CGPoint(x: minX, y: minY + td - ta), control2: CGPoint(x: minX + td - ta, y: minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Transitions

/// The content swap Apple uses in the Dynamic Island: old content blurs and shrinks away
/// quickly, new content blooms in just after the shape starts moving.
struct BlurScale: ViewModifier {
    var progress: Double
    var anchor: UnitPoint = .center

    func body(content: Content) -> some View {
        content
            .blur(radius: 9 * progress)
            .scaleEffect(1 - 0.14 * progress, anchor: anchor)
            .opacity(1 - progress)
    }
}

extension AnyTransition {
    static func island(anchor: UnitPoint = .center) -> AnyTransition {
        .asymmetric(
            insertion: .modifier(active: BlurScale(progress: 1, anchor: anchor), identity: BlurScale(progress: 0, anchor: anchor))
                .animation(.spring(response: 0.36, dampingFraction: 0.9).delay(0.05)),
            removal: .modifier(active: BlurScale(progress: 1, anchor: anchor), identity: BlurScale(progress: 0, anchor: anchor))
                .animation(.easeOut(duration: 0.14))
        )
    }

    static var islandSoft: AnyTransition {
        .modifier(active: BlurScale(progress: 1), identity: BlurScale(progress: 0))
    }
}

// MARK: - Buttons

struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.86

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.62), value: configuration.isPressed)
    }
}

/// Round icon button with a hover halo, used for transport controls and row actions.
struct IconButton: View {
    let symbol: String
    var size: CGFloat = 16
    var weight: Font.Weight = .semibold
    var tint: Color = .white
    var background: Color? = nil
    var diameter: CGFloat? = nil
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: weight))
                .foregroundStyle(tint)
                .contentTransition(.symbolEffect(.replace.downUp))
                .frame(width: diameter ?? size * 2.2, height: diameter ?? size * 2.2)
                .background(
                    Circle().fill(background ?? Color.white.opacity(hovering ? 0.12 : 0))
                )
                .overlay(
                    Circle().fill(Color.white.opacity(background != nil && hovering ? 0.08 : 0))
                )
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
    }
}

/// Capsule button with text, e.g. "Snooze".
struct CapsuleButton: View {
    let title: String
    var symbol: String? = nil
    var tint: Color = .orange
    var filled = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 12, weight: .bold)) }
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            }
            .fixedSize()
            .foregroundStyle(filled ? Color.black : tint)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(Capsule().fill(filled ? tint : tint.opacity(hovering ? 0.32 : 0.22)))
            .brightness(filled && hovering ? 0.08 : 0)
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle(scale: 0.92))
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
    }
}

/// Small pill chip for presets.
struct ChipButton: View {
    let title: String
    var tint: Color = .white
    var selected = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(selected ? Color.black : tint.opacity(0.9))
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Capsule().fill(selected ? tint : Color.white.opacity(hovering ? 0.16 : 0.09)))
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle(scale: 0.9))
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
    }
}

// MARK: - Toggle

struct IslandToggle: View {
    @Binding var isOn: Bool
    var tint: Color = Color(red: 0.2, green: 0.82, blue: 0.35)

    var body: some View {
        Capsule()
            .fill(isOn ? tint : Color.white.opacity(0.18))
            .frame(width: 40, height: 24)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .padding(2)
            }
            .contentShape(Capsule())
            .onTapGesture {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.72)) { isOn.toggle() }
            }
    }
}

// MARK: - Artwork

struct ArtworkView: View {
    let image: NSImage?
    let size: CGFloat
    var radius: CGFloat? = nil
    var accent: Color = .pink

    var body: some View {
        let r = radius ?? size * 0.22
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                LinearGradient(colors: [Color(white: 0.28), Color(white: 0.16)], startPoint: .top, endPoint: .bottom)
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: r, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: r, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
        .animation(.easeInOut(duration: 0.3), value: image)
    }
}

// MARK: - Equalizer

/// The little "now playing" waveform. Driven entirely by Core Animation so it costs the app
/// essentially no CPU while music plays; bars settle into dots when paused.
struct EqualizerView: NSViewRepresentable {
    var isPlaying: Bool
    var color: Color
    var bars = 4
    var barWidth: CGFloat = 2.6
    var spacing: CGFloat = 2.2

    func makeNSView(context: Context) -> EqualizerNSView { EqualizerNSView() }

    func updateNSView(_ view: EqualizerNSView, context: Context) {
        view.configure(bars: bars, barWidth: barWidth, spacing: spacing, color: NSColor(color), playing: isPlaying)
    }
}

final class EqualizerNSView: NSView {
    private var barLayers: [CALayer] = []
    private var playing = false
    private var barWidth: CGFloat = 2.6
    private var spacing: CGFloat = 2.2
    private var lastSize: CGSize = .zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(bars: Int, barWidth: CGFloat, spacing: CGFloat, color: NSColor, playing: Bool) {
        if bars != barLayers.count || barWidth != self.barWidth || spacing != self.spacing {
            barLayers.forEach { $0.removeFromSuperlayer() }
            barLayers = (0..<bars).map { _ in CALayer() }
            barLayers.forEach { layer?.addSublayer($0) }
            self.barWidth = barWidth
            self.spacing = spacing
            lastSize = .zero
            needsLayout = true
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.35)
        barLayers.forEach { $0.backgroundColor = color.cgColor }
        CATransaction.commit()
        if playing != self.playing {
            self.playing = playing
            applyAnimations()
        }
    }

    override func layout() {
        super.layout()
        guard bounds.size != lastSize else { return }
        lastSize = bounds.size
        let n = CGFloat(barLayers.count)
        let total = n * barWidth + (n - 1) * spacing
        var x = (bounds.width - total) / 2 + barWidth / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for bar in barLayers {
            bar.position = CGPoint(x: x, y: bounds.midY)
            bar.bounds = CGRect(x: 0, y: 0, width: barWidth, height: barWidth)
            bar.cornerRadius = barWidth / 2
            x += barWidth + spacing
        }
        CATransaction.commit()
        applyAnimations()
    }

    private func applyAnimations() {
        let maxH = max(barWidth, bounds.height)
        for (i, bar) in barLayers.enumerated() {
            let current = bar.presentation()?.bounds.height ?? bar.bounds.height
            bar.removeAnimation(forKey: "eq")
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            bar.bounds.size.height = playing ? current : barWidth
            CATransaction.commit()

            if playing {
                let anim = CAKeyframeAnimation(keyPath: "bounds.size.height")
                var values: [CGFloat] = [current]
                for _ in 0..<7 { values.append(barWidth + (maxH - barWidth) * CGFloat.random(in: 0.22...1.0)) }
                values.append(current)
                anim.values = values
                anim.duration = 1.5 + Double(i) * 0.21
                anim.calculationMode = .cubic
                anim.repeatCount = .infinity
                anim.isRemovedOnCompletion = false
                bar.add(anim, forKey: "eq")
            } else {
                let settle = CABasicAnimation(keyPath: "bounds.size.height")
                settle.fromValue = current
                settle.toValue = barWidth
                settle.duration = 0.35
                settle.timingFunction = CAMediaTimingFunction(name: .easeOut)
                bar.add(settle, forKey: "eq")
            }
        }
    }
}

// MARK: - Progress ring

struct ProgressRing: View {
    var progress: Double
    var color: Color
    var lineWidth: CGFloat = 3.5

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.25), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.0001, progress))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

// MARK: - Marquee

/// Single-line text that scrolls (with soft faded edges) when it doesn't fit. The scrolling
/// runs as a Core Animation loop rather than redrawing SwiftUI every frame.
struct MarqueeText: View {
    let text: String
    var size: CGFloat = 12
    var weight: Font.Weight = .semibold
    var color: Color = .white
    var alignment: Alignment = .center

    var body: some View {
        GeometryReader { geo in
            let font = NSFont.systemFont(ofSize: size, weight: weight.nsWeight)
            let width = ceil((text as NSString).size(withAttributes: [.font: font]).width)
            if width > geo.size.width + 0.5 {
                MarqueeLayer(text: text, font: font, color: NSColor(color))
                    .frame(width: geo.size.width, height: geo.size.height)
            } else {
                Text(text)
                    .font(.system(size: size, weight: weight))
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: alignment)
            }
        }
    }
}

private extension Font.Weight {
    var nsWeight: NSFont.Weight {
        switch self {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        default: return .regular
        }
    }
}

private struct MarqueeLayer: NSViewRepresentable {
    let text: String
    let font: NSFont
    let color: NSColor

    func makeNSView(context: Context) -> MarqueeNSView { MarqueeNSView() }
    func updateNSView(_ view: MarqueeNSView, context: Context) { view.update(text: text, font: font, color: color) }
}

final class MarqueeNSView: NSView {
    private let strip = CALayer()
    private let fade = CAGradientLayer()
    private var key = ""
    private var textWidth: CGFloat = 0
    private let gap: CGFloat = 36
    private let speed: CGFloat = 26
    private let pause: CFTimeInterval = 2.2

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(strip)
        strip.anchorPoint = CGPoint(x: 0, y: 0.5)
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        fade.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        fade.locations = [0, 0.07, 0.93, 1]
        layer?.mask = fade
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(text: String, font: NSFont, color: NSColor) {
        let newKey = "\(text)|\(font.pointSize)|\(font.fontName)|\(color)"
        guard newKey != key else { return }
        key = newKey
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (text as NSString).size(withAttributes: attrs)
        textWidth = ceil(size.width)
        let height = ceil(size.height)
        let image = NSImage(size: NSSize(width: textWidth * 2 + gap, height: height), flipped: false) { _ in
            (text as NSString).draw(at: .zero, withAttributes: attrs)
            (text as NSString).draw(at: NSPoint(x: self.textWidth + self.gap, y: 0), withAttributes: attrs)
            return true
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        strip.contents = image
        strip.contentsScale = window?.backingScaleFactor ?? 2
        strip.bounds = CGRect(x: 0, y: 0, width: image.size.width, height: height)
        CATransaction.commit()
        needsLayout = true
        restartAnimation()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        strip.contentsScale = window?.backingScaleFactor ?? 2
        restartAnimation()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = bounds
        strip.position = CGPoint(x: 0, y: bounds.midY)
        CATransaction.commit()
    }

    private func restartAnimation() {
        strip.removeAnimation(forKey: "marquee")
        guard textWidth > 0 else { return }
        let travel = textWidth + gap
        let scroll = CFTimeInterval(travel / speed)
        let total = pause + scroll
        let anim = CAKeyframeAnimation(keyPath: "position.x")
        anim.values = [0, 0, -travel]
        anim.keyTimes = [0, NSNumber(value: pause / total), 1]
        anim.duration = total
        anim.repeatCount = .infinity
        anim.isAdditive = false
        anim.isRemovedOnCompletion = false
        strip.add(anim, forKey: "marquee")
    }
}

// MARK: - Time dial

/// A big two-digit number you can scroll, drag, or click the chevrons of — the island's
/// take on the iOS picker wheel.
struct DialField: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    var unit: String? = nil
    var fontSize: CGFloat = 36
    var tint: Color = .white
    var step = 1
    var format = "%02d"

    @State private var hovering = false
    @State private var accumulator: CGFloat = 0
    @State private var dragBase: Int?

    var body: some View {
        VStack(spacing: 0) {
            chevron("chevron.up", delta: step)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(String(format: format, value))
                    .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .contentTransition(.numericText(value: Double(value)))
                if let unit {
                    Text(unit)
                        .font(.system(size: fontSize * 0.36, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            .padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(hovering ? 0.08 : 0)))
            .overlay(ScrollCatcher { dy in scrolled(dy) })
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { g in
                        if dragBase == nil { dragBase = value }
                        let steps = Int((-g.translation.height / 14).rounded())
                        set(dragBase! + steps * step)
                    }
                    .onEnded { _ in dragBase = nil }
            )
            chevron("chevron.down", delta: -step)
        }
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
    }

    private func chevron(_ symbol: String, delta: Int) -> some View {
        Button { set(value + delta) } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(hovering ? 0.7 : 0.22))
                .frame(width: 36, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.8))
    }

    private func scrolled(_ dy: CGFloat) {
        accumulator += dy
        let threshold: CGFloat = 10
        while accumulator <= -threshold { accumulator += threshold; set(value + step) }
        while accumulator >= threshold { accumulator -= threshold; set(value - step) }
    }

    private func set(_ newValue: Int) {
        let span = range.upperBound - range.lowerBound + 1
        var v = newValue
        if v > range.upperBound || v < range.lowerBound {
            v = ((v - range.lowerBound) % span + span) % span + range.lowerBound
        }
        guard v != value else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { value = v }
    }
}

// MARK: - Countdown text

struct CountdownText: View {
    let timer: IslandTimer
    var font: Font
    var color: Color

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
            let remaining = timer.remaining(at: ctx.date)
            Text(IslandFormat.clock(remaining, roundUp: true))
                .font(font)
                .monospacedDigit()
                .foregroundStyle(color)
                .contentTransition(.numericText(countsDown: true))
                .animation(.snappy(duration: 0.3), value: Int(remaining.rounded(.up)))
        }
    }
}
