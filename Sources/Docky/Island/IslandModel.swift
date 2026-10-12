import AppKit
import Combine
import SwiftUI

enum IslandTab: String, CaseIterable, Identifiable {
    case nowPlaying, timers, reminders, calendar, clipboard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nowPlaying: return "Now Playing"
        case .timers: return "Timers"
        case .reminders: return "Reminders & Alarms"
        case .clipboard: return "Clipboard"
        case .calendar: return "Calendar"
        }
    }

    var symbol: String {
        switch self {
        case .nowPlaying: return "music.note"
        case .timers: return "timer"
        case .reminders: return "alarm.fill"
        case .clipboard: return "doc.on.clipboard"
        case .calendar: return "calendar"
        }
    }
}

enum IslandPresentation: Equatable {
    case hidden
    case idle
    case lock(unlocked: Bool)
    case music
    case timer
    case peek
    case expanded(IslandTab)
    case alert(String)
    case hud(HUDEvent.Kind)
    case notice(String)
    case pomodoro
    case breakTime
    case onboarding(Int)
    case onboardingDemo

    var isCompact: Bool {
        switch self {
        case .hidden, .idle, .lock, .music, .timer, .hud, .pomodoro, .onboardingDemo: return true
        default: return false
        }
    }
}

/// Screen-dependent geometry.
struct IslandMetrics: Equatable {
    var hasNotch = false
    var notchWidth: CGFloat = 0
    /// Height of the compact island (the notch height in notch style).
    var band: CGFloat = 26
    var topOffset: CGFloat = 2
    var scale: CGFloat = 1
    var windowSize = CGSize(width: 720, height: 420)
    var flare: CGFloat { hasNotch ? 7 : 0 }
    /// Breathing room between compact content and the island's edge (vertical); the
    /// horizontal inset adds a little more so content clears the capsule's curve.
    var compactInset: CGFloat { (band * 0.22).rounded() }
    var compactSideInset: CGFloat { compactInset + 5 }
    var bubbleGap: CGFloat { 7 * scale }
}

/// Everything the views need to draw one frame of the island. Animating on this value is
/// what makes every morph spring together.
struct IslandLayout: Equatable {
    var presentation: IslandPresentation = .idle
    var size = CGSize(width: 120, height: 26)
    var bottomRadius: CGFloat = 13
    var topRadius: CGFloat = 13
    var showsBubble = false
    var bubbleSize: CGFloat = 26
    var shadow: Double = 0
    var hovering = false
}

final class IslandModel: ObservableObject {
    let prefs: PreferencesStore
    let nowPlaying: NowPlayingService
    let clock: ClockStore
    let lock: LockMonitor
    let clipboard: ClipboardStore
    let calendar: CalendarStore

    @Published private(set) var metrics = IslandMetrics()
    @Published private(set) var layout = IslandLayout()
    @Published var tab: IslandTab = .nowPlaying {
        didSet { if oldValue != tab { recompute() } }
    }
    @Published private(set) var isHovering = false
    @Published private(set) var isExpanded = false
    @Published private(set) var peeking = false
    @Published private(set) var swipeStretch: CGFloat = 0
    /// True while a text field inside the island is being edited; blocks auto-collapse.
    @Published var isEditing = false {
        didSet {
            guard oldValue != isEditing else { return }
            if isEditing { onBeginEditing?() } else { onEndEditing?() }
            if !isEditing && !isHovering && isExpanded { scheduleCollapse() }
        }
    }
    /// Whether the Timers tab shows the composer (affects the island's height).
    @Published var timerComposerOpen = false {
        didSet { if oldValue != timerComposerOpen { recompute() } }
    }
    /// A fullscreen app is frontmost on the island's display.
    @Published var fullscreenActive = false {
        didSet { if oldValue != fullscreenActive { recompute() } }
    }
    /// A card asking for something (e.g. Accessibility access), with one action.
    struct Notice: Equatable {
        var id: String
        var symbol: String
        var title: String
        var message: String
        var actionTitle: String
        /// When set, the card shows a switch for this preference instead of a button.
        var toggleKey: String? = nil
        var toggleLabel: String? = nil
    }
    @Published private(set) var notice: Notice?
    private var noticeAction: (() -> Void)?
    private var noticeDismiss: (() -> Void)?

