import AppKit
import CoreImage
import QuartzCore
import SwiftUI

/// Colours shared by the screen-edge glow and the island's glow ring (Apple Intelligence-like).
enum IntroPalette {
    static let nsColors: [NSColor] = [
        NSColor(srgbRed: 0.33, green: 0.52, blue: 1.00, alpha: 1), // blue
        NSColor(srgbRed: 0.66, green: 0.42, blue: 1.00, alpha: 1), // violet
        NSColor(srgbRed: 1.00, green: 0.42, blue: 0.80, alpha: 1), // pink
        NSColor(srgbRed: 1.00, green: 0.55, blue: 0.32, alpha: 1), // orange
        NSColor(srgbRed: 0.98, green: 0.36, blue: 0.48, alpha: 1), // coral
        NSColor(srgbRed: 0.30, green: 0.82, blue: 1.00, alpha: 1), // cyan
    ]
    static let colors: [Color] = nsColors.map(Color.init)

    static func gradient(angle: Angle) -> AngularGradient {
        AngularGradient(colors: colors + [colors[0]], center: .center, angle: angle)
    }

    static func angle(at date: Date) -> Angle {
        .degrees((date.timeIntervalSinceReferenceDate * 70).truncatingRemainder(dividingBy: 360))
    }
}

/// The launch intro, built entirely from Core Animation so it runs in the window server at
/// full frame rate without touching the main thread:
///
///   0.00  the screen's edges dim slightly
///   0.05  two flames ignite at the bottom centre and race up both sides, shedding sparks
///   0.95  they meet at the top centre in a flash and a burst of sparks
///   0.45  "Docky" rises in the middle; a highlight sweeps across it
///   1.85  the wordmark shrinks up into the top of the screen…
///   2.05  …and the island drops in, wearing the same glow for three seconds
///   5.05  the edge glow, vignette and island glow fade away
final class IntroController {
    private var window: NSWindow?
    private var work: [DispatchWorkItem] = []

    static let ignite: CFTimeInterval = 0.9
    static let meet: CFTimeInterval = 0.95
    static let wordIn: CFTimeInterval = 0.45
    static let wordOut: CFTimeInterval = 1.85
    static let dropTime: CFTimeInterval = 2.05
    static let fadeTime: CFTimeInterval = 5.05
    static let endTime: CFTimeInterval = 6.0

    var isPlaying: Bool { window != nil }
    var debugWindow: NSWindow? { window }

    /// Where the island will sit (screen coordinates) and its corner radius.
    var islandFrame: () -> (rect: CGRect, radius: CGFloat) = { (.zero, 0) }

    func play(on screen: NSScreen, model: IslandModel) {
        stop()
        model.introHidden = true
        model.introGlow = false

        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        w.animationBehavior = .none

        let view = IntroLayerView(frame: NSRect(origin: .zero, size: screen.frame.size), scale: screen.backingScaleFactor)
        w.contentView = view
        w.setFrame(screen.frame, display: true)
        w.orderFrontRegardless()
        window = w
        let island = islandFrame()
        view.run(island: island.rect.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY), radius: island.radius)

