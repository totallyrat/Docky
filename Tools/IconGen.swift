// Renders Docky's app icons into .iconset folders (convert with iconutil).
// Usage: swift IconGen.swift <output-dir>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let canvas: CGFloat = 1024
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let bodyRadius: CGFloat = 186

func squircle(_ rect: NSRect, radius: CGFloat) -> NSBezierPath {
    // Continuous-corner approximation (superellipse-ish) using a smoothed rounded rect.
    let p = NSBezierPath()
    let r = radius * 1.28
    let k: CGFloat = 0.62
    let minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
    p.move(to: NSPoint(x: minX + r, y: maxY))
    p.line(to: NSPoint(x: maxX - r, y: maxY))
    p.curve(to: NSPoint(x: maxX, y: maxY - r), controlPoint1: NSPoint(x: maxX - r * (1 - k), y: maxY), controlPoint2: NSPoint(x: maxX, y: maxY - r * (1 - k)))
    p.line(to: NSPoint(x: maxX, y: minY + r))
    p.curve(to: NSPoint(x: maxX - r, y: minY), controlPoint1: NSPoint(x: maxX, y: minY + r * (1 - k)), controlPoint2: NSPoint(x: maxX - r * (1 - k), y: minY))
    p.line(to: NSPoint(x: minX + r, y: minY))
    p.curve(to: NSPoint(x: minX, y: minY + r), controlPoint1: NSPoint(x: minX + r * (1 - k), y: minY), controlPoint2: NSPoint(x: minX, y: minY + r * (1 - k)))
    p.line(to: NSPoint(x: minX, y: maxY - r))
    p.curve(to: NSPoint(x: minX + r, y: maxY), controlPoint1: NSPoint(x: minX, y: maxY - r * (1 - k)), controlPoint2: NSPoint(x: minX + r * (1 - k), y: maxY))
    p.close()
    return p
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func render(_ draw: () -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas), pixelsHigh: Int(canvas), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func shadowedBody(_ fill: () -> Void) {
    let shape = squircle(body, radius: bodyRadius)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 18
    shadow.shadowOffset = NSSize(width: 0, height: -8)
    shadow.set()
    color(0x000000).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    fill()
    NSGraphicsContext.restoreGraphicsState()
}

func radialGlow(center: NSPoint, radius: CGFloat, _ c: NSColor) {
    NSGradient(colors: [c, c.withAlphaComponent(0)])!.draw(fromCenter: center, radius: 0, toCenter: center, radius: radius, options: [])
}

func drawIsland(in rect: NSRect, artColors: [NSColor], barColor: NSColor) {
    let capsule = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
    NSGraphicsContext.saveGraphicsState()
    let s = NSShadow()
    s.shadowColor = NSColor.black.withAlphaComponent(0.45)
    s.shadowBlurRadius = 30
    s.shadowOffset = NSSize(width: 0, height: -14)
    s.set()
    NSColor.black.setFill()
    capsule.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Album art
    let inset = rect.height * 0.18
    let artSize = rect.height - inset * 2
    let art = NSRect(x: rect.minX + inset * 1.25, y: rect.minY + inset, width: artSize, height: artSize)
    let artPath = NSBezierPath(roundedRect: art, xRadius: artSize * 0.26, yRadius: artSize * 0.26)
    NSGradient(colors: artColors)!.draw(in: artPath, angle: -55)

    // Equalizer
    let bars: [CGFloat] = [0.55, 0.95, 0.42, 0.78]
    let barW = rect.height * 0.12
    let gap = barW * 0.7
    let total = CGFloat(bars.count) * barW + CGFloat(bars.count - 1) * gap
    var x = rect.maxX - inset * 1.6 - total
    for h in bars {
        let bh = artSize * 0.82 * h
        let bar = NSRect(x: x, y: rect.midY - bh / 2, width: barW, height: bh)
        barColor.setFill()
        NSBezierPath(roundedRect: bar, xRadius: barW / 2, yRadius: barW / 2).fill()
        x += barW + gap
    }
}

func writeIconset(named name: String, from master: NSBitmapImageRep) throws {
    let dir = out.appendingPathComponent("\(name).iconset")
    try? FileManager.default.removeItem(at: dir)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let image = NSImage(size: NSSize(width: canvas, height: canvas))
    image.addRepresentation(master)
    let specs: [(String, Int)] = [
        ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
        ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ]
    for (file, px) in specs {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        try rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent("\(file).png"))
    }
}

// MARK: Docky (the island)

let islandIcon = render {
    shadowedBody {
        NSGradient(colors: [color(0x2A2E45), color(0x141522), color(0x0B0B12)])!.draw(in: body, angle: -90)
        radialGlow(center: NSPoint(x: 260, y: 170), radius: 520, color(0x7B4DFF, 0.55))
        radialGlow(center: NSPoint(x: 820, y: 230), radius: 480, color(0xFF5E7A, 0.45))
        radialGlow(center: NSPoint(x: 560, y: 60), radius: 380, color(0xFFB347, 0.35))
        // Faint glass sheen
        NSGradient(colors: [NSColor.white.withAlphaComponent(0.10), NSColor.white.withAlphaComponent(0)])!
            .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
        drawIsland(in: NSRect(x: 232, y: 640, width: 560, height: 160),
                   artColors: [color(0xFF4F8B), color(0xFF9A3C)],
                   barColor: color(0xFF7FA6))
        // A dropped-down "expanded" card hint
        let card = NSRect(x: 232, y: 300, width: 560, height: 280)
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: card, xRadius: 70, yRadius: 70).fill()
        let track = NSRect(x: 292, y: 400, width: 440, height: 18)
        NSColor.white.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: track, xRadius: 9, yRadius: 9).fill()
        color(0xFF7FA6).setFill()
        NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: 250, height: 18), xRadius: 9, yRadius: 9).fill()
        let play = NSBezierPath()
        play.move(to: NSPoint(x: 492, y: 510)); play.line(to: NSPoint(x: 492, y: 450)); play.line(to: NSPoint(x: 545, y: 480)); play.close()
        NSColor.white.withAlphaComponent(0.9).setFill()
        play.fill()
    }
}
try writeIconset(named: "AppIcon", from: islandIcon)

// MARK: Docky Settings

let settingsIcon = render {
    shadowedBody {
        NSGradient(colors: [color(0xF4F4F7), color(0xD9DAE0), color(0xB9BAC4)])!.draw(in: body, angle: -90)
        if let gear = NSImage(systemSymbolName: "gearshape.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 470, weight: .regular).applying(.init(paletteColors: [color(0x5E5F68)]))) {
            let size = gear.size
            let rect = NSRect(x: 512 - size.width / 2, y: 440 - size.height / 2, width: size.width, height: size.height)
            NSGraphicsContext.saveGraphicsState()
            let s = NSShadow()
            s.shadowColor = NSColor.white.withAlphaComponent(0.7)
            s.shadowOffset = NSSize(width: 0, height: -4)
            s.shadowBlurRadius = 2
            s.set()
            gear.draw(in: rect)
            NSGraphicsContext.restoreGraphicsState()
        }
        drawIsland(in: NSRect(x: 292, y: 735, width: 440, height: 124),
                   artColors: [color(0x4F8BFF), color(0x8E5CFF)],
                   barColor: color(0x34C759))
    }
}
try writeIconset(named: "SettingsIcon", from: settingsIcon)
print("iconsets written to \(out.path)")