    /// A system indicator (volume, brightness, Focus, device, charging) currently showing.
    @Published private(set) var hud: HUDEvent?
    private var hudWork: DispatchWorkItem?
    /// True while the pointer is dragging a level (volume/brightness) slider.
    private(set) var isAdjustingLevel = false
    /// Asks the system to set volume or brightness (0…1).
    var onAdjustLevel: ((HUDEvent.Kind, Double) -> Void)?

    /// Setup walkthrough, shown inside the island itself. nil when not onboarding.
    @Published private(set) var onboardingStep: Int?
    /// The island briefly shrinks to its compact look to demonstrate a choice.
    @Published private(set) var onboardingDemo = false
    private var demoWork: DispatchWorkItem?
    var onOnboardingFinished: (() -> Void)?
    /// Permission states reported by the app ("ax", "cal", "focus" → 0 no, 1 yes, 2 denied).
    @Published var permissions: [String: Int] = [:]
    static let onboardingStepCount = 7

    /// "Time for a break" card (and the warm screen glow) after a focus session.
    @Published private(set) var breakCardActive = false
    var onBreakGlow: ((Bool) -> Void)?
    /// Timers tab: plain timers or Pomodoro.
    @Published var timersMode: TimersMode = .timers {
        didSet { if oldValue != timersMode { recompute() } }
    }
    enum TimersMode: String { case timers, pomodoro }

    /// Now Playing tucked away by swiping it inward; swiping outward brings it back.
    @Published private(set) var musicRetracted = false
    /// Live feedback while a sideways/upward gesture is in progress: < 0 squeezes the island
    /// inward, > 0 stretches it outward.
    @Published private(set) var dragStretch: CGFloat = 0

    /// Intro: the island waits above the screen edge, then drops in glowing.
    @Published var introHidden = false
    @Published var introGlow = false {
        didSet { if oldValue != introGlow { recompute() } }
    }
    /// Something is being dragged over the island (files heading for the Clipboard).
    @Published private(set) var dropTargeted = false
    /// Bumped when the island wants a composer to open (e.g. "New Reminder" from the menu bar).
    @Published var composeRequest: (tab: IslandTab, token: Int)?

    var onBeginEditing: (() -> Void)?
    var onEndEditing: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onShare: (([URL], CGRect) -> Void)?

    private var cancellables = Set<AnyCancellable>()
    private var hoverWork: DispatchWorkItem?
    private var collapseWork: DispatchWorkItem?
    private var peekWork: DispatchWorkItem?
    private var lingerWork: DispatchWorkItem?
    private var lastScreen: NSScreen?