        schedule(Self.dropTime) {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.68)) {
                model.introHidden = false
                model.introGlow = true
            }
        }
        schedule(Self.fadeTime) {
            withAnimation(.easeInOut(duration: 0.8)) { model.introGlow = false }
        }
        schedule(Self.endTime) { [weak self] in self?.stop() }
    }

    func stop() {
        work.forEach { $0.cancel() }
        work.removeAll()
        window?.orderOut(nil)
        window?.close()
        window = nil
    }

    private func schedule(_ delay: TimeInterval, _ block: @escaping () -> Void) {
        let item = DispatchWorkItem(block: block)
        work.append(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
}

// MARK: - Layer tree

private final class IntroLayerView: NSView {
    private let scale: CGFloat
    private let root = CALayer()

    init(frame: NSRect, scale: CGFloat) {
        self.scale = scale
        super.init(frame: frame)
        layer = root
        wantsLayer = true
        root.frame = bounds
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var total: CFTimeInterval { IntroController.endTime }

    func run(island: CGRect, radius: CGFloat) {
        let b = bounds
        let now = CACurrentMediaTime()
        let ease = CAMediaTimingFunction(controlPoints: 0.3, 0.0, 0.2, 1.0)

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // 1. Vignette: a soft darkening around the edges makes the glow read on any wallpaper.
        let vignette = CAGradientLayer()
        vignette.type = .radial
        vignette.frame = b
        vignette.colors = [NSColor.black.withAlphaComponent(0).cgColor, NSColor.black.withAlphaComponent(0.42).cgColor]
        vignette.locations = [0.55, 1]
        vignette.startPoint = CGPoint(x: 0.5, y: 0.5)
        vignette.endPoint = CGPoint(x: 1.08, y: 1.08)
        vignette.opacity = 0
        root.addSublayer(vignette)
        fade(vignette, at: [0, 0.42, 5.0, 5.8], values: [0, 1, 1, 0], begin: now)

        // 2. The glow: a slowly turning conic gradient seen through pre-blurred border masks,
        //    revealed by two strokes running up the sides.
        let reveal = CALayer()
        reveal.frame = b
        var revealStrokes: [CAShapeLayer] = []
        for path in Self.halfPaths(in: b, inset: 0) {
            let s = CAShapeLayer()
            s.frame = b
            s.path = path
            s.fillColor = nil
            s.strokeColor = NSColor.white.cgColor
            s.lineWidth = 240
            s.lineCap = .round
            s.strokeEnd = 0
            reveal.addSublayer(s)
            revealStrokes.append(s)
        }
        let glowGroup = CALayer()
        glowGroup.frame = b
        glowGroup.mask = reveal
        root.addSublayer(glowGroup)

        // Soft outer bloom, a brighter core, and a crisp line.
        let specs: [(width: CGFloat, blur: CGFloat, res: CGFloat, opacity: Float)] = [
            (80, 50, 0.16, 0.8), (22, 12, 0.35, 0.95), (5, 1.0, 1.0, 1.0),
        ]
        for spec in specs {
            let color = Self.conicLayer(frame: b)
            let mask = CALayer()
            mask.frame = b
            mask.contents = Self.borderMask(size: b.size, lineWidth: spec.width, blur: spec.blur, resolution: spec.res * scale)
            color.mask = mask
            color.opacity = spec.opacity
            glowGroup.addSublayer(color)
            spin(color, begin: now)
        }
        for s in revealStrokes {
            let a = CABasicAnimation(keyPath: "strokeEnd")
            a.fromValue = 0
            a.toValue = 1
            a.beginTime = now + 0.05
            a.duration = IntroController.ignite
            a.timingFunction = ease
            a.fillMode = .forwards
            a.isRemovedOnCompletion = false
            s.add(a, forKey: "ignite")
        }
        fade(glowGroup, at: [0, IntroController.fadeTime, IntroController.fadeTime + 0.8], values: [1, 1, 0], begin: now)

        // 3. Flame heads lead each stroke, shedding sparks.
        let headImage = Self.radialImage(diameter: 90, colors: [.white, IntroPalette.nsColors[2].withAlphaComponent(0.4), .clear])
        for path in Self.halfPaths(in: b, inset: 3) {
            let move = CAKeyframeAnimation(keyPath: "position")
            move.path = path
            move.calculationMode = .paced
            move.timingFunction = ease
            move.beginTime = now + 0.05
            move.duration = IntroController.ignite
            move.fillMode = .both
            move.isRemovedOnCompletion = false

            let head = CALayer()
            head.contents = headImage
            head.bounds = CGRect(x: 0, y: 0, width: 90, height: 90)
            head.position = CGPoint(x: b.midX, y: -300)
            head.compositingFilter = "screenBlendMode"
            root.addSublayer(head)
            head.add(move, forKey: "run")
            fade(head, at: [0, 0.06, 0.95, 1.15], values: [0, 1, 1, 0], begin: now)

            let sparks = Self.trailEmitter(frame: b)
            root.addSublayer(sparks)
            let follow = move.copy() as! CAKeyframeAnimation
            follow.keyPath = "emitterPosition"
            sparks.add(follow, forKey: "run")
            let rate = CAKeyframeAnimation(keyPath: "birthRate")
            rate.values = [0, 1, 1, 0]
            rate.keyTimes = [0, 0.05, 0.9, 1]
            rate.beginTime = now + 0.05
            rate.duration = IntroController.ignite
            rate.fillMode = .both
            rate.isRemovedOnCompletion = false
            sparks.add(rate, forKey: "rate")
        }

        // 4. Where the flames meet: a flash and a burst of sparks spilling from the top.
        let flash = CALayer()
        flash.contents = Self.radialImage(diameter: 560, colors: [.white, IntroPalette.nsColors[1].withAlphaComponent(0.5), .clear])
        flash.bounds = CGRect(x: 0, y: 0, width: 560, height: 560)
        flash.position = CGPoint(x: b.midX, y: b.maxY)
        flash.compositingFilter = "screenBlendMode"
        flash.opacity = 0
        root.addSublayer(flash)
        fade(flash, at: [0, 0.92, 1.05, 1.9], values: [0, 0, 1, 0], begin: now)

        let burst = Self.burstEmitter(frame: b)
        root.addSublayer(burst)
        let burstRate = CAKeyframeAnimation(keyPath: "birthRate")
        burstRate.values = [0, 1, 0]
        burstRate.keyTimes = [0, 0.01, 1]
        burstRate.beginTime = now + IntroController.meet
        burstRate.duration = 0.18
        burstRate.fillMode = .both
        burstRate.isRemovedOnCompletion = false
        burst.add(burstRate, forKey: "rate")

        // 5. The wordmark rises, a highlight sweeps across, then it flies up to where the island lands.
        let (word, shine) = Self.wordmarkLayer()
        word.position = CGPoint(x: b.midX, y: b.midY)
        word.opacity = 0
        root.addSublayer(word)

        let k = { (s: CFTimeInterval) in NSNumber(value: s / self.total) }
        let wIn = IntroController.wordIn, wOut = IntroController.wordOut
        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = [0, 0, 1, 1, 0]
        opacity.keyTimes = [k(0), k(wIn), k(wIn + 0.4), k(wOut + 0.1), k(wOut + 0.4)]
        let scaleKeys = [k(0), k(wIn), k(wIn + 0.65), k(wOut), k(wOut + 0.42)]
        let scaleAnim = CAKeyframeAnimation(keyPath: "transform.scale")
        scaleAnim.values = [0.84, 0.84, 1.0, 1.03, 0.12]
        scaleAnim.keyTimes = scaleKeys
        scaleAnim.timingFunctions = [ease, CAMediaTimingFunction(controlPoints: 0.2, 1.35, 0.4, 1), ease, CAMediaTimingFunction(name: .easeIn)]
        let rise = CAKeyframeAnimation(keyPath: "position.y")
        rise.values = [b.midY - 30, b.midY - 30, b.midY, b.midY + 6, b.maxY - 20]
        rise.keyTimes = scaleKeys
        rise.timingFunctions = [ease, ease, ease, CAMediaTimingFunction(name: .easeIn)]
        let group = CAAnimationGroup()
        group.animations = [opacity, scaleAnim, rise]
        group.beginTime = now
        group.duration = total
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        word.add(group, forKey: "word")

        let sweep = CABasicAnimation(keyPath: "position.x")
        sweep.fromValue = -160
        sweep.toValue = word.bounds.width + 160
        sweep.beginTime = now + wIn + 0.45
        sweep.duration = 0.9
        sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        sweep.fillMode = .both
        shine.add(sweep, forKey: "sweep")

        if island.width > 0 { addIslandGlow(island: island, radius: radius, begin: now) }

        CATransaction.commit()
    }

    /// The glow the island wears while it drops in — drawn here, just behind the island
    /// window, so it costs nothing on the main thread.
    private func addIslandGlow(island: CGRect, radius: CGFloat, begin: CFTimeInterval) {
        let pad: CGFloat = 70
        let frame = island.insetBy(dx: -pad, dy: -pad)
        let holder = CALayer()
        holder.frame = frame
        holder.opacity = 0
        root.addSublayer(holder)
        let local = CGRect(x: pad, y: pad, width: island.width, height: island.height)
        let specs: [(width: CGFloat, blur: CGFloat, opacity: Float)] = [(26, 22, 0.95), (7, 4, 1), (2.5, 0, 1)]
        for spec in specs {
            let color = Self.conicLayer(frame: holder.bounds)
            let mask = CALayer()
            mask.frame = holder.bounds
            mask.contents = Self.roundedMask(size: frame.size, rect: local, radius: radius, lineWidth: spec.width, blur: spec.blur, scale: scale)
            color.mask = mask
            color.opacity = spec.opacity
            holder.addSublayer(color)
            spin(color, begin: begin)
        }
        let drop = IntroController.dropTime, fadeAt = IntroController.fadeTime
        fade(holder, at: [0, drop, drop + 0.15, fadeAt, fadeAt + 0.8], values: [0, 0, 1, 1, 0], begin: begin)
        // Same spring as the island itself (response 0.6, damping 0.68).
        let fall = CASpringAnimation(keyPath: "position.y")
        fall.fromValue = frame.midY + island.height + 40
        fall.toValue = frame.midY
        fall.mass = 1
        fall.stiffness = pow(2 * .pi / 0.6, 2)
        fall.damping = 2 * 0.68 * sqrt(fall.stiffness)
        fall.beginTime = begin + drop
        fall.duration = fall.settlingDuration
        fall.fillMode = .backwards
        holder.add(fall, forKey: "fall")
    }

    static func roundedMask(size: CGSize, rect: CGRect, radius: CGFloat, lineWidth: CGFloat, blur: CGFloat, scale: CGFloat) -> CGImage? {
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(lineWidth)
        let r = min(radius, rect.height / 2, rect.width / 2)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil))
        ctx.strokePath()
        guard let sharp = ctx.makeImage() else { return nil }
        guard blur > 0.5 else { return sharp }
        let input = CIImage(cgImage: sharp)
        let blurred = input.clampedToExtent().applyingGaussianBlur(sigma: Double(blur * scale)).cropped(to: input.extent)
        return CIContext().createCGImage(blurred, from: input.extent)
    }

    /// Opacity keyframes at absolute times (seconds from the start).
    private func fade(_ layer: CALayer, at times: [CFTimeInterval], values: [Float], begin: CFTimeInterval) {
        let a = CAKeyframeAnimation(keyPath: "opacity")
        a.values = values
        a.keyTimes = times.map { NSNumber(value: min(1, $0 / total)) }
        a.beginTime = begin
        a.duration = total
        a.fillMode = .forwards
        a.isRemovedOnCompletion = false
        layer.add(a, forKey: "opacity")
    }

    /// Turning a conic gradient = moving its end point around its centre.
    private func spin(_ gradient: CAGradientLayer, begin: CFTimeInterval) {
        let steps = 48
        let a = CAKeyframeAnimation(keyPath: "endPoint")
        a.values = (0...steps).map { i -> NSValue in
            let angle = Double(i) / Double(steps) * 2 * .pi
            return NSValue(point: CGPoint(x: 0.5 + 0.5 * cos(angle), y: 0.5 + 0.5 * sin(angle)))
        }
        a.duration = 4.5
        a.repeatCount = .infinity
        a.beginTime = begin
        gradient.add(a, forKey: "spin")
    }

    // MARK: Builders

    /// Two paths from the bottom centre up either side to the top centre (y up).
    static func halfPaths(in b: CGRect, inset: CGFloat) -> [CGPath] {
        [b.maxX - inset, b.minX + inset].map { sideX in
            let p = CGMutablePath()
            p.move(to: CGPoint(x: b.midX, y: b.minY + inset))
            p.addLine(to: CGPoint(x: sideX, y: b.minY + inset))
            p.addLine(to: CGPoint(x: sideX, y: b.maxY - inset))
            p.addLine(to: CGPoint(x: b.midX, y: b.maxY - inset))
            return p
        }
    }

    static func conicLayer(frame: CGRect) -> CAGradientLayer {
        let g = CAGradientLayer()
        g.type = .conic
        g.frame = frame
        g.colors = (IntroPalette.nsColors + [IntroPalette.nsColors[0]]).map(\.cgColor)
        g.startPoint = CGPoint(x: 0.5, y: 0.5)
        g.endPoint = CGPoint(x: 1, y: 0.5)
        return g
    }

    /// A blurred white border on clear, rendered once at low resolution — glows are soft, so
    /// the GPU upscales them for free.
    static func borderMask(size: CGSize, lineWidth: CGFloat, blur: CGFloat, resolution: CGFloat) -> CGImage? {
        let w = max(1, Int(size.width * resolution)), h = max(1, Int(size.height * resolution))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.scaleBy(x: resolution, y: resolution)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(lineWidth)
        ctx.stroke(CGRect(origin: .zero, size: size))
        guard let sharp = ctx.makeImage() else { return nil }
        guard blur > 1.5 else { return sharp }
        let input = CIImage(cgImage: sharp)
        let blurred = input.clampedToExtent().applyingGaussianBlur(sigma: Double(blur * resolution)).cropped(to: input.extent)
        return CIContext().createCGImage(blurred, from: input.extent)
    }

    static func radialImage(diameter: CGFloat, colors: [NSColor]) -> CGImage? {
        let px = Int(diameter)
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors.map(\.cgColor) as CFArray,
                                        locations: [0, 0.22, 1])
        else { return nil }
        let c = CGPoint(x: diameter / 2, y: diameter / 2)
        ctx.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: diameter / 2, options: [])
        return ctx.makeImage()
    }

    /// "Docky" in heavy SF Rounded with a coloured bloom; returns the layer and its shine stripe.
    static func wordmarkLayer() -> (CALayer, CALayer) {
        let base = NSFont.systemFont(ofSize: 120, weight: .heavy)
        let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 120) } ?? base
        let text = "Docky" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .kern: -2.5]
        let textSize = text.size(withAttributes: attrs)
        let pad: CGFloat = 100
        let size = CGSize(width: ceil(textSize.width) + pad * 2, height: ceil(textSize.height) + pad * 2)
        let origin = NSPoint(x: pad, y: pad)

        func image(_ draw: @escaping (CGContext) -> Void) -> NSImage {
            NSImage(size: size, flipped: false) { _ in
                if let ctx = NSGraphicsContext.current?.cgContext { draw(ctx) }
                return true
            }
        }

        let bloom = image { _ in
            let layers: [(NSColor, CGFloat)] = [(IntroPalette.nsColors[0], 80), (IntroPalette.nsColors[2], 44), (IntroPalette.nsColors[1], 20)]
            for (color, radius) in layers {
                let shadow = NSShadow()
                shadow.shadowColor = color.withAlphaComponent(0.95)
                shadow.shadowBlurRadius = radius
                var a = attrs
                a[.foregroundColor] = color.withAlphaComponent(0.55)
                a[.shadow] = shadow
                text.draw(at: origin, withAttributes: a)
            }
        }
        let face = image { ctx in
            var a = attrs
            a[.foregroundColor] = NSColor.white
            text.draw(at: origin, withAttributes: a)
            ctx.setBlendMode(.sourceAtop)
            let colors = [NSColor.white.cgColor,
                          NSColor(srgbRed: 0.92, green: 0.9, blue: 1, alpha: 1).cgColor,
                          NSColor(srgbRed: 1, green: 0.86, blue: 0.95, alpha: 1).cgColor] as CFArray
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.6, 1])!
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: size.height), end: .zero, options: [])
        }

        let container = CALayer()
        container.bounds = CGRect(origin: .zero, size: size)
        let bloomLayer = CALayer()
        bloomLayer.frame = container.bounds
        bloomLayer.contents = bloom
        bloomLayer.compositingFilter = "screenBlendMode"
        let faceLayer = CALayer()
        faceLayer.frame = container.bounds
        faceLayer.contents = face
        container.addSublayer(bloomLayer)
        container.addSublayer(faceLayer)

        // Highlight stripe, clipped to the letters.
        let shineHolder = CALayer()
        shineHolder.frame = container.bounds
        let lettersMask = CALayer()
        lettersMask.frame = container.bounds
        lettersMask.contents = face
        shineHolder.mask = lettersMask
        let shine = CAGradientLayer()
        shine.colors = [NSColor.white.withAlphaComponent(0).cgColor, NSColor.white.withAlphaComponent(0.95).cgColor,
                        NSColor.white.withAlphaComponent(0).cgColor]
        shine.startPoint = CGPoint(x: 0, y: 0.5)
        shine.endPoint = CGPoint(x: 1, y: 0.5)
        shine.bounds = CGRect(x: 0, y: 0, width: 110, height: size.height * 1.6)
        shine.position = CGPoint(x: -160, y: size.height / 2)
        shine.transform = CATransform3DMakeRotation(-0.35, 0, 0, 1)
        shineHolder.addSublayer(shine)
        container.addSublayer(shineHolder)
        return (container, shine)
    }

    private static let sparkImage: CGImage? = radialImage(diameter: 48, colors: [.white, NSColor.white.withAlphaComponent(0.35), .clear])

    static func trailEmitter(frame: CGRect) -> CAEmitterLayer {
        let e = CAEmitterLayer()
        e.frame = frame
        e.emitterShape = .point
        e.renderMode = .additive
        e.birthRate = 0
        e.emitterCells = IntroPalette.nsColors.prefix(4).map { color in
            let cell = CAEmitterCell()
            cell.contents = sparkImage
            cell.color = color.cgColor
            cell.birthRate = 90
            cell.lifetime = 0.8
            cell.lifetimeRange = 0.4
            cell.velocity = 190
            cell.velocityRange = 130
            cell.emissionRange = .pi * 2
            cell.yAcceleration = -160
            cell.scale = 0.22
            cell.scaleRange = 0.12
            cell.scaleSpeed = -0.2
            cell.alphaSpeed = -1.1
            return cell
        }
        return e
    }

    static func burstEmitter(frame: CGRect) -> CAEmitterLayer {
        let e = CAEmitterLayer()
        e.frame = frame
        e.emitterShape = .point
        e.emitterPosition = CGPoint(x: frame.midX, y: frame.maxY - 4)
        e.renderMode = .additive
        e.birthRate = 0
        e.emitterCells = IntroPalette.nsColors.map { color in
            let cell = CAEmitterCell()
            cell.contents = sparkImage
            cell.color = color.cgColor
            cell.birthRate = 1100
            cell.lifetime = 1.4
            cell.lifetimeRange = 0.5
            cell.velocity = 560
            cell.velocityRange = 320
            cell.emissionLongitude = -.pi / 2
            cell.emissionRange = .pi * 0.85
            cell.yAcceleration = -300
            cell.scale = 0.28
            cell.scaleRange = 0.15
            cell.scaleSpeed = -0.18
            cell.alphaSpeed = -0.7
            return cell
        }
        return e
    }
}

