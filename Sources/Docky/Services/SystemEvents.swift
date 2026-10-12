import AppKit
import ApplicationServices
import AudioToolbox
import Combine
import CoreAudio
import Intents
import IOBluetooth
import IOKit.ps

/// What the island shows when the system changes something.
struct HUDEvent: Equatable {
    enum Kind: Equatable { case volume, brightness, focus, device, charging, drive }

    var kind: Kind
    var symbol: String
    var title: String
    var detail: String = ""
    /// 0…1 for volume and brightness.
    var level: Double?
    var tint: Tint = .white
    var token = 0

    enum Tint: Equatable { case white, green, purple, blue, orange, red }
}

/// Watches the Mac for volume, brightness, Focus, device and power changes and turns each into
/// an island HUD. With Accessibility access it also intercepts the volume and brightness keys,
/// so the macOS overlay never appears and the island is the only place the change shows.
final class SystemEvents: ObservableObject {
    @Published private(set) var hasAccessibility = AXIsProcessTrusted()
    @Published private(set) var focusAuthorized = false

    var onEvent: ((HUDEvent) -> Void)?
    /// Asks the island to show a card explaining why Accessibility access is needed.
    var onNeedsAccessibility: (() -> Void)?
    private var askedThisRun = false

    private let prefs: PreferencesStore
    private let volume = VolumeController()
    private let brightness = BrightnessController()
    private var keyTap: MediaKeyTap?
    private var power: PowerMonitor?
    private var bluetooth: BluetoothMonitor?
    private var focus: FocusMonitor?
    private var accessibilityTimer: Timer?
    private var brightnessTimer: Timer?
    private var lastBrightness: Float?
    private var lastOwnChange = Date.distantPast
    private var observers: [NSObjectProtocol] = []
    private var started = Date()

    init(prefs: PreferencesStore) {
        self.prefs = prefs
    }

    var p: DockyPrefs { prefs.values }

    func start(withPermissions: Bool = true) {
        started = Date()

        volume.onChange = { [weak self] in
            guard let self, Date().timeIntervalSince(self.lastOwnChange) > 0.25 else { return }
            self.showVolume()
        }
        volume.start()

        // Keyboard-driven brightness is caught by the key tap; this catches the rest (Control
        // Centre slider, or keys when Docky lacks Accessibility) while ignoring slow auto-brightness drift.
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.pollBrightness() }
        t.tolerance = 0.05
        RunLoop.main.add(t, forMode: .common)
        brightnessTimer = t

