import AppKit
import Combine
import SwiftUI

/// Borderless, transparent, non-activating panel pinned to the top of the screen.
final class IslandPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Hosting view that takes clicks without a prior "activation" click and reports
/// mouse movement even while Docky isn't the active app.
final class IslandHostingView: NSHostingView<AnyView> {
    var onMouseMoved: (() -> Void)?
    private var trackingArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onMouseMoved?()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onMouseMoved?()
    }
}

/// An NSView that only participates in hit-testing for scroll-wheel events. SwiftUI clicks
/// and drags pass straight through it, while scrolls (used by the time dials) land on it.
final class ScrollCatcherNSView: NSView {
    static var probing = false
    var onScroll: ((CGFloat) -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        let isScroll = Self.probing || NSApp.currentEvent?.type == .scrollWheel
        return isScroll ? super.hitTest(point) : nil
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.momentumPhase == [] else { return }
        var dy = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 12)
        if !event.isDirectionInvertedFromDevice { dy = -dy }
        onScroll?(dy) // > 0 means fingers moved down
    }
}

struct ScrollCatcher: NSViewRepresentable {
    var onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> ScrollCatcherNSView {
        let v = ScrollCatcherNSView()
        v.onScroll = onScroll
        return v
    }

    func updateNSView(_ view: ScrollCatcherNSView, context: Context) {
        view.onScroll = onScroll
    }
}

final class IslandWindowController: NSObject, NSSharingServicePickerDelegate {
    let model: IslandModel
    private(set) var panel: IslandPanel?
    private var host: IslandHostingView?
    private var monitors: [Any] = []
    private var cancellables = Set<AnyCancellable>()
    private var pollTimer: Timer?
    private var previousApp: NSRunningApplication?
    private var fullscreenTimer: Timer?
    private var keepFocusAfterEditing = false
    private(set) var currentScreen: NSScreen?

    // Swipe tracking
    private var scrollAccumulator: CGFloat = 0
    private var horizontalAccumulator: CGFloat = 0
    private var scrollAxis: ScrollAxis?
    private var gestureConsumed = false
    private var lastScrollTime: TimeInterval = 0
    private let swipeThreshold: CGFloat = 26

    init(model: IslandModel) {
        self.model = model
        super.init()
    }

    func show() {
        buildPanel()
        installMonitors()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.rebuild()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            self?.reposition()
        }