// MARK: - Break glow

/// The warm, soft glow around the screen during a Pomodoro break. Unlike the intro it never
/// flashes: it fades in slowly, breathes gently, and drifts through warm tones until the break
/// ends or the island is swiped up.
final class BreakGlowController {
    private var window: NSWindow?
    private var fadeWork: DispatchWorkItem?

    static let warm: [NSColor] = [
        NSColor(srgbRed: 1.00, green: 0.72, blue: 0.42, alpha: 1), // amber
        NSColor(srgbRed: 1.00, green: 0.58, blue: 0.46, alpha: 1), // peach
        NSColor(srgbRed: 1.00, green: 0.64, blue: 0.68, alpha: 1), // rose
        NSColor(srgbRed: 1.00, green: 0.84, blue: 0.56, alpha: 1), // soft gold
        NSColor(srgbRed: 0.99, green: 0.62, blue: 0.40, alpha: 1), // apricot
    ]

    var isShowing: Bool { window != nil }
    var debugWindow: NSWindow? { window }

    func show(on screen: NSScreen) {
        fadeWork?.cancel()
        if let window, let root = window.contentView?.layer {
            // Already up (or fading out): fade back in.
            root.removeAnimation(forKey: "out")
            root.opacity = 1
            return
        }
        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        w.animationBehavior = .none

        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        let root = CALayer()
        view.layer = root
        view.wantsLayer = true
        root.frame = view.bounds
        w.contentView = view
        build(in: root, bounds: view.bounds, scale: screen.backingScaleFactor)
        w.setFrame(screen.frame, display: true)
        w.orderFrontRegardless()
        window = w

        let fadeIn = CABasicAnimation(keyPath: "opacity")
        fadeIn.fromValue = 0
        fadeIn.toValue = 1
        fadeIn.duration = 1.6
        fadeIn.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        root.add(fadeIn, forKey: "in")
    }

