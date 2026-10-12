#if DOCKY_DEBUG
import AppKit

/// Test-only remote control (compiled with -D DOCKY_DEBUG): drive island states and
/// snapshot the island window from the command line.
///   swift -e '…postNotificationName("com.totallyrat.docky.debug", object: "expand timers")'
enum DebugHooks {
    static var freezeMouse = false

    static var extraWindows: () -> [NSWindow] = { [] }
    static var playIntro: () -> Void = {}
    static var showAccessibilityNotice: () -> Void = {}

    static func install(model: IslandModel, controller: IslandWindowController, clock: ClockStore, lock: LockMonitor, nowPlaying: NowPlayingService) {
        DistributedNotificationCenter.default().addObserver(
            forName: .init("com.totallyrat.docky.debug"), object: nil, queue: .main
        ) { note in
            guard let raw = note.object as? String else { return }
            let parts = raw.split(separator: " ", maxSplits: 1).map(String.init)
            let arg = parts.count > 1 ? parts[1] : ""
            switch parts[0] {
            case "freeze": freezeMouse = arg == "1"
            case "hover": freezeMouse = true; model.setHovering(arg == "1")
            case "expand": model.expand(tab: IslandTab(rawValue: arg) ?? .nowPlaying)
            case "collapse": model.collapse()
            case "stretch": model.setSwipeStretch(CGFloat(Double(arg) ?? 0))
            case "timer": clock.startTimer(duration: Double(arg) ?? 60)
            case "canceltimers": clock.timers.removeAll()
            case "alarm": clock.fireTestAlarm()
            case "reminder": clock.addReminder(title: arg.isEmpty ? "Call Mom" : arg, due: Date().addingTimeInterval(1))
            case "addreminder": clock.addReminder(title: arg, due: Date().addingTimeInterval(3600 * 2))
            case "addalarm":
                let hm = arg.split(separator: ":").compactMap { Int($0) }
                clock.addAlarm(IslandAlarm(hour: hm.first ?? 7, minute: hm.count > 1 ? hm[1] : 0, label: "Wake up", repeatDays: [2, 3, 4, 5, 6]))
            case "dismiss": if let a = clock.alerts.first { clock.dismissAlert(a) }
            case "lock": lock.debugSet(arg)
            case "compose": model.requestCompose(.reminders)
            case "snap": controller.snapshot(to: arg)
            case "fullscreen": model.fullscreenActive = arg == "1"
            case "hud":
                switch arg {
                case "volume": model.showHUD(HUDEvent(kind: .volume, symbol: "speaker.wave.3.fill", title: "Speakers", level: 0.62))
                case "brightness": model.showHUD(HUDEvent(kind: .brightness, symbol: "sun.max.fill", title: "Brightness", level: 0.8))
                case "focus": model.showHUD(HUDEvent(kind: .focus, symbol: "moon.fill", title: "Do Not Disturb", detail: "On", tint: .purple))
                case "airpods": model.showHUD(HUDEvent(kind: .device, symbol: "airpodspro", title: "AirPods Pro", detail: "85%", tint: .blue))
                case "charging": model.showHUD(HUDEvent(kind: .charging, symbol: "battery.100percent.bolt", title: "Charging", detail: "64%", tint: .green))
                default: break
                }
            case "state":
                let text = "presentation=\(model.layout.presentation) size=\(model.layout.size) fullscreen=\(model.fullscreenActive) introHidden=\(model.introHidden) hover=\(model.isHovering) front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-")\n"
                try? text.write(toFile: arg, atomically: true, encoding: .utf8)
            case "clip": model.clipboard.add(arg.split(separator: "|").map { URL(fileURLWithPath: String($0)) })
            case "clipclear": model.clipboard.clear()
            case "intro": playIntro()
            case "axnotice": showAccessibilityNotice()
            case "hudlevel": model.setHUDLevel(Double(arg) ?? 0.5)
            case "stretch2": model.setDragStretch(CGFloat(Double(arg) ?? 0))
            case "onb":
                if model.onboardingStep == nil { model.startOnboarding() }
                let target = Int(arg) ?? 0
                model.onboardingGo(target - (model.onboardingStep ?? 0))
            case "onbdemo": model.demonstrate(after: 0)
            case "onbfinish": model.finishOnboarding()
            case "retract": model.retractMusic()
            case "snapwindow":
                // snapwindow <path>: capture the frontmost titled Docky window (settings / onboarding).
                if let w = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }),
                   let img = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(w.windowNumber), [.boundsIgnoreFraming, .bestResolution]) {
                    try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: arg))
                }
            case "pomo":
                let v = arg.split(separator: " ").compactMap { Double($0) }
                clock.debugStartPomodoro(focus: v.first ?? 4, rest: v.count > 1 ? v[1] : 8)
            case "pomostop": clock.stopPomodoro()
            case "timersmode": model.timersMode = arg == "pomodoro" ? .pomodoro : .timers
            case "breakdismiss": model.dismissBreakMoment()
            case "restore": model.restoreMusic()
            case "cdrag":
                // cdrag <dx> <dy> <startX>: simulate a finished click-drag on the compact island.
                let v = arg.split(separator: " ").compactMap { Double($0) }
                if v.count == 3 {
                    model.compactDragEnded(translation: CGSize(width: v[0], height: v[1]), startX: v[2], width: model.layout.size.width)
                }
            case "settings": model.openSettings()
            case "closesettings": NSApp.windows.first { $0.styleMask.contains(.titled) }?.performClose(nil)
            case "comp":
                // comp <prefix> <count> <interval>: composite every Docky window onto a wallpaper.
                let bits = arg.split(separator: " ").map(String.init)
                let count = Int(bits.count > 1 ? bits[1] : "10") ?? 10
                let interval = Double(bits.count > 2 ? bits[2] : "0.3") ?? 0.3
                for i in 0..<count {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * interval) {
                        composite(to: "\(bits[0])-\(String(format: "%02d", i)).png", island: controller.panel)
                    }
                }
            case "music": nowPlaying.debugFakeTrack(playing: arg != "paused")
            case "nexttrack": nowPlaying.debugFakeTrack(playing: true, title: "Wait", artist: "M83")
            case "seq":
                // seq <prefix>: 12 frames, 45 ms apart, to inspect an animation in flight.
                for i in 0..<12 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.045) {
                        controller.snapshot(to: "\(arg)-\(String(format: "%02d", i)).png")
                    }
                }
            default: break
            }
        }
    }
}