        // Geometry-affecting preferences need a fresh window.
        model.prefs.$values
            .map { [$0.style.rawValue, $0.display.rawValue, "\($0.lockScreenEnabled)"] }
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &cancellables)
        // Size only changes the island's measurements; the window stays put.
        model.prefs.$values
            .map(\.islandScale)
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, let screen = self.currentScreen else { return }
                self.model.updateMetrics(for: screen)
            }
            .store(in: &cancellables)

        // Re-evaluate hover whenever the island changes shape under a still cursor.
        model.$layout
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateMouse() }
            .store(in: &cancellables)

        model.onBeginEditing = { [weak self] in self?.beginKeyboardFocus() }
        model.onEndEditing = { [weak self] in self?.endKeyboardFocus() }
        model.onShare = { [weak self] urls, rect in self?.showSharePicker(urls, from: rect) }

        startFullscreenMonitoring()
    }

    /// The island's current frame in screen coordinates.
    func islandScreenRect() -> CGRect {
        guard let panel else { return .zero }
        let size = model.layout.size
        let f = panel.frame
        let top = f.maxY - model.metrics.topOffset
        return CGRect(x: f.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height)
    }

    // MARK: Fullscreen apps

    private func startFullscreenMonitoring() {
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.checkFullscreen()
                // Entering fullscreen animates; look again once the space has settled.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { self?.checkFullscreen() }
            }
        }
        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in self?.checkFullscreen() }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        fullscreenTimer = t
        checkFullscreen()
    }

    private func checkFullscreen() {
        guard model.p.hideInFullscreen, let screen = currentScreen else {
            if model.fullscreenActive { model.fullscreenActive = false }
            return
        }
        let active = Self.frontmostAppIsFullscreen(on: screen)
        if active != model.fullscreenActive { model.fullscreenActive = active }
    }

    /// True when the frontmost app has a window covering the whole display — a fullscreen
    /// app, video or game. Window bounds are readable without Screen Recording permission.
    static func frontmostAppIsFullscreen(on screen: NSScreen) -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let f = screen.frame
        let target = CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height)
        for w in windows {
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == front.processIdentifier,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: dict)
            else { continue }
            if abs(r.minX - target.minX) < 1, abs(r.minY - target.minY) < 1,
               abs(r.width - target.width) < 1, abs(r.height - target.height) < 1 {
                return true
            }
        }
        return false
    }

    // MARK: Sharing

    private func showSharePicker(_ urls: [URL], from rect: CGRect) {
        guard let host else { return }
        var r = rect == .zero ? CGRect(x: host.bounds.midX - 20, y: 60, width: 40, height: 40) : rect
        if !host.isFlipped { r.origin.y = host.bounds.height - r.maxY }
        let picker = NSSharingServicePicker(items: urls)
        picker.delegate = self
        model.isEditing = true // keeps the island open and Docky focused while the menu is up
        DispatchQueue.main.async {
            picker.show(relativeTo: r, of: host, preferredEdge: .minY)
        }
    }

    func sharingServicePicker(_ picker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        // When a service was picked its window (AirDrop, Messages…) needs to stay in front.
        keepFocusAfterEditing = service != nil
        model.isEditing = false
        keepFocusAfterEditing = false
    }

    private func targetScreen() -> NSScreen {
        let screens = NSScreen.screens
        switch model.p.display {
        case .builtIn:
            if let builtIn = screens.first(where: { screen in
                guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
                return CGDisplayIsBuiltin(id.uint32Value) != 0
            }) { return builtIn }
            return screens.first ?? NSScreen.main!
        case .main:
            return screens.first ?? NSScreen.main!
        }
    }

    private func frame(for screen: NSScreen) -> NSRect {
        let size = model.metrics.windowSize
        return NSRect(x: (screen.frame.midX - size.width / 2).rounded(),
                      y: screen.frame.maxY - size.height,
                      width: size.width, height: size.height)
    }

    private func buildPanel() {
        let screen = targetScreen()
        currentScreen = screen
        model.updateMetrics(for: screen)
        let frame = frame(for: screen)

        let panel = IslandPanel(contentRect: frame)
        let root = IslandRootView()
            .environmentObject(model)
            .environmentObject(model.prefs)
            .environmentObject(model.nowPlaying)
            .environmentObject(model.clock)
            .environmentObject(model.clipboard)
            .environmentObject(model.calendar)
        let host = IslandHostingView(rootView: AnyView(root))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: frame.size)
        host.autoresizingMask = [.width, .height]
        host.onMouseMoved = { [weak self] in self?.updateMouse() }
        panel.contentView = host
        panel.setFrame(frame, display: false)
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()

        if model.p.lockScreenEnabled {
            SkyLightSpace.shared.adopt(panel)
        }

        self.panel = panel
        self.host = host
    }

    func rebuild() {
        let old = panel
        buildPanel()
        old?.orderOut(nil)
        old?.close()
    }

    private func reposition() {
        guard let panel else { return }
        let screen = targetScreen()
        currentScreen = screen
        model.updateMetrics(for: screen)
        panel.setFrame(frame(for: screen), display: true)
    }

    // MARK: Event monitors

    private func installMonitors() {
        let moveMask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .leftMouseUp]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: moveMask, handler: { [weak self] _ in self?.updateMouse() }) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: moveMask, handler: { [weak self] e in self?.updateMouse(); return e }) {
            monitors.append(m)
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] e in
            self?.model.clickedOutside()
            if e.type == .leftMouseDown { self?.startPressPolling() }
        }) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] e in
            self?.handleScroll(e) ?? e
        }) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            if e.keyCode == 53, let self, self.model.isExpanded { // Escape
                self.model.collapse()
                return nil
            }
            return e
        }) {
            monitors.append(m)
        }
    }

    /// Maps the cursor into the panel and toggles click-through so only the island itself
    /// intercepts the mouse; the rest of the (transparent) window lets clicks fall through.
    private func updateMouse() {
        guard let panel else { return }
        #if DOCKY_DEBUG
        if DebugHooks.freezeMouse { panel.ignoresMouseEvents = true; return }
        #endif
        let loc = NSEvent.mouseLocation
        let f = panel.frame
        let point = CGPoint(x: loc.x - f.minX, y: f.maxY - loc.y)
        var inside = f.insetBy(dx: -2, dy: -2).contains(loc) && model.hitTest(point)
        // Mid-drag on the island (a slider, a file, a swipe), keep hold of the pointer even if
        // it wanders off the island until the button is released.
        if !inside && !panel.ignoresMouseEvents && NSEvent.pressedMouseButtons & 1 != 0 { inside = true }
        if panel.ignoresMouseEvents == inside {
            panel.ignoresMouseEvents = !inside
        }
        model.setHovering(inside)
        updatePolling()
    }

    /// While the cursor is over the island we poll a little, to catch exits that skip events
    /// (e.g. the cursor jumping between displays).
    /// While a mouse button is held anywhere (e.g. dragging a file out of Finder), keep checking
    /// where the pointer is. Other apps' drag sessions don't reliably report pointer movement,
    /// and the island has to stop ignoring the mouse before macOS will offer it the drop.
    private var pressTimer: Timer?

    private func startPressPolling() {
        guard pressTimer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.updateMouse()
            if NSEvent.pressedMouseButtons & 1 == 0 {
                timer.invalidate()
                self.pressTimer = nil
                // Re-evaluate once more now that the button is up.
                DispatchQueue.main.async { self.updateMouse() }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        pressTimer = t
    }

    private func updatePolling() {
        let needsPolling = model.isHovering || model.isExpanded
        if needsPolling, pollTimer == nil {
            let t = Timer(timeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in self?.updateMouse() }
            RunLoop.main.add(t, forMode: .common)
            pollTimer = t
        } else if !needsPolling, let t = pollTimer {
            t.invalidate()
            pollTimer = nil
        }
    }

    // MARK: Swipe gestures

    private enum ScrollAxis { case horizontal, vertical }

    private func handleScroll(_ e: NSEvent) -> NSEvent? {
        guard let panel, e.window === panel else { return e }
        if model.isExpanded, isOverScrollableContent(e) { return e }

        let precise = e.hasPreciseScrollingDeltas
        // Finger movement, whatever the scroll-direction setting: dx > 0 right, dy > 0 down.
        var fx = e.scrollingDeltaX * (precise ? 1 : 10)
        var fy = e.scrollingDeltaY * (precise ? 1 : 10)
        if !e.isDirectionInvertedFromDevice { fx = -fx; fy = -fy }

        // A volume / brightness indicator under the pointer: scrolling moves its slider.
        if model.isLevelHUD {
            guard e.momentumPhase == [] else { return nil }
            model.cancelPendingHoverExpand()
            model.adjustHUDLevel(by: Double(fx - fy) / 260)
            return nil
        }

        let now = ProcessInfo.processInfo.systemUptime
        let isTrackpad = e.phase != [] || e.momentumPhase != []
        if e.phase == .began || (!isTrackpad && now - lastScrollTime > 0.35) {
            resetScrollGesture()
        }
        lastScrollTime = now

        if e.momentumPhase != [] { return model.isExpanded ? e : nil }
        if e.phase == .ended || e.phase == .cancelled {
            resetScrollGesture()
            return nil
        }
        if gestureConsumed { return nil }

        scrollAccumulator += fy
        horizontalAccumulator += fx
        if scrollAxis == nil, hypot(scrollAccumulator, horizontalAccumulator) > 6 {
            scrollAxis = abs(horizontalAccumulator) > abs(scrollAccumulator) ? .horizontal : .vertical
            model.cancelPendingHoverExpand()
        }

        if model.isExpanded {
            if scrollAxis == .vertical, model.p.swipeToExpand, scrollAccumulator <= -swipeThreshold * 1.3 {
                gestureConsumed = true
                model.collapse()
            }
            return nil
        }

        switch scrollAxis {
        case .vertical where scrollAccumulator > 0:
            // Swipe down: open the island.
            guard model.p.swipeToExpand, model.canExpand else { return nil }
            model.setSwipeStretch(scrollAccumulator / (swipeThreshold * 2.2))
            if scrollAccumulator >= swipeThreshold {
                gestureConsumed = true
                model.expand(haptic: true)
            }
        case .vertical:
            // Swipe up on the break card: put it (and the glow) away.
            if model.layout.presentation == .breakTime {
                if scrollAccumulator <= -swipeThreshold {
                    gestureConsumed = true
                    model.dismissBreakMoment()
                }
                return nil
            }
            // Swipe up from below: tuck Now Playing away.
            guard model.canRetractMusic else { return nil }
            model.setDragStretch(scrollAccumulator / (swipeThreshold * 2.4))
            if scrollAccumulator <= -swipeThreshold * 1.2 {
                gestureConsumed = true
                model.retractMusic()
            }
        case .horizontal:
            // Toward the middle tucks Now Playing away; away from it brings it back.
            let side: CGFloat = NSEvent.mouseLocation.x >= panel.frame.midX ? 1 : -1
            let outward = side * horizontalAccumulator
            if model.canRetractMusic {
                model.setDragStretch(max(-1, min(0.35, outward / (swipeThreshold * 2.4))))
                if outward <= -swipeThreshold * 1.4 {
                    gestureConsumed = true
                    model.retractMusic()
                }
            } else if model.canRestoreMusic {
                model.setDragStretch(max(-0.35, min(1, outward / (swipeThreshold * 2.4))))
                if outward >= swipeThreshold * 1.4 {
                    gestureConsumed = true
                    model.restoreMusic()
                }
            }
        case nil:
            break
        }
        return nil
    }

    private func resetScrollGesture() {
        scrollAccumulator = 0
        horizontalAccumulator = 0
        scrollAxis = nil
        gestureConsumed = false
        model.setSwipeStretch(0)
        model.setDragStretch(0)
    }

    /// True when the cursor is over a time dial or a list that can actually scroll.
    private func isOverScrollableContent(_ e: NSEvent) -> Bool {
        guard let host, let frameView = host.superview else { return false }
        ScrollCatcherNSView.probing = true
        defer { ScrollCatcherNSView.probing = false }
        let point = frameView.convert(e.locationInWindow, from: nil)
        guard let hit = host.hitTest(point) else { return false }
        if hit is ScrollCatcherNSView { return true }
        var scrollView: NSScrollView? = hit as? NSScrollView ?? hit.enclosingScrollView
        if scrollView == nil {
            var v: NSView? = hit
            while let current = v, scrollView == nil {
                scrollView = current as? NSScrollView
                v = current.superview
            }
        }
        guard let sv = scrollView, let doc = sv.documentView else { return false }
        return doc.frame.height > sv.contentView.bounds.height + 1
    }

    // MARK: Keyboard focus for text entry

    private func beginKeyboardFocus() {
        guard let panel else { return }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = NSWorkspace.shared.frontmostApplication
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKey()
    }

    private func endKeyboardFocus() {
        guard let panel else { return }
        panel.makeFirstResponder(nil)
        if NSApp.isActive && !keepFocusAfterEditing {
            if let previousApp, !previousApp.isTerminated {
                previousApp.activate()
            } else {
                NSApp.deactivate()
            }
        }
        previousApp = nil
    }
}
