import AppKit
import Combine
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let prefs = PreferencesStore()
    private lazy var nowPlaying = NowPlayingService()
    private lazy var clock = ClockStore(prefs: prefs)
    private lazy var lock = LockMonitor()
    private lazy var clipboard = ClipboardStore()
    private lazy var calendar = CalendarStore()
    private lazy var systemEvents = SystemEvents(prefs: prefs)
    private lazy var model = IslandModel(prefs: prefs, nowPlaying: nowPlaying, clock: clock, lock: lock,
                                         clipboard: clipboard, calendar: calendar)
    private var controller: IslandWindowController?
    private let settings = SettingsWindowController()
    private let intro = IntroController()
    private let breakGlow = BreakGlowController()
    private let updater = Updater()
    /// Posts settingsChanged whenever the island itself changes a preference (e.g. during setup).
    private let settingsNotifier = SettingsNotifier()
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One island at a time: if Docky is already running, nudge it and bow out.
        let me = NSRunningApplication.current
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? DockyIPC.islandBundleID)
            .filter { $0.processIdentifier != me.processIdentifier }
        if !others.isEmpty {
            DistributedNotificationCenter.default().postNotificationName(
                DockyIPC.command, object: DockyIPC.Command.preview.rawValue, userInfo: nil, deliverImmediately: true)
            NSApp.terminate(nil)
            return
        }

        model.onOpenSettings = { [weak self] in self?.openSettings() }
        let playIntro = prefs.values.playIntro
        if playIntro { model.introHidden = true } // the intro drops the island in
        let controller = IslandWindowController(model: model)
        controller.show()
        self.controller = controller
        intro.islandFrame = { [weak self] in
            guard let self, let controller = self.controller else { return (.zero, 0) }
            return (controller.islandScreenRect(), self.model.layout.bottomRadius)
        }
        settings.islandFrame = { [weak self] in
            guard let self, let controller = self.controller else { return (.zero, 0) }
            return (controller.islandScreenRect(), self.model.layout.bottomRadius)
        }
        #if DOCKY_DEBUG
        DebugHooks.install(model: model, controller: controller, clock: clock, lock: lock, nowPlaying: nowPlaying)
        DebugHooks.extraWindows = { [weak self] in
            guard let self else { return [] }
            return [self.intro.debugWindow, self.breakGlow.debugWindow].compactMap { $0 } + self.settings.debugWindows
        }
        DebugHooks.playIntro = { [weak self] in self?.playIntro() }
        DebugHooks.showAccessibilityNotice = { [weak self] in self?.systemEvents.onNeedsAccessibility?() }
        #endif

        nowPlaying.start()
        clock.start()

        DistributedNotificationCenter.default().addObserver(
            forName: DockyIPC.command, object: nil, queue: .main
        ) { [weak self] note in
            guard let raw = note.object as? String, let command = DockyIPC.Command(rawValue: raw) else { return }
            self?.handle(command)
        }

        prefs.$values
            .map(\.showMenuBarIcon)
            .removeDuplicates()
            .sink { [weak self] show in self?.setStatusItemVisible(show) }
            .store(in: &cancellables)

        prefs.$values
            .map(\.launchAtLogin)
            .removeDuplicates()
            .sink { enabled in Self.applyLoginItem(enabled) }
            .store(in: &cancellables)

        postStatus("launched")

        // System indicators start after the intro so permission prompts don't land on top of it.
        systemEvents.onEvent = { [weak self] event in self?.model.showHUD(event) }
        model.onBreakGlow = { [weak self] on in
            guard let self else { return }
            if on, let screen = self.controller?.currentScreen { self.breakGlow.show(on: screen) } else { self.breakGlow.hide() }
        }
        model.onAdjustLevel = { [weak self] kind, level in self?.systemEvents.setLevel(kind, to: level) }
        systemEvents.onNeedsAccessibility = { [weak self] in
            guard let self else { return }
            self.model.showNotice(
                IslandModel.Notice(id: "accessibility", symbol: "hand.raised.fill",
                                   title: "Replace the macOS overlay",
                                   message: "Allow Accessibility so volume and brightness only show in the island.",
                                   actionTitle: "Allow"),
                action: { [weak self] in self?.systemEvents.requestAccessibility() },
                dismiss: { [weak self] in self?.systemEvents.accessibilityNoticeDismissed() })
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (playIntro ? 6.5 : 1)) { [weak self] in
            var permissions = true
            #if DOCKY_DEBUG
            permissions = ProcessInfo.processInfo.environment["DOCKY_NO_PROMPTS"] == nil
            #endif
            self?.systemEvents.start(withPermissions: permissions)
        }
        systemEvents.$hasAccessibility
            .filter { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.model.clearNotice(id: "accessibility") }
            .store(in: &cancellables)
        Publishers.CombineLatest3(systemEvents.$hasAccessibility, systemEvents.$focusAuthorized, calendar.$access)
            .removeDuplicates { $0 == $1 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.postPermissions() }
            .store(in: &cancellables)

        // Updates from GitHub: downloaded quietly, then the island offers a restart.
        updater.isEnabled = { [weak self] in self?.prefs.values.autoUpdate ?? true }
        updater.onReady = { [weak self] version in self?.offerUpdate(version) }
        updater.start()

        // First launch: walk through setup once the intro has played.
        if !UserDefaults.standard.bool(forKey: "didOnboard") {

            DispatchQueue.main.asyncAfter(deadline: .now() + (playIntro ? 6.2 : 0.8)) { [weak self] in
                self?.model.startOnboarding()
            }
        }
        if playIntro {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.playIntro() }
        } else if !UserDefaults.standard.bool(forKey: "didWelcome") {
            // First launch without the intro: a quick hello so people know where the island lives.
            UserDefaults.standard.set(true, forKey: "didWelcome")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.model.preview() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // A downloaded update that wasn't installed yet goes in now, ready for next time.
        if updater.hasStagedUpdate { updater.install(relaunch: false) }
        nowPlaying.stop()
        clock.save()
        postStatus("terminated")
    }

    private func postStatus(_ status: String) {
        DistributedNotificationCenter.default().postNotificationName(
            DockyIPC.islandStatus, object: status, userInfo: nil, deliverImmediately: true)
    }

    private func handle(_ command: DockyIPC.Command) {
        switch command {
        case .preview: model.preview()
        case .quit: NSApp.terminate(nil)
        case .clearCompleted: clock.clearCompleted()
        case .testAlarm: clock.fireTestAlarm()
        case .openTimers: model.expand(tab: .timers)
        case .openReminders: model.requestCompose(.reminders)
        case .openClipboard: model.expand(tab: .clipboard)
        case .playIntro: playIntro()
        case .openCalendar: model.expand(tab: .calendar)
        case .requestAccessibility: systemEvents.requestAccessibility()
        case .requestCalendar: calendar.requestAccess()
        case .requestFocus: systemEvents.requestFocus()
        case .reportPermissions: postPermissions()
        case .showOnboarding: model.startOnboarding()
        case .checkForUpdates: updater.check(userInitiated: true)
        case .installUpdate: installUpdateNow()
        case .reportUpdate: updater.postState()
        }
    }

    // MARK: Updates

    private func offerUpdate(_ version: String) {
        model.showNotice(
            IslandModel.Notice(id: "update", symbol: "arrow.down.circle.fill",
                               title: "Docky \(version) is ready",
                               message: "Restart Docky to update. It only takes a second.",
                               actionTitle: "Restart"),
            action: { [weak self] in self?.installUpdateNow() })
    }

    private func installUpdateNow() {
        guard updater.install(relaunch: true) else { return }
        // Give the installer a moment to start waiting, then get out of its way.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
    }

    // MARK: Menu bar

    private func setStatusItemVisible(_ visible: Bool) {
        if visible, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            if let button = item.button {
                let image = NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: "Docky")
                image?.isTemplate = true
                button.image = image?.withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
            }
            item.menu = buildMenu()
            statusItem = item
        } else if !visible, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Island", action: #selector(openIsland), keyEquivalent: "").target = self
        menu.addItem(withTitle: "New Timer", action: #selector(newTimer), keyEquivalent: "").target = self
        menu.addItem(withTitle: "New Reminder", action: #selector(newReminder), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Clipboard", action: #selector(openClipboard), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Docky Settings…", action: #selector(openSettingsAction), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Set Up Docky…", action: #selector(showOnboardingAction), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdatesAction), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Docky", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    @objc private func openIsland() { model.expand() }
    @objc private func newTimer() { model.expand(tab: .timers) }
    @objc private func newReminder() { model.requestCompose(.reminders) }
    @objc private func openClipboard() { model.expand(tab: .clipboard) }
    @objc private func openSettingsAction() { openSettings() }
    @objc private func showOnboardingAction() { model.startOnboarding() }
    @objc private func checkForUpdatesAction() {
        updater.check(userInitiated: true)
        openSettings()
    }

    func openSettings() {
        guard let controller else { return }
        settings.show(from: controller.islandScreenRect(), radius: model.layout.bottomRadius)
    }

    private func postPermissions() {
        let ax = systemEvents.hasAccessibility ? 1 : 0
        let cal = calendar.access == .granted ? 1 : (calendar.access == .denied ? 2 : 0)
        let focus = systemEvents.focusAuthorized ? 1 : 0
        model.permissions = ["ax": ax, "cal": cal, "focus": focus]
        DistributedNotificationCenter.default().postNotificationName(
            DockyIPC.permissions, object: "ax=\(ax),cal=\(cal),focus=\(focus)", userInfo: nil, deliverImmediately: true)
    }

    private func playIntro() {
        guard let screen = controller?.currentScreen else { return }
        model.collapse()
        intro.play(on: screen, model: model)
    }

    // MARK: Login item

    private static func applyLoginItem(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled, service.status != .enabled {
                try service.register()
            } else if !enabled, service.status == .enabled {
                try service.unregister()
            }
        } catch {
            NSLog("Docky: login item change failed: \(error.localizedDescription)")
        }
    }
}
