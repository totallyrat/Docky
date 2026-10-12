import AppKit
import Combine

/// Tracks the login-window lock state. `unlocking` is the short window right after
/// Touch ID / password unlock in which the island plays its "shackle opens" animation.
final class LockMonitor: ObservableObject {
    enum State: Equatable { case unlocked, locked, unlocking }

    @Published private(set) var state: State = .unlocked
    private var observers: [NSObjectProtocol] = []
    private var settleWork: DispatchWorkItem?

    init() {
        if Self.screenIsLockedNow() { state = .locked }
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.didLock()
        })
        observers.append(center.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.didUnlock()
        })
    }

    private func didLock() {
        settleWork?.cancel()
        state = .locked
    }

    private func didUnlock() {
        guard state == .locked else { return }
        state = .unlocking
        let work = DispatchWorkItem { [weak self] in self?.state = .unlocked }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    #if DOCKY_DEBUG
    func setStateForDebug(_ s: State) { settleWork?.cancel(); state = s }
    func didUnlockForDebug() { didUnlock() }
    #endif

    private static func screenIsLockedNow() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (dict["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }
}

/// Private SkyLight calls that move a window into a dedicated space with the absolute level
/// macOS uses for notifications on the lock screen, so the island stays visible while locked.
final class SkyLightSpace {
    static let shared = SkyLightSpace()

    private typealias MainConnectionFn = @convention(c) () -> Int32
    private typealias SpaceCreateFn = @convention(c) (Int32, Int32, Int32) -> UInt64
    private typealias SpaceSetAbsoluteLevelFn = @convention(c) (Int32, UInt64, Int32) -> Int32
    private typealias ShowSpacesFn = @convention(c) (Int32, CFArray) -> Int32
    private typealias AddWindowsFn = @convention(c) (Int32, UInt64, CFArray, Int32) -> Int32

    private var connection: Int32 = 0
    private var space: UInt64 = 0
    private var addWindows: AddWindowsFn?

    private init() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW),
              let mainConnection = dlsym(handle, "SLSMainConnectionID"),
              let spaceCreate = dlsym(handle, "SLSSpaceCreate"),
              let setLevel = dlsym(handle, "SLSSpaceSetAbsoluteLevel"),
              let showSpaces = dlsym(handle, "SLSShowSpaces"),
              let add = dlsym(handle, "SLSSpaceAddWindowsAndRemoveFromSpaces")
        else {
            NSLog("Docky: SkyLight unavailable; lock screen island disabled")
            return
        }
        connection = unsafeBitCast(mainConnection, to: MainConnectionFn.self)()
        space = unsafeBitCast(spaceCreate, to: SpaceCreateFn.self)(connection, 1, 0)
        // 400 = kSLSSpaceAbsoluteLevelNotificationCenterAtScreenLock
        _ = unsafeBitCast(setLevel, to: SpaceSetAbsoluteLevelFn.self)(connection, space, 400)
        _ = unsafeBitCast(showSpaces, to: ShowSpacesFn.self)(connection, [NSNumber(value: space)] as CFArray)
        addWindows = unsafeBitCast(add, to: AddWindowsFn.self)
    }

    var isAvailable: Bool { addWindows != nil && space != 0 }

    func adopt(_ window: NSWindow) {
        guard let addWindows, space != 0, window.windowNumber > 0 else { return }
        _ = addWindows(connection, space, [NSNumber(value: window.windowNumber)] as CFArray, 7)
    }
}
