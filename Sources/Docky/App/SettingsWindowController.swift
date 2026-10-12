import AppKit
import QuartzCore
import SwiftUI

/// Hosts Docky Settings inside the island app so it can open *out of* the island: a
/// snapshot of the window springs from the island's shape to full size (shedding the
/// island's black as it grows), and shrinks back into the island when closed.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    /// Current island frame (screen coordinates) and corner radius, for the return trip.
    var islandFrame: () -> (rect: CGRect, radius: CGFloat) = { (.zero, 0) }

    private var window: SettingsWindow?
    private var overlay: NSWindow?
    private var notifier: SettingsNotifier?
    private let status = IslandStatus(inProcess: true)
    private var previousApp: NSRunningApplication?
    private var closing = false

    var debugWindows: [NSWindow] { [window, overlay].compactMap { $0 } }

    private static let contentSize = NSSize(width: 800, height: 600)

    // MARK: Open

    func show(from origin: CGRect, radius: CGFloat) {
        if let window, window.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        if notifier == nil { notifier = SettingsNotifier() }
        if let front = NSWorkspace.shared.frontmostApplication, front != .current { previousApp = front }

        let screen = NSScreen.screens.first { $0.frame.intersects(origin) } ?? NSScreen.main ?? NSScreen.screens[0]
        let w = makeWindow()
        window = w
        let visible = screen.visibleFrame
        let size = w.frame.size
        let final = NSRect(x: (visible.midX - size.width / 2).rounded(),
                           y: (visible.midY - size.height / 2 + visible.height * 0.04).rounded(),
                           width: size.width, height: size.height)

        NSApp.setActivationPolicy(.regular)
        installMenu()

        // Render the window once off-screen to get a snapshot for the fly-out. Docky must
        // already be active, or Stage Manager tilts the window into its strip first.
        NSApp.activate(ignoringOtherApps: true)
        w.allowsOffscreen = true
        w.setFrame(final.offsetBy(dx: -40_000, dy: 0), display: true)
        w.alphaValue = 1
        w.makeKeyAndOrderFront(nil)
        w.displayIfNeeded()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self, let w = self.window else { return }
            let snapshot = Self.snapshot(of: w)
            w.alphaValue = 0
            w.setFrame(final, display: false)
            w.allowsOffscreen = false
            w.makeKeyAndOrderFront(nil)

            guard let snapshot, origin.width > 0 else {
                w.animator().alphaValue = 1
                return
            }
            self.fly(image: snapshot, from: origin, fromRadius: radius, to: final, toRadius: 16,
                     on: screen, opening: true) {
                w.alphaValue = 1
            }
        }
    }

    private func makeWindow() -> SettingsWindow {
        let hosting = NSHostingController(rootView: SettingsRoot().environmentObject(status))
        hosting.sceneBridgingOptions = [.title, .toolbars]
        let w = SettingsWindow(contentViewController: hosting)
        w.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        w.title = "Docky Settings"
        w.toolbar = NSToolbar(identifier: "DockySettings")
        w.toolbarStyle = .unified
        w.isReleasedWhenClosed = false
        w.animationBehavior = .none
        w.delegate = self
        w.setContentSize(Self.contentSize)
        return w
    }

    // MARK: Close

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closing { return true }
        guard let w = window, let snapshot = Self.snapshot(of: w) else { return true }
        let target = islandFrame()
        guard target.rect.width > 0 else { return true }
        closing = true
        let screen = w.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let from = w.frame
        w.alphaValue = 0
        fly(image: snapshot, from: from, fromRadius: 16, to: target.rect, toRadius: target.radius,
            on: screen, opening: false) { [weak self] in
            w.close()
            self?.closing = false
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        NSApp.setActivationPolicy(.accessory)
        if let previousApp, !previousApp.isTerminated { previousApp.activate() }
        previousApp = nil
    }

    // MARK: Fly animation

    private func fly(image: CGImage, from: CGRect, fromRadius: CGFloat, to: CGRect, toRadius: CGFloat,
                     on screen: NSScreen, opening: Bool, completion: @escaping () -> Void) {
        overlay?.orderOut(nil)
        let ov = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        ov.isOpaque = false
        ov.backgroundColor = .clear
        ov.hasShadow = false
        ov.ignoresMouseEvents = true
        ov.isReleasedWhenClosed = false
        ov.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 4)
        ov.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let root = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        root.wantsLayer = true
        ov.contentView = root
        ov.setFrame(screen.frame, display: false)
        overlay = ov

        let local = { (r: CGRect) in r.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY) }
        let a = local(from), b = local(to)

        let shadow = CALayer()
        shadow.shadowColor = NSColor.black.cgColor
        shadow.shadowOpacity = 0.35
        shadow.shadowRadius = 28
        shadow.shadowOffset = CGSize(width: 0, height: -12)
        let card = CALayer()
        card.contents = image
        card.contentsGravity = .resize
        card.masksToBounds = true
        card.cornerCurve = .continuous
        let ink = CALayer()
        ink.backgroundColor = NSColor.black.cgColor
        ink.frame = CGRect(origin: .zero, size: CGSize(width: max(a.width, b.width), height: max(a.height, b.height)))
        card.addSublayer(ink)
        shadow.addSublayer(card)
        root.layer?.addSublayer(shadow)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in [shadow, card] {
            l.bounds = CGRect(origin: .zero, size: b.size)
            l.position = CGPoint(x: b.midX, y: b.midY)
        }
        card.position = CGPoint(x: b.width / 2, y: b.height / 2)
        card.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        card.cornerRadius = toRadius
        ink.opacity = opening ? 0 : 1
        CATransaction.commit()
        ov.orderFrontRegardless()

        let spring: (String, Any, Any) -> CASpringAnimation = { key, fromValue, toValue in
            let s = CASpringAnimation(keyPath: key)
            s.fromValue = fromValue
            s.toValue = toValue
            s.mass = 1
            s.stiffness = opening ? 190 : 260
            s.damping = opening ? 22 : 30
            s.duration = s.settlingDuration
            return s
        }
        let move = spring("position", NSValue(point: CGPoint(x: a.midX, y: a.midY)), NSValue(point: CGPoint(x: b.midX, y: b.midY)))
        let duration = move.duration

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak ov] in
            completion()
            // Let the real window draw before dropping the stand-in.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                ov?.orderOut(nil)
                if self?.overlay === ov { self?.overlay = nil }
            }
        }
        shadow.add(move, forKey: "move")
        let resize = spring("bounds", NSValue(rect: CGRect(origin: .zero, size: a.size)), NSValue(rect: CGRect(origin: .zero, size: b.size)))
        shadow.add(resize, forKey: "resize")
        card.add(resize, forKey: "resize")
        let recenter = spring("position", NSValue(point: CGPoint(x: a.width / 2, y: a.height / 2)), NSValue(point: CGPoint(x: b.width / 2, y: b.height / 2)))
        card.add(recenter, forKey: "recenter")
        let corner = spring("cornerRadius", fromRadius, toRadius)
        card.add(corner, forKey: "corner")

        // The island's black melts away as the window grows (and floods back on the way home).
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = opening ? 1 : 0
        fade.toValue = opening ? 0 : 1
        fade.beginTime = CACurrentMediaTime() + (opening ? 0.04 : duration * 0.25)
        fade.duration = opening ? 0.32 : min(0.3, duration * 0.5)
        fade.timingFunction = CAMediaTimingFunction(name: opening ? .easeOut : .easeIn)
        fade.fillMode = .both
        ink.add(fade, forKey: "fade")
        let shadowFade = CABasicAnimation(keyPath: "shadowOpacity")
        shadowFade.fromValue = opening ? 0 : 0.35
        shadowFade.toValue = opening ? 0.35 : 0
        shadowFade.duration = duration * 0.6
        shadow.add(shadowFade, forKey: "shadow")
        CATransaction.commit()
    }

    private static func snapshot(of window: NSWindow) -> CGImage? {
        CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                [.boundsIgnoreFraming, .bestResolution])
    }

    // MARK: Menu (only visible while Settings makes Docky a regular app)

    private func installMenu() {
        guard NSApp.mainMenu == nil || NSApp.mainMenu?.items.isEmpty == true else { return }
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Hide Docky", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Docky", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }
}

final class SettingsWindow: NSWindow {
    var allowsOffscreen = false

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        allowsOffscreen ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }
}