        power = PowerMonitor { [weak self] percent, charging in self?.powerChanged(percent: percent, charging: charging) }
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] note in
            self?.driveChanged(note, mounted: true)
        })
        observers.append(ws.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] note in
            self?.driveChanged(note, mounted: false)
        })
        guard withPermissions else { return }

        bluetooth = BluetoothMonitor { [weak self] name, symbol, connected, battery in
            self?.deviceChanged(name: name, symbol: symbol, connected: connected, battery: battery)
        }
        focus = FocusMonitor { [weak self] on, name, symbol in self?.focusChanged(on: on, name: name, symbol: symbol) }
        focus?.onAuthorization = { [weak self] ok in self?.focusAuthorized = ok }
        focus?.start()
        startKeyTapIfPossible()
    }

    // MARK: Accessibility & key interception

    func requestAccessibility() {
        if !AXIsProcessTrusted(), let id = Bundle.main.bundleIdentifier {
            // Docky's signature changes with every build, so a switch turned on for an earlier
            // build no longer counts (and blocks the new one from being added). Clear Docky's
            // own stale entry so this build can be allowed.
            let reset = Process()
            reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            reset.arguments = ["reset", "Accessibility", id]
            reset.standardOutput = FileHandle.nullDevice
            reset.standardError = FileHandle.nullDevice
            try? reset.run()
            reset.waitUntilExit()
        }
        NSApp.activate(ignoringOtherApps: true)
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        hasAccessibility = AXIsProcessTrustedWithOptions(options)
        if !hasAccessibility {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        watchForAccessibility()
    }

    /// Show the island's permission card when Docky can't take over the keys yet — once at
    /// launch for each new build, and again the first time you press volume or brightness.
    private func nudgeForAccessibilityIfNeeded(force: Bool = false) {
        guard p.replaceSystemHUD, p.hudVolume || p.hudBrightness, !AXIsProcessTrusted(), !askedThisRun else { return }
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let dismissed = UserDefaults.standard.string(forKey: "axNoticeDismissedBuild") == build
        guard force || !dismissed else { return }
        if !force && UserDefaults.standard.string(forKey: "axNoticeShownBuild") == build { return }
        UserDefaults.standard.set(build, forKey: "axNoticeShownBuild")
        askedThisRun = true
        onNeedsAccessibility?()
    }

    func accessibilityNoticeDismissed() {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        UserDefaults.standard.set(build, forKey: "axNoticeDismissedBuild")
    }

    func requestFocus() { focus?.requestAuthorization() }

    private func watchForAccessibility() {
        accessibilityTimer?.invalidate()
        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if AXIsProcessTrusted() {
                timer.invalidate()
                self.hasAccessibility = true
                self.startKeyTapIfPossible()
                if self.keyTap != nil {
                    self.onEvent?(HUDEvent(kind: .device, symbol: "checkmark.circle.fill", title: "Volume & brightness",
                                           detail: "Island only", tint: .green))
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        accessibilityTimer = t
    }

    private func startKeyTapIfPossible() {
        hasAccessibility = AXIsProcessTrusted()
        guard keyTap == nil else { return }
        guard hasAccessibility else {
            nudgeForAccessibilityIfNeeded()
            watchForAccessibility()
            return
        }
        let tap = MediaKeyTap { [weak self] key, flags in self?.handle(key, flags: flags) ?? false }
        if tap.start() {
            keyTap = tap
        } else {
            // Trust can take a moment to apply after it's granted; try again shortly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.startKeyTapIfPossible() }
        }
    }

    /// Return true to swallow the key (so macOS doesn't show its own overlay).
    private func handle(_ key: MediaKeyTap.Key, flags: NSEvent.ModifierFlags) -> Bool {
        guard p.replaceSystemHUD else { return false }
        let fine = flags.contains(.option) && flags.contains(.shift)
        switch key {
        case .volumeUp, .volumeDown, .mute:
            guard p.hudVolume, volume.canControl else { return false }
            lastOwnChange = Date()
            switch key {
            case .mute: volume.toggleMute()
            case .volumeUp: volume.step(up: true, fine: fine)
            default: volume.step(up: false, fine: fine)
            }
            showVolume()
            if key != .mute { volume.playFeedbackIfEnabled() }
            return true
        case .brightnessUp, .brightnessDown:
            guard p.hudBrightness, brightness.isAvailable else { return false }
            lastOwnChange = Date()
            brightness.step(up: key == .brightnessUp, fine: fine)
            lastBrightness = brightness.value
            showBrightness(Double(brightness.value ?? 0))
            return true
        }
    }

    /// Sets volume or brightness directly (dragging the island's slider).
    func setLevel(_ kind: HUDEvent.Kind, to level: Double) {
        lastOwnChange = Date()
        switch kind {
        case .volume:
            guard volume.canControl else { return }
            volume.set(level: Float(level))
        case .brightness:
            guard brightness.isAvailable else { return }
            brightness.set(Float(level))
            lastBrightness = brightness.value
        default:
            break
        }
    }

    // MARK: Producers

    private var warmedUp: Bool { Date().timeIntervalSince(started) > 3 }

    private func showVolume() {
        guard p.hudVolume, let level = volume.volume else { return }
        if keyTap == nil { nudgeForAccessibilityIfNeeded(force: true) }
        let muted = volume.isMuted || level < 0.001
        let symbol = muted ? "speaker.slash.fill" : "speaker.wave.3.fill"
        onEvent?(HUDEvent(kind: .volume, symbol: symbol, title: volume.deviceName, level: muted ? 0 : Double(level)))
    }

    private func showBrightness(_ level: Double) {
        guard p.hudBrightness else { return }
        onEvent?(HUDEvent(kind: .brightness, symbol: level < 0.5 ? "sun.min.fill" : "sun.max.fill", title: "Brightness", level: level))
    }

    private func pollBrightness() {
        guard p.hudBrightness, brightness.isAvailable, let value = brightness.value else { return }
        defer { lastBrightness = value }
        guard let last = lastBrightness, Date().timeIntervalSince(lastOwnChange) > 0.6 else { return }
        // A key press or slider moves at least ~1/16 at once; auto-brightness creeps.
        if abs(value - last) >= 0.035 { showBrightness(Double(value)) }
    }

    private func powerChanged(percent: Int, charging: Bool) {
        guard p.hudCharging, warmedUp, charging else { return }
        let symbol = percent >= 100 ? "battery.100percent.bolt" : "battery.100percent.bolt"
        onEvent?(HUDEvent(kind: .charging, symbol: symbol, title: "Charging", detail: "\(percent)%", tint: percent <= 20 ? .orange : .green))
    }

    private func deviceChanged(name: String, symbol: String, connected: Bool, battery: Int?) {
        guard p.hudDevices, warmedUp else { return }
        let detail = connected ? (battery.map { "\($0)%" } ?? "Connected") : "Disconnected"
        onEvent?(HUDEvent(kind: .device, symbol: symbol, title: name, detail: detail, tint: connected ? .blue : .white))
    }

    private func focusChanged(on: Bool, name: String?, symbol: String?) {
        guard p.hudFocus, warmedUp else { return }
        onEvent?(HUDEvent(kind: .focus, symbol: symbol ?? "moon.fill", title: name ?? "Focus", detail: on ? "On" : "Off",
                          tint: on ? .purple : .white))
    }

    private func driveChanged(_ note: Notification, mounted: Bool) {
        guard p.hudDevices, warmedUp, let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
        let values = try? url.resourceValues(forKeys: [.volumeIsInternalKey, .volumeLocalizedNameKey])
        if values?.volumeIsInternal == true { return }
        let name = (note.userInfo?[NSWorkspace.localizedVolumeNameUserInfoKey] as? String) ?? values?.volumeLocalizedName ?? url.lastPathComponent
        onEvent?(HUDEvent(kind: .drive, symbol: mounted ? "externaldrive.fill" : "eject.fill", title: name,
                          detail: mounted ? "Connected" : "Ejected", tint: mounted ? .blue : .white))
    }
}

// MARK: - Volume (CoreAudio)

final class VolumeController {
    var onChange: (() -> Void)?
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var listening: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private let queue = DispatchQueue.main

    private static var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    private static var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    private static var muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)

    private lazy var deviceListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refreshDevice() }
    private lazy var valueListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.onChange?() }

    func start() {
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutputAddress, queue, deviceListener)
        refreshDevice()
    }

    private func refreshDevice() {
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutputAddress, 0, nil, &size, &id)
        guard id != device else { return }
        if listening != kAudioObjectUnknown {
            AudioObjectRemovePropertyListenerBlock(listening, &Self.volumeAddress, queue, valueListener)
            AudioObjectRemovePropertyListenerBlock(listening, &Self.muteAddress, queue, valueListener)
        }
        device = id
        AudioObjectAddPropertyListenerBlock(id, &Self.volumeAddress, queue, valueListener)
        AudioObjectAddPropertyListenerBlock(id, &Self.muteAddress, queue, valueListener)
        listening = id
    }

    var canControl: Bool {
        var settable: DarwinBoolean = false
        return AudioObjectHasProperty(device, &Self.volumeAddress)
            && AudioObjectIsPropertySettable(device, &Self.volumeAddress, &settable) == noErr && settable.boolValue
    }

    var volume: Float? {
        var v = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectHasProperty(device, &Self.volumeAddress),
              AudioObjectGetPropertyData(device, &Self.volumeAddress, 0, nil, &size, &v) == noErr else { return nil }
        return v
    }

    var isMuted: Bool {
        var m = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectHasProperty(device, &Self.muteAddress),
              AudioObjectGetPropertyData(device, &Self.muteAddress, 0, nil, &size, &m) == noErr else { return false }
        return m != 0
    }

    var deviceName: String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr, let value = name?.takeRetainedValue() else {
            return "Volume"
        }
        return value as String
    }

    private func setVolume(_ value: Float) {
        var v = Float32(min(1, max(0, value)))
        AudioObjectSetPropertyData(device, &Self.volumeAddress, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
    }

    private func setMuted(_ muted: Bool) {
        var m = UInt32(muted ? 1 : 0)
        AudioObjectSetPropertyData(device, &Self.muteAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m)
    }

    /// Same steps as macOS: sixteenths, or sixty-fourths with ⌥⇧.
    func step(up: Bool, fine: Bool) {
        let unit: Float = fine ? 1 / 64 : 1 / 16
        let current = volume ?? 0
        if isMuted && up { setMuted(false) }
        let next = ((current / unit).rounded() + (up ? 1 : -1)) * unit
        setVolume(next)
        if next <= 0.0001 { setMuted(true) } else if isMuted { setMuted(false) }
    }

    func toggleMute() { setMuted(!isMuted) }

    /// Sets an exact level; 0 mutes, anything above unmutes.
    func set(level: Float) {
        setVolume(level)
        if level <= 0.001 { setMuted(true) } else if isMuted { setMuted(false) }
    }

    func playFeedbackIfEnabled() {
        guard UserDefaults(suiteName: UserDefaults.globalDomain)?.integer(forKey: "com.apple.sound.beep.feedback") == 1 else { return }
        let path = "/System/Library/LoginPlugins/BezelServices.loginPlugin/Contents/Resources/volume.aiff"
        NSSound(contentsOfFile: path, byReference: true)?.play()
    }
}

