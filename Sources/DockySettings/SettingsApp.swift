import AppKit
import Combine
import SwiftUI

@main
struct DockySettingsApp: App {
    @NSApplicationDelegateAdaptor(SettingsAppDelegate.self) private var delegate
    @StateObject private var status = IslandStatus()

    var body: some Scene {
        Window("Docky Settings", id: "settings") {
            SettingsRoot()
                .environmentObject(status)
        }
        .windowResizability(.contentSize)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

final class SettingsAppDelegate: NSObject, NSApplicationDelegate {
    private var notifier: SettingsNotifier?

    func applicationDidFinishLaunching(_ notification: Notification) {
        notifier = SettingsNotifier()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