    init(prefs: PreferencesStore, nowPlaying: NowPlayingService, clock: ClockStore, lock: LockMonitor, clipboard: ClipboardStore, calendar: CalendarStore) {
        self.prefs = prefs
        self.nowPlaying = nowPlaying
        self.clock = clock
        self.lock = lock
        self.clipboard = clipboard
        self.calendar = calendar

        nowPlaying.filter = { [weak prefs] info in
            guard let prefs, prefs.values.musicOnly else { return true }
            return MusicClassifier.isMusic(bundleID: info.bundleID, duration: info.duration)
        }
        nowPlaying.pauseOthersWhenSwitching = { [weak prefs] in prefs?.values.autoPauseOthers ?? false }
        prefs.$values
            .map(\.musicOnly)
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak nowPlaying] _ in nowPlaying?.refilter() }
            .store(in: &cancellables)

        let triggers: [AnyPublisher<Void, Never>] = [
            nowPlaying.$info.map { _ in () }.eraseToAnyPublisher(),
            nowPlaying.$pausedAt.map { _ in () }.eraseToAnyPublisher(),
            clock.$alerts.map { _ in () }.eraseToAnyPublisher(),
            clock.$timers.map { _ in () }.eraseToAnyPublisher(),
            clock.$pomodoro.map { _ in () }.eraseToAnyPublisher(),
            clock.$pomodoroConfig.map { _ in () }.eraseToAnyPublisher(),
            lock.$state.map { _ in () }.eraseToAnyPublisher(),
            prefs.$values.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(triggers)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.recompute() }
            .store(in: &cancellables)

        nowPlaying.$trackChangeCount
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.trackChanged() }
            .store(in: &cancellables)

        nowPlaying.$pausedAt
            .receive(on: DispatchQueue.main)
            .sink { [weak self] date in self?.scheduleLingerCheck(pausedAt: date) }
            .store(in: &cancellables)

        clock.$breakStartedCount
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.startBreakMoment() }
            .store(in: &cancellables)

        // The break moment ends with the break (or when the Pomodoro is stopped/skipped).
        clock.$pomodoro
            .receive(on: DispatchQueue.main)
            .sink { [weak self] session in
                guard let self, self.breakCardActive, session?.phase != .rest else { return }
                self.endBreakMoment()
            }
            .store(in: &cancellables)

        lock.$state
            .filter { $0 == .locked }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.collapse() }
            .store(in: &cancellables)

        clock.$alerts
            .map(\.isEmpty)
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] empty in
                guard let self, empty, !self.isHovering, self.isExpanded, !self.isEditing else { return }
                self.collapse()
            }
            .store(in: &cancellables)
    }

    var p: DockyPrefs { prefs.values }

    var spring: Animation {
        .spring(response: p.animationFeel.response, dampingFraction: p.animationFeel.damping)
    }

    // MARK: Metrics

    func updateMetrics(for screen: NSScreen) {
        lastScreen = screen
        let scale = CGFloat(p.islandScale)
        let hardwareNotch = screen.safeAreaInsets.top > 0 && screen.auxiliaryTopLeftArea != nil
        let useNotch = p.style == .notch || (p.style == .automatic && hardwareNotch)
        var menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        if menuBar < 20 { menuBar = max(24, NSStatusBar.system.thickness) }

        var m = IslandMetrics()
        m.scale = scale
        m.hasNotch = useNotch
        if useNotch {
            if hardwareNotch, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
                m.notchWidth = screen.frame.width - left.width - right.width
                m.band = screen.safeAreaInsets.top
            } else {
                m.notchWidth = 190 * scale
                m.band = menuBar
            }
            m.topOffset = 0
        } else {
            m.band = FloatingGeometry.height * scale
            m.topOffset = FloatingGeometry.topOffset
        }
        m.windowSize = CGSize(width: max(720, m.notchWidth + 460), height: 420)
        metrics = m
        recompute()
    }

    // MARK: State

    private var musicActive: Bool {
        guard p.nowPlayingEnabled, let info = nowPlaying.info, info.hasContent else { return false }
        if info.isPlaying { return true }
        guard let paused = nowPlaying.pausedAt else { return false }
        return Date().timeIntervalSince(paused) < p.pausedLinger
    }

    private func currentPresentation() -> IslandPresentation {
        if p.lockScreenEnabled {
            switch lock.state {
            case .locked: return .lock(unlocked: false)
            case .unlocking: return .lock(unlocked: true)
            case .unlocked: break
            }
        }
        if let alert = clock.alerts.first { return .alert(alert.id) }
        if let notice { return .notice(notice.id) }
        if let step = onboardingStep { return onboardingDemo ? .onboardingDemo : .onboarding(step) }
        if breakCardActive { return .breakTime }
        if isExpanded { return .expanded(tab) }
        if let hud { return .hud(hud.kind) }
        // Out of the way in fullscreen apps until the pointer visits the top of the screen.
        if fullscreenActive && p.hideInFullscreen && !isHovering && !dropTargeted && !introGlow { return .hidden }
        if peeking && musicActive && p.compactShowsTitle && !musicRetracted { return .peek }
        if musicActive && !musicRetracted { return .music }
        if clock.pomodoro != nil { return .pomodoro }
        if clock.activeTimer != nil { return .timer }
        return p.hideWhenIdle && !isHovering && !introGlow && !dropTargeted ? .hidden : .idle
    }

    func recompute() {
        // A tucked-away Now Playing comes back by itself next time something starts playing.
        if musicRetracted && !musicActive { musicRetracted = false }
        let presentation = currentPresentation()
        let m = metrics
        let s = m.scale
        let H = m.band
        let notch = m.hasNotch
        let wing = max(H + 8, 42 * s)

        var size: CGSize
        switch presentation {
        case .hidden, .idle:
            size = notch ? CGSize(width: m.notchWidth, height: H) : CGSize(width: FloatingGeometry.idleWidth * s, height: H)
        case .lock:
            size = notch ? CGSize(width: m.notchWidth + wing * 1.4, height: H) : CGSize(width: FloatingGeometry.lockWidth * s, height: H)
        case .music:
            size = notch
                ? CGSize(width: m.notchWidth + wing * 2, height: H)
                : CGSize(width: (p.compactShowsTitle ? FloatingGeometry.musicWidth : FloatingGeometry.musicWidthNoTitle) * s, height: H)
        case .timer:
            size = notch ? CGSize(width: m.notchWidth + wing * 2 + 22, height: H) : CGSize(width: FloatingGeometry.timerWidth * s, height: H)
        case .peek:
            size = notch ? CGSize(width: max(m.notchWidth + 190, 400), height: H + 64) : FloatingGeometry.peekSize
        case .expanded(let tab):
            let width = notch ? max(500, m.notchWidth + 330) : FloatingGeometry.expandedWidth
            size = CGSize(width: width, height: headerHeight + contentHeight(for: tab) + expandedBottomInset)
        case .hud(let kind):
            let level = kind == .volume || kind == .brightness
            size = notch
                ? CGSize(width: m.notchWidth + (level ? 220 : 260), height: H)
                : CGSize(width: (level ? 268 : 312) * s, height: H)
        case .onboarding(let step):
            let heights: [CGFloat] = [214, 250, 232, 236, 262, 280, 262]
            let width = notch ? max(580, m.notchWidth + 360) : 580
            size = CGSize(width: width, height: (notch ? m.band : 0) + heights[min(step, heights.count - 1)])
        case .onboardingDemo:
            size = notch
                ? CGSize(width: m.notchWidth + wing * 2, height: H)
                : CGSize(width: (p.compactShowsTitle ? FloatingGeometry.musicWidth : FloatingGeometry.musicWidthNoTitle) * s, height: H)
        case .pomodoro:
            size = notch ? CGSize(width: m.notchWidth + wing * 2 + 22, height: H) : CGSize(width: FloatingGeometry.timerWidth * s, height: H)
        case .breakTime:
            size = notch ? CGSize(width: max(m.notchWidth + 220, 460), height: H + 96) : CGSize(width: 440, height: 104)
        case .notice:
            let wide: CGFloat = notice?.toggleKey != nil ? 40 : 0
            size = notch ? CGSize(width: max(m.notchWidth + 220, 460) + wide, height: H + 96) : CGSize(width: 440 + wide, height: 104)
        case .alert:
            size = notch ? CGSize(width: max(m.notchWidth + 200, 440), height: H + 86) : FloatingGeometry.alertSize
        }

        let growable = presentation.isCompact && presentation != .lock(unlocked: false) && presentation != .lock(unlocked: true)
        if isHovering && growable && p.hoverGrow {
            size.width += (notch ? 18 : 10) * s
            size.height += notch ? 5 : 3 * s
        }
        if growable && swipeStretch > 0 {
            size.width += 12 * swipeStretch
            size.height += 12 * swipeStretch
        }
        if growable && dragStretch != 0 {
            // Squeeze toward the middle when pushed inward, stretch when pulled outward.
            size.width += 26 * dragStretch
            size.height -= 3 * min(0, dragStretch) * -1
        }

        var layout = IslandLayout()
        layout.presentation = presentation
        layout.size = CGSize(width: size.width.rounded(), height: size.height.rounded())
        layout.hovering = isHovering
        switch presentation {
        case .expanded: layout.bottomRadius = notch ? 30 : 34
        case .alert, .notice, .breakTime: layout.bottomRadius = notch ? 28 : 34
        case .onboarding: layout.bottomRadius = notch ? 32 : 38
        case .peek: layout.bottomRadius = notch ? 24 : 26
        default: layout.bottomRadius = notch ? min(14, size.height * 0.36) : size.height / 2
        }
        layout.topRadius = notch ? 0 : layout.bottomRadius
        layout.shadow = presentation.isCompact ? 0 : 0.5
        layout.bubbleSize = H
        layout.showsBubble = presentation == .music && p.showTimerBubble && (clock.activeTimer != nil || clock.pomodoro != nil)

        if layout != self.layout { self.layout = layout }
    }

    // Expanded layout: content sits on an even inset so its corners stay concentric with the island's.
    var expandedTopInset: CGFloat { metrics.hasNotch ? 0 : 16 }
    var expandedSideInset: CGFloat { 22 }
    var expandedBottomInset: CGFloat { 20 }
    var headerRowHeight: CGFloat { metrics.hasNotch ? metrics.band : 31 }
    var headerHeight: CGFloat { expandedTopInset + headerRowHeight + 14 }

    func contentHeight(for tab: IslandTab) -> CGFloat {
        switch tab {
        case .nowPlaying: return 150
        case .timers:
            let modeBar: CGFloat = 38
            if timersMode == .pomodoro { return modeBar + (clock.pomodoro == nil ? 112 : 70) }
            if clock.timers.isEmpty || timerComposerOpen { return modeBar + 118 }
            return modeBar + CGFloat(min(clock.timers.count, 3)) * TimerRow.pitch + 34
        case .reminders: return 204
        case .calendar: return 204
        case .clipboard: return 136
        }
    }

    // MARK: Hit testing (window coordinates, origin top-left)

    func hitTest(_ point: CGPoint) -> Bool {
        let window = metrics.windowSize
        let size = layout.size
        let dragging = NSEvent.pressedMouseButtons & 1 != 0
        let margin: CGFloat = dragging ? 18 : (isHovering ? 10 : 2)
        let x = (window.width - size.width) / 2
        // Extend to the very top of the screen so slamming the cursor upward still counts.
        var rects = [CGRect(x: x, y: 0, width: size.width, height: metrics.topOffset + size.height)]
        if layout.presentation == .hidden {
            // A hidden island is woken by a generous strip along the top edge.
            rects = [CGRect(x: x - 60, y: 0, width: size.width + 120, height: metrics.topOffset + size.height)]
        }
        if layout.showsBubble {
            rects.append(CGRect(x: x + size.width + metrics.bubbleGap, y: 0,
                                width: layout.bubbleSize, height: metrics.topOffset + layout.bubbleSize))
        }
        return rects.contains { $0.insetBy(dx: -margin, dy: -margin).contains(point) }
    }

    // MARK: Interaction

    func setHovering(_ hovering: Bool) {
        guard hovering != isHovering else { return }
        isHovering = hovering
        hoverWork?.cancel()
        collapseWork?.cancel()
        if hovering {
            // Holding the pointer over an indicator keeps it up (and lets you drag its slider).
            if hud != nil { hudWork?.cancel() }
            if p.hoverToExpand && !isExpanded && canExpand && hud == nil {
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.isHovering else { return }
                    self.expand(haptic: true)
                }
                hoverWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + p.hoverDelay, execute: work)
            }
        } else {
            swipeStretch = 0
            if isExpanded && !isEditing { scheduleCollapse() }
            if hud != nil && !isAdjustingLevel { scheduleHUDDismissal(after: 0.9) }
        }
        recompute()
    }

    /// Cancels a pending hover-to-expand (a gesture is starting instead).
    func cancelPendingHoverExpand() {
        hoverWork?.cancel()
    }

    private func scheduleCollapse() {
        collapseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isHovering, !self.isEditing else { return }
            // Never pull the island out from under a drag (dragging a file in or out of it).
            if NSEvent.pressedMouseButtons & 1 != 0 {
                self.scheduleCollapse()
                return
            }
            self.collapse()
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + p.collapseDelay, execute: work)
    }

    var canExpand: Bool {
        switch layout.presentation {
        case .lock, .alert, .notice, .breakTime, .onboarding, .onboardingDemo: return false
        default: return true
        }
    }

    func expand(tab: IslandTab? = nil, haptic: Bool = false) {
        guard canExpand else { return }
        if let tab {
            self.tab = tab
        } else {
            switch layout.presentation {
            case .timer: self.tab = .timers
            case .music, .peek: self.tab = .nowPlaying
            default: break
            }
        }
        peeking = false
        swipeStretch = 0
        guard !isExpanded else { recompute(); return }
        isExpanded = true
        if haptic { performHaptic() }
        recompute()
    }

    func collapse() {
        collapseWork?.cancel()
        guard isExpanded || isEditing else { return }
        isEditing = false
        isExpanded = false
        timerComposerOpen = false
        recompute()
    }

    func toggleExpanded() {
        isExpanded ? collapse() : expand(haptic: false)
    }

    func islandClicked() {
        if onboardingStep != nil { return }
        if isLevelHUD { return } // clicks on a volume/brightness indicator belong to its slider
        guard p.clickToExpand, !isExpanded else { return }
        expand()
    }

    func clickedOutside() {
        if isExpanded { collapse() }
    }

    func setSwipeStretch(_ value: CGFloat) {
        let v = min(1, max(0, value))
        guard abs(v - swipeStretch) > 0.01 || v == 0 else { return }
        swipeStretch = v
        recompute()
    }

    func performHaptic() {
        guard p.haptics else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    func preview() {
        expand(tab: musicActive ? .nowPlaying : tab)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, !self.isHovering, !self.isEditing else { return }
            self.collapse()
        }
    }

    func requestCompose(_ tab: IslandTab) {
        expand(tab: tab)
        composeRequest = (tab, (composeRequest?.token ?? 0) + 1)
    }

    func openSettings() {
        onOpenSettings?()
        collapse()
    }

    /// Tabs shown in the switcher.
    var visibleTabs: [IslandTab] {
        IslandTab.allCases.filter { $0 != .calendar || p.showCalendar }
    }

    // MARK: Notices

    func showNotice(_ notice: Notice, action: @escaping () -> Void, dismiss: (() -> Void)? = nil) {
        noticeAction = action
        noticeDismiss = dismiss
        self.notice = notice
        recompute()
    }

    /// Removes a notice without running either of its actions (e.g. the permission arrived).
    func clearNotice(id: String) {
        guard notice?.id == id else { return }
        noticeAction = nil
        noticeDismiss = nil
        notice = nil
        recompute()
    }

    /// Changes the text of the notice that's showing (e.g. to confirm a choice).
    func updateNotice(message: String) {
        guard var n = notice else { return }
        n.message = message
        notice = n
    }

    func resolveNotice(acted: Bool) {
        let action = acted ? noticeAction : noticeDismiss
        noticeAction = nil
        noticeDismiss = nil
        notice = nil
        recompute()
        action?()
    }

    // MARK: System indicators

    func showHUD(_ event: HUDEvent) {
        if case .lock = layout.presentation { return }
        var e = event
        e.token = (hud?.token ?? 0) + 1
        hud = e
        hudWork?.cancel()
        // While the pointer rests on it (or drags its slider) the indicator stays up.
        if !isHovering && !isAdjustingLevel {
            scheduleHUDDismissal(after: event.level != nil ? 1.5 : 2.6)
        }
        recompute()
    }

    private func scheduleHUDDismissal(after delay: TimeInterval) {
        hudWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isHovering, !self.isAdjustingLevel else { return }
            self.hud = nil
            self.recompute()
        }
        hudWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// A volume or brightness indicator is on screen.
    var isLevelHUD: Bool {
        guard case .hud(let kind) = layout.presentation else { return false }
        return kind == .volume || kind == .brightness
    }

    /// Sets the level shown by the volume/brightness indicator (and the system's value).
    func setHUDLevel(_ level: Double) {
        guard var e = hud, e.level != nil else { return }
        let clamped = min(1, max(0, level))
        e.level = clamped
        if e.kind == .volume {
            e.symbol = clamped <= 0.001 ? "speaker.slash.fill" : "speaker.wave.3.fill"
        } else if e.kind == .brightness {
            e.symbol = clamped < 0.5 ? "sun.min.fill" : "sun.max.fill"
        }
        hud = e
        onAdjustLevel?(e.kind, clamped)
    }

    func adjustHUDLevel(by delta: Double) {
        guard let current = hud?.level else { return }
        setHUDLevel(current + delta)
    }

    func setAdjustingLevel(_ adjusting: Bool) {
        isAdjustingLevel = adjusting
        if adjusting {
            hudWork?.cancel()
        } else if !isHovering {
            scheduleHUDDismissal(after: 1.2)
        }
    }

    // MARK: Retracting Now Playing

    /// True when an inward gesture would tuck Now Playing away.
    var canRetractMusic: Bool { layout.presentation == .music }
    /// True when an outward gesture would bring Now Playing back.
    var canRestoreMusic: Bool {
        musicRetracted && musicActive && layout.presentation.isCompact && layout.presentation != .music
    }

    /// Live feedback during a gesture; `progress` is -1…1 (negative = inward).
    func setDragStretch(_ progress: CGFloat) {
        let v = min(1, max(-1, progress))
        guard abs(v - dragStretch) > 0.01 || v == 0 else { return }
        dragStretch = v
        recompute()
    }

    /// Click-drag on the compact island: inward (toward the middle, or up) tucks Now Playing
    /// away, outward brings it back, and dragging down opens the island.
    func compactDragChanged(translation: CGSize, startX: CGFloat, width: CGFloat) {
        cancelPendingHoverExpand()
        let side: CGFloat = startX >= width / 2 ? 1 : -1
        let outward = side * translation.width
        if canRetractMusic {
            let inward = max(-outward, -translation.height)
            setDragStretch(max(-1, min(0.35, -inward / 70)))
        } else if canRestoreMusic {
            setDragStretch(max(-0.35, min(1, outward / 70)))
        }
    }

    // MARK: Onboarding

    func startOnboarding() {
        collapse()
        hud = nil
        withAnimation(spring) {
            onboardingStep = 0
            recompute()
        }
    }

    func onboardingGo(_ delta: Int) {
        guard let step = onboardingStep else { return }
        let next = step + delta
        if next >= Self.onboardingStepCount { finishOnboarding(); return }
        guard next >= 0 else { return }
        onboardingStep = next
        recompute()
    }

    func finishOnboarding() {
        demoWork?.cancel()
        onboardingDemo = false
        onboardingStep = nil
        UserDefaults.standard.set(true, forKey: "didOnboard")
        performHaptic()
        recompute()
        onOnboardingFinished?()
    }

    /// Shrinks the island to its compact look for a moment and springs back — so a size,
    /// style or animation choice can be seen on the real island.
    func demonstrate(after delay: TimeInterval = 0.25) {
        demoWork?.cancel()
        let start = DispatchWorkItem { [weak self] in
            guard let self, self.onboardingStep != nil else { return }
            self.onboardingDemo = true
            self.recompute()
            let back = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.onboardingDemo = false
                self.recompute()
            }
            self.demoWork = back
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: back)
        }
        demoWork = start
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: start)
    }

    // MARK: Pomodoro break

    private func startBreakMoment() {
        collapse()
        breakCardActive = true
        recompute()
        if clock.pomodoroConfig.breakGlow { onBreakGlow?(true) }
    }

    private func endBreakMoment() {
        guard breakCardActive else { return }
        breakCardActive = false
        recompute()
        onBreakGlow?(false)
    }

    /// Swiping the island up (or the chevron) puts the break card and the glow away;
    /// the break keeps counting in the compact island.
    func dismissBreakMoment() {
        endBreakMoment()
        performHaptic()
    }

    func compactDragEnded(translation: CGSize, startX: CGFloat, width: CGFloat) {
        if layout.presentation == .breakTime {
            if translation.height < -24 { dismissBreakMoment() }
            return
        }
        let side: CGFloat = startX >= width / 2 ? 1 : -1
        let outward = side * translation.width
        let inward = max(-outward, -translation.height)
        if canRetractMusic && inward >= 40 {
            retractMusic()
        } else if canRestoreMusic && outward >= 40 {
            restoreMusic()
        } else if translation.height > 34 && abs(translation.width) < translation.height && canExpand {
            setDragStretch(0)
            expand(haptic: true)
        } else {
            setDragStretch(0)
        }
    }

    func retractMusic() {
        guard canRetractMusic else { return }
        dragStretch = 0
        musicRetracted = true
        peeking = false
        performHaptic()
        recompute()
    }

    func restoreMusic() {
        guard canRestoreMusic else { return }
        dragStretch = 0
        musicRetracted = false
        performHaptic()
        recompute()
    }

    // MARK: Clipboard drops

    func setDropTargeted(_ targeted: Bool) {
        #if DOCKY_DEBUG
        dockyDebugLog("island drop targeted \(targeted)")
        #endif
        guard targeted != dropTargeted else { return }
        dropTargeted = targeted
        if targeted && (!isExpanded || tab != .clipboard) && canExpand {
            expand(tab: .clipboard, haptic: true)
        }
        recompute()
    }

    func share(_ urls: [URL], from rect: CGRect) {
        guard !urls.isEmpty else { return }
        onShare?(urls, rect)
    }

    // MARK: Now Playing side effects

    private func trackChanged() {
        guard p.trackChangePeek, p.compactShowsTitle, !isHovering, !isExpanded else { return }
        switch layout.presentation {
        case .music, .idle, .hidden, .timer, .peek: break
        default: return
        }
        peekWork?.cancel()
        peeking = true
        recompute()
        let work = DispatchWorkItem { [weak self] in
            self?.peeking = false
            self?.recompute()
        }
        peekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2, execute: work)
    }

    private func scheduleLingerCheck(pausedAt: Date?) {
        lingerWork?.cancel()
        guard let pausedAt else { return }
        let remaining = p.pausedLinger - Date().timeIntervalSince(pausedAt)
        guard remaining > 0 else { return }
        let work = DispatchWorkItem { [weak self] in self?.recompute() }
        lingerWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining + 0.05, execute: work)
    }
}