// MARK: - Brightness (DisplayServices, private)

final class BrightnessController {
    private typealias GetFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (UInt32, Float) -> Int32
    private var getter: GetFn?
    private var setter: SetFn?
    private let display: UInt32

    init() {
        display = NSScreen.screens.compactMap { s -> UInt32? in
            guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return CGDisplayIsBuiltin(n.uint32Value) != 0 ? n.uint32Value : nil
        }.first ?? CGMainDisplayID()
        if let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW) {
            if let g = dlsym(h, "DisplayServicesGetBrightness") { getter = unsafeBitCast(g, to: GetFn.self) }
            if let s = dlsym(h, "DisplayServicesSetBrightness") { setter = unsafeBitCast(s, to: SetFn.self) }
        }
    }

    var isAvailable: Bool { getter != nil && setter != nil && value != nil }

    var value: Float? {
        guard let getter else { return nil }
        var v: Float = 0
        return getter(display, &v) == 0 ? v : nil
    }

    func set(_ level: Float) {
        _ = setter?(display, min(1, max(0, level)))
    }

    func step(up: Bool, fine: Bool) {
        guard let setter, let current = value else { return }
        let unit: Float = fine ? 1 / 64 : 1 / 16
        let next = min(1, max(0, ((current / unit).rounded() + (up ? 1 : -1)) * unit))
        _ = setter(display, next)
    }
}