/// Appends a line to $DOCKY_LOG (debug builds only).
func dockyDebugLog(_ line: String) {
    guard let path = ProcessInfo.processInfo.environment["DOCKY_LOG"], let data = (line + "\n").data(using: .utf8) else { return }
    if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(data); try? h.close() }
    else { FileManager.default.createFile(atPath: path, contents: data) }
}

/// Draws the island, intro overlay and settings windows at their real positions over a
/// stand-in wallpaper, at half resolution.
private func composite(to path: String, island: NSWindow?) {
    guard let screen = island?.screen ?? NSScreen.main else { return }
    let sf = screen.frame
    let scale: CGFloat = 0.5
    let size = NSSize(width: sf.width * scale, height: sf.height * scale)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGradient(colors: [NSColor(srgbRed: 0.18, green: 0.2, blue: 0.36, alpha: 1), NSColor(srgbRed: 0.42, green: 0.28, blue: 0.45, alpha: 1)])!
        .draw(in: NSRect(origin: .zero, size: size), angle: -60)
    NSColor(white: 1, alpha: 0.12).setFill()
    NSRect(x: 0, y: size.height - 30 * scale, width: size.width, height: 30 * scale).fill()
    var windows = DebugHooks.extraWindows()
    if let island { windows.insert(island, at: windows.count > 0 ? windows.count - 1 : 0) }
    windows.sort { $0.level.rawValue < $1.level.rawValue }
    for w in windows where w.isVisible && w.alphaValue > 0.05 {
        guard let img = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(w.windowNumber), [.boundsIgnoreFraming, .bestResolution]) else { continue }
        let f = w.frame.offsetBy(dx: -sf.minX, dy: -sf.minY)
        NSImage(cgImage: img, size: f.size).draw(in: NSRect(x: f.minX * scale, y: f.minY * scale, width: f.width * scale, height: f.height * scale))
    }
    NSGraphicsContext.restoreGraphicsState()
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

extension LockMonitor {
    func debugSet(_ value: String) {
        switch value {
        case "locked": setStateForDebug(.locked)
        case "unlock": setStateForDebug(.locked); didUnlockForDebug()
        default: setStateForDebug(.unlocked)
        }
    }
}

extension IslandWindowController {
    func snapshot(to path: String) {
        guard let panel else { return }
        let id = CGWindowID(panel.windowNumber)
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, id, [.boundsIgnoreFraming, .bestResolution]) else {
            NSLog("Docky debug: snapshot failed")
            return
        }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
#endif