    func hide() {
        guard let window, let root = window.contentView?.layer else { return }
        let out = CABasicAnimation(keyPath: "opacity")
        out.fromValue = root.presentation()?.opacity ?? 1
        out.toValue = 0
        out.duration = 1.1
        out.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        out.fillMode = .forwards
        out.isRemovedOnCompletion = false
        root.add(out, forKey: "out")
        let work = DispatchWorkItem { [weak self] in
            self?.window?.orderOut(nil)
            self?.window?.close()
            self?.window = nil
        }
        fadeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.15, execute: work)
    }

    private func build(in root: CALayer, bounds b: CGRect, scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // A faint warm wash toward the edges, like late-afternoon light.
        let wash = CAGradientLayer()
        wash.type = .radial
        wash.frame = b
        wash.colors = [NSColor(srgbRed: 1, green: 0.7, blue: 0.45, alpha: 0).cgColor,
                       NSColor(srgbRed: 1, green: 0.62, blue: 0.42, alpha: 0.16).cgColor]
        wash.locations = [0.5, 1]
        wash.startPoint = CGPoint(x: 0.5, y: 0.5)
        wash.endPoint = CGPoint(x: 1.05, y: 1.05)
        root.addSublayer(wash)

        // Wide, very soft border light plus a gentler inner band.
        let specs: [(width: CGFloat, blur: CGFloat, res: CGFloat, opacity: Float)] = [(150, 80, 0.18, 0.72), (44, 24, 0.3, 0.6)]
        for spec in specs {
            let color = CAGradientLayer()
            color.type = .conic
            color.frame = b
            color.colors = (Self.warm + [Self.warm[0]]).map(\.cgColor)
            color.startPoint = CGPoint(x: 0.5, y: 0.5)
            color.endPoint = CGPoint(x: 1, y: 0.5)
            let mask = CALayer()
            mask.frame = b
            mask.contents = IntroLayerView.borderMask(size: b.size, lineWidth: spec.width, blur: spec.blur, resolution: spec.res * scale)
            color.mask = mask
            color.opacity = spec.opacity
            root.addSublayer(color)

            // Slow colour drift.
            let steps = 36
            let drift = CAKeyframeAnimation(keyPath: "endPoint")
            drift.values = (0...steps).map { i -> NSValue in
                let a = Double(i) / Double(steps) * 2 * .pi
                return NSValue(point: CGPoint(x: 0.5 + 0.5 * cos(a), y: 0.5 + 0.5 * sin(a)))
            }
            drift.duration = 24
            drift.repeatCount = .infinity
            color.add(drift, forKey: "drift")
        }

        // Gentle breathing of the whole glow.
        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = 0.72
        breathe.toValue = 1.0
        breathe.duration = 3.6
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        let breather = CALayer()
        breather.frame = b
        for layer in root.sublayers ?? [] {
            layer.removeFromSuperlayer()
            breather.addSublayer(layer)
        }
        root.addSublayer(breather)
        breather.add(breathe, forKey: "breathe")

        CATransaction.commit()
    }
}