// MARK: - Media key tap

/// Intercepts the volume / brightness keys (NX_SYSDEFINED events). Needs Accessibility.
final class MediaKeyTap {
    enum Key { case volumeUp, volumeDown, mute, brightnessUp, brightnessDown }

    private let handler: (Key, NSEvent.ModifierFlags) -> Bool
    private var tap: CFMachPort?
    private var swallowed = Set<Int>()

    init(handler: @escaping (Key, NSEvent.ModifierFlags) -> Bool) {
        self.handler = handler
    }

    func start() -> Bool {
        let mask = CGEventMask(1 << 14) // NX_SYSDEFINED
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<MediaKeyTap>.fromOpaque(refcon).takeUnretainedValue()
            return me.process(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func process(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type.rawValue == 14, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else {
            return Unmanaged.passUnretained(event)
        }
        let code = (ns.data1 & 0xFFFF_0000) >> 16
        let isDown = ((ns.data1 & 0x0000_FF00) >> 8) == 0xA
        let key: Key
        switch code {
        case 0: key = .volumeUp
        case 1: key = .volumeDown
        case 7: key = .mute
        case 2: key = .brightnessUp
        case 3: key = .brightnessDown
        default: return Unmanaged.passUnretained(event)
        }
        if isDown {
            if handler(key, ns.modifierFlags) {
                swallowed.insert(code)
                return nil
            }
            return Unmanaged.passUnretained(event)
        }
        // Key up: swallow it too if we swallowed the press.
        return swallowed.remove(code) != nil ? nil : Unmanaged.passUnretained(event)
    }
}

// MARK: - Power

final class PowerMonitor {
    private let onChange: (Int, Bool) -> Void
    private var lastOnAC: Bool?

    init(onChange: @escaping (Int, Bool) -> Void) {
        self.onChange = onChange
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            Unmanaged<PowerMonitor>.fromOpaque(ctx).takeUnretainedValue().check()
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }
        lastOnAC = Self.read()?.onAC
    }

    private static func read() -> (percent: Int, onAC: Bool)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef],
              let first = list.first,
              let desc = IOPSGetPowerSourceDescription(info, first)?.takeUnretainedValue() as? [String: Any]
        else { return nil }
        let percent = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
        let state = desc[kIOPSPowerSourceStateKey] as? String
        return (percent, state == kIOPSACPowerValue)
    }

    private func check() {
        guard let now = Self.read() else { return }
        defer { lastOnAC = now.onAC }
        // Only the moment you plug in.
        if now.onAC && lastOnAC == false { onChange(now.percent, true) }
    }
}

// MARK: - Bluetooth

final class BluetoothMonitor: NSObject {
    private let onChange: (String, String, Bool, Int?) -> Void
    private var connectNote: IOBluetoothUserNotification?
    private var disconnectNotes: [String: IOBluetoothUserNotification] = [:]

