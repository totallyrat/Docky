import AppKit
import CoreAudio

/// Knows which apps are producing sound right now, using Core Audio's per-process objects
/// (macOS 14.2+, no permission needed). Helper processes (browser audio services, WebKit's
/// GPU process) are attributed to the app responsible for them.
final class AudioActivityMonitor {
    /// Called when an app starts producing sound and keeps going past a short debounce.
    var onAppStartedOutput: ((String) -> Void)?

    /// Apps currently producing sound, with when they started.
    private(set) var outputting: [String: Date] = [:]

    private var processes: [AudioObjectID: String] = [:] // process object → owning app bundle ID
    private var running: Set<AudioObjectID> = []
    private var pending: [String: DispatchWorkItem] = [:]
    private let debounce: TimeInterval = 0.9

    private static var listAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    private static var runningAddress = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyIsRunningOutput, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)

    private lazy var listListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refreshList() }
    private lazy var runningListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.evaluate() }

    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    private static let responsible: ResponsibleFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: ResponsibleFn.self)
    }()

    func start() {
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.listAddress, .main, listListener)
        refreshList()
        // Whatever is already playing at launch is the baseline, not a "new" sound.
        pending.values.forEach { $0.cancel() }
        pending.removeAll()
        for app in outputting.keys { outputting[app] = .distantPast }
    }

    private func refreshList() {
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &Self.listAddress, 0, nil, &size) == noErr else { return }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &Self.listAddress, 0, nil, &size, &ids) == noErr else { return }

        let current = Set(ids)
        for gone in Set(processes.keys).subtracting(current) {
            AudioObjectRemovePropertyListenerBlock(gone, &Self.runningAddress, .main, runningListener)
            processes[gone] = nil
            running.remove(gone)
        }
        for id in current where processes[id] == nil {
            processes[id] = Self.owningApp(of: id) ?? ""
            AudioObjectAddPropertyListenerBlock(id, &Self.runningAddress, .main, runningListener)
        }
        evaluate()
    }

    private func evaluate() {
        var nowRunning: Set<AudioObjectID> = []
        for id in processes.keys {
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(id, &Self.runningAddress, 0, nil, &size, &value) == noErr, value != 0 {
                nowRunning.insert(id)
            }
        }
        running = nowRunning
        let apps = Set(nowRunning.compactMap { processes[$0] }.filter { !$0.isEmpty })

        for app in Set(outputting.keys).subtracting(apps) {
            outputting[app] = nil
            pending[app]?.cancel()
            pending[app] = nil
        }
        for app in apps where outputting[app] == nil {
            outputting[app] = Date()
            // Debounce so short sounds (a notification ping in a browser tab) don't count.
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.outputting[app] != nil else { return }
                self.pending[app] = nil
                self.onAppStartedOutput?(app)
            }
            pending[app] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
        }
    }

    func isOutputting(_ app: String) -> Bool { outputting[app] != nil }

    private static func owningApp(of object: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &pid) == noErr, pid > 0 else { return nil }
        if let r = responsible?(pid), r > 0, let app = NSRunningApplication(processIdentifier: r), let id = app.bundleIdentifier {
            return id
        }
        if let app = NSRunningApplication(processIdentifier: pid), let id = app.bundleIdentifier { return id }
        address.mSelector = kAudioProcessPropertyBundleID
        var bundle: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        if AudioObjectGetPropertyData(object, &address, 0, nil, &size, &bundle) == noErr,
           let id = bundle?.takeRetainedValue() as String?, !id.isEmpty {
            return id
        }
        // Command-line tools have no bundle; fall back to the process name.
        var name = [CChar](repeating: 0, count: 256)
        return proc_name(pid, &name, UInt32(name.count)) > 0 ? String(cString: name) : nil
    }
}

/// "One thing plays at a time": when a media app starts producing sound, every other media
/// app that is still playing gets paused — whether you started a video over your music or
/// went back to your music over a video.
final class MediaArbiter {
    private let audio = AudioActivityMonitor()
    private let isEnabled: () -> Bool
    private let sendToBridge: (String) -> Void
    /// Apps seen in Now Playing this session count as media apps too.
    private var seenPlayers: Set<String> = []
    private var lastPause: [String: Date] = [:]

    static let knownPlayers: Set<String> = MusicClassifier.musicApps.union([
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome", "com.google.Chrome.canary",
        "company.thebrowser.Browser", "company.thebrowser.dia", "com.brave.Browser", "com.microsoft.edgemac",
        "org.mozilla.firefox", "com.operasoftware.Opera", "com.operasoftware.OperaGX", "com.vivaldi.Vivaldi",
        "app.zen-browser.zen", "com.apple.TV", "com.apple.podcasts", "com.apple.QuickTimePlayerX",
        "org.videolan.vlc", "com.colliderli.iina", "com.netflix.Netflix", "com.disney.disneyplus",
        "tv.twitch.studio", "com.google.android.youtube", "com.amazon.aiv.AIVApp",
    ])

    /// Apps that also understand a plain AppleScript `pause` (used if the media command is ignored).
    private static let scriptable: Set<String> = ["com.spotify.client", "com.apple.Music", "com.apple.TV"]

    init(isEnabled: @escaping () -> Bool, send: @escaping (String) -> Void) {
        self.isEnabled = isEnabled
        self.sendToBridge = send
        audio.onAppStartedOutput = { [weak self] app in self?.started(app) }
    }

    func start() { audio.start() }

    func noteNowPlaying(_ bundleID: String) {
        if !bundleID.isEmpty { seenPlayers.insert(bundleID) }
    }

    private func isPlayer(_ app: String) -> Bool {
        #if DOCKY_DEBUG
        if let extra = ProcessInfo.processInfo.environment["DOCKY_TEST_PLAYERS"], extra.split(separator: ",").contains(Substring(app)) { return true }
        #endif
        return Self.knownPlayers.contains(app) || seenPlayers.contains(app)
    }

    #if DOCKY_DEBUG
    private func debugLog(_ line: String) {
        guard let path = ProcessInfo.processInfo.environment["DOCKY_ARBITER_LOG"],
              let data = (line + "\n").data(using: .utf8) else { return }
        if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(data); try? h.close() }
        else { FileManager.default.createFile(atPath: path, contents: data) }
    }
    #endif

    private func started(_ app: String) {
        #if DOCKY_DEBUG
        debugLog("started \(app) player=\(isPlayer(app)) outputting=\(audio.outputting.keys.sorted())")
        #endif
        guard isEnabled(), isPlayer(app) else { return }
        for other in audio.outputting.keys where other != app && isPlayer(other) {
            pause(other)
        }
    }

    /// Pauses one app. Also called when Now Playing hands over from one app to another.
    func pause(_ app: String) {
        guard isEnabled(), !app.isEmpty else { return }
        if let last = lastPause[app], Date().timeIntervalSince(last) < 1 { return }
        lastPause[app] = Date()
        #if DOCKY_DEBUG
        debugLog("pause \(app)")
        if ProcessInfo.processInfo.environment["DOCKY_ARBITER_DRYRUN"] != nil { return }
        #endif
        sendToBridge("pauseapp \(app)")
        guard Self.scriptable.contains(app) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.audio.isOutputting(app) else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                var error: NSDictionary?
                NSAppleScript(source: "tell application id \"\(app)\" to pause")?.executeAndReturnError(&error)
            }
        }
    }
}
