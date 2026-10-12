import AppKit
import Combine
import SwiftUI

/// Watches the shared defaults and tells the island whenever something changes.
final class SettingsNotifier {
    private var observer: NSObjectProtocol?
    private var pending: DispatchWorkItem?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: DockyPrefs.store, queue: .main
        ) { [weak self] _ in
            self?.schedule()
        }
    }

    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem {
            DockyPrefs.store.synchronize()
            DistributedNotificationCenter.default().postNotificationName(
                DockyIPC.settingsChanged, object: nil, userInfo: nil, deliverImmediately: true)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }
}

/// Knows whether the island app is running and how to start, stop and poke it.
final class IslandStatus: ObservableObject {
    @Published private(set) var isRunning = false
    /// Permissions as the island (not this process) sees them: "ax", "cal", "focus" → 0 no, 1 yes, 2 denied.
    @Published private(set) var permissions: [String: Int] = [:]
    /// The island's updater state, e.g. "checking" or "ready:1.0.2" (see DockyIPC.updateStatus).
    @Published private(set) var update = "idle"
    private var permissionObserver: NSObjectProtocol?
    private var observers: [NSObjectProtocol] = []
    /// True when this settings UI is hosted inside the island app itself.
    let inProcess: Bool

    init(inProcess: Bool = false) {
        self.inProcess = inProcess
        permissionObserver = DistributedNotificationCenter.default().addObserver(
            forName: DockyIPC.permissions, object: nil, queue: .main
        ) { [weak self] note in
            guard let raw = note.object as? String else { return }
            var result: [String: Int] = [:]
            for pair in raw.split(separator: ",") {
                let kv = pair.split(separator: "=")
                if kv.count == 2 { result[String(kv[0])] = Int(kv[1]) }
            }
            self?.permissions = result
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.send(.reportPermissions) }
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: DockyIPC.updateStatus, object: nil, queue: .main
        ) { [weak self] note in
            if let raw = note.object as? String { self?.update = raw }
        })
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.send(.reportUpdate) }
        if inProcess {
            isRunning = true
            return
        }
        refresh()
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                if app?.bundleIdentifier == DockyIPC.islandBundleID {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self?.refresh() }
                }
            })
        }
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: DockyIPC.islandStatus, object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.refresh() }
        })
    }

    func refresh() {
        guard !inProcess else { return }
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: DockyIPC.islandBundleID).isEmpty
        if running != isRunning { isRunning = running }
    }

    var islandURL: URL? {
        let fm = FileManager.default
        if inProcess { return Bundle.main.bundleURL }
        let candidates: [URL?] = [
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Docky.app"),
            URL(fileURLWithPath: "/Applications/Docky.app"),
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: DockyIPC.islandBundleID),
        ]
        return candidates.compactMap { $0 }.first { fm.fileExists(atPath: $0.path) }
    }

    func launch(then command: DockyIPC.Command? = nil) {
        guard let url = islandURL else { NSSound.beep(); return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                self.refresh()
                if let command { self.send(command) }
            }
        }
    }

    func send(_ command: DockyIPC.Command) {
        DistributedNotificationCenter.default().postNotificationName(
            DockyIPC.command, object: command.rawValue, userInfo: nil, deliverImmediately: true)
    }

    func quit() {
        if inProcess { NSApp.terminate(nil); return }
        send(.quit)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.refresh() }
    }

    func restart() {
        if inProcess {
            // Relaunch ourselves once this process has gone.
            let path = Bundle.main.bundlePath
            let relaunch = Process()
            relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
            relaunch.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
            try? relaunch.run()
            NSApp.terminate(nil)
            return
        }
        send(.quit)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.launch(then: .preview) }
    }

    func preview() {
        if isRunning { send(.preview) } else { launch(then: .preview) }
    }
}