    init(onChange: @escaping (String, String, Bool, Int?) -> Void) {
        self.onChange = onChange
        super.init()
        connectNote = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(connected(_:device:)))
    }

    @objc private func connected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let key = device.addressString ?? device.name ?? UUID().uuidString
        disconnectNotes[key] = device.register(forDisconnectNotification: self, selector: #selector(disconnected(_:device:)))
        // AirPods report battery a moment after connecting.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.onChange(device.name ?? "Bluetooth Device", Self.symbol(for: device), true, Self.battery(of: device))
        }
    }

    @objc private func disconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let key = device.addressString ?? device.name ?? ""
        disconnectNotes[key]?.unregister()
        disconnectNotes[key] = nil
        onChange(device.name ?? "Bluetooth Device", Self.symbol(for: device), false, nil)
    }

    static func symbol(for device: IOBluetoothDevice) -> String {
        let name = (device.name ?? "").lowercased()
        if name.contains("airpods max") { return "airpodsmax" }
        if name.contains("airpods pro") { return "airpodspro" }
        if name.contains("airpods") { return "airpods" }
        if name.contains("beats") { return "beats.headphones" }
        if name.contains("keyboard") { return "keyboard" }
        if name.contains("mouse") { return "magicmouse.fill" }
        if name.contains("trackpad") { return "rectangle.and.hand.point.up.left.filled" }
        if name.contains("controller") || name.contains("dualsense") || name.contains("xbox") { return "gamecontroller.fill" }
        switch device.deviceClassMajor {
        case 0x04: return "headphones" // audio/video
        case 0x05: return "keyboard"   // peripheral
        case 0x02: return "iphone"     // phone
        default: return "dot.radiowaves.left.and.right"
        }
    }

    /// Battery is only exposed through private properties; read them defensively.
    static func battery(of device: IOBluetoothDevice) -> Int? {
        for key in ["batteryPercentSingle", "batteryPercentCombined", "batteryPercentLeft", "batteryPercentRight"] {
            let selector = NSSelectorFromString(key)
            guard device.responds(to: selector),
                  let value = (device.value(forKey: key) as? NSNumber)?.intValue, value > 0, value <= 100 else { continue }
            return value
        }
        return nil
    }
}

// MARK: - Focus

final class FocusMonitor {
    private let onChange: (Bool, String?, String?) -> Void
    var onAuthorization: ((Bool) -> Void)?
    private var last: Bool?
    private var lastName: String?
    private var lastSymbol: String?
    private var timer: Timer?

    init(onChange: @escaping (Bool, String?, String?) -> Void) {
        self.onChange = onChange
    }

    func start() {
        let center = INFocusStatusCenter.default
        if center.authorizationStatus == .notDetermined {
            requestAuthorization()
        } else {
            onAuthorization?(center.authorizationStatus == .authorized)
        }
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.poll() }
        t.tolerance = 0.3
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func requestAuthorization() {
        INFocusStatusCenter.default.requestAuthorization { [weak self] status in
            DispatchQueue.main.async { self?.onAuthorization?(status == .authorized) }
        }
    }

    private func poll() {
        let fileState = Self.readAssertions()
        let on = fileState?.on ?? INFocusStatusCenter.default.focusStatus.isFocused
        guard let on else { return }
        if on, let name = fileState?.name { lastName = name; lastSymbol = fileState?.symbol }
        if let last, last != on { onChange(on, fileState?.name ?? lastName, fileState?.symbol ?? lastSymbol) }
        last = on
    }

    /// With Full Disk Access, the Focus database tells us which Focus is on (name and symbol).
    private static func readAssertions() -> (on: Bool, name: String?, symbol: String?)? {
        let base = (NSHomeDirectory() as NSString).appendingPathComponent("Library/DoNotDisturb/DB")
        guard let data = FileManager.default.contents(atPath: base + "/Assertions.json"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["data"] as? [[String: Any]]
        else { return nil }
        let records = entries.first?["storeAssertionRecords"] as? [[String: Any]] ?? []
        guard let record = records.last else { return (false, nil, nil) }
        let modeID = (record["assertionDetails"] as? [String: Any])?["assertionDetailsModeIdentifier"] as? String
        var name: String?, symbol: String?
        if let modeID,
           let configData = FileManager.default.contents(atPath: base + "/ModeConfigurations.json"),
           let config = try? JSONSerialization.jsonObject(with: configData) as? [String: Any],
           let configs = (config["data"] as? [[String: Any]])?.first?["modeConfigurations"] as? [String: Any],
           let mode = (configs[modeID] as? [String: Any])?["mode"] as? [String: Any] {
            name = mode["name"] as? String
            symbol = mode["symbolImageName"] as? String
        }
        return (true, name, symbol)
    }
}
