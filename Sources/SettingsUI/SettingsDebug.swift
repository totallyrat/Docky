#if DOCKY_DEBUG
import AppKit
import SwiftUI

/// Test-only: switch panes and snapshot the settings window from the command line.
struct SettingsDebugReceiver: ViewModifier {
    @Binding var selection: Pane?

    func body(content: Content) -> some View {
        content.onReceive(DistributedNotificationCenter.default().publisher(for: .init("com.totallyrat.docky.settings.debug"))) { note in
            guard let raw = note.object as? String else { return }
            let parts = raw.split(separator: " ", maxSplits: 1).map(String.init)
            let arg = parts.count > 1 ? parts[1] : ""
            switch parts[0] {
            case "pane":
                selection = Pane(rawValue: arg)
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first { $0.styleMask.contains(.titled) }?.orderFrontRegardless()
            case "snap":
                guard let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }) ?? NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 300 }),
                      let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution])
                else { return }
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: arg))
            default: break
            }
        }
    }
}
#endif
