import AppKit
import Combine

/// Live view of the shared preferences. Docky Settings writes the shared suite and posts
/// `DockyIPC.settingsChanged`; we re-read and publish only when something actually changed.
final class PreferencesStore: ObservableObject {
    @Published private(set) var values = DockyPrefs()
    private var observer: NSObjectProtocol?

    init() {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: DockyIPC.settingsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reload()
        }
    }

    func reload() {
        let store = DockyPrefs.store
        store.synchronize()
        let fresh = DockyPrefs(store)
        if fresh != values { values = fresh }
    }

    func set(_ value: Any, for key: String) {
        DockyPrefs.store.set(value, forKey: key)
        reload()
    }
}
