import Foundation

/// Identifiers shared by Docky (the island) and Docky Settings.
enum DockyIPC {
    static let suiteName = "com.totallyrat.docky.shared"
    static let islandBundleID = "com.totallyrat.docky"
    static let settingsBundleID = "com.totallyrat.docky.settings"

    /// Posted by Docky Settings whenever a preference changes.
    static let settingsChanged = Notification.Name("com.totallyrat.docky.settingsChanged")
    /// Posted by Docky Settings to ask the island to do something. `object` carries the command string.
    static let command = Notification.Name("com.totallyrat.docky.command")
    /// Posted by the island in answer to `reportPermissions`; `object` is e.g. "ax=1,cal=0,focus=1,bt=1".
    static let permissions = Notification.Name("com.totallyrat.docky.permissions")
    /// Posted by the island when it launches or quits so the settings window can refresh its status.
    static let islandStatus = Notification.Name("com.totallyrat.docky.status")

    enum Command: String {
        case preview, quit, clearCompleted, testAlarm, openTimers, openReminders, playIntro, openClipboard
        case openCalendar, requestAccessibility, requestCalendar, requestFocus, reportPermissions, showOnboarding
    }
}

enum IslandStyle: String, CaseIterable, Identifiable {
    case automatic, notch, floating
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .notch: return "Notch"
        case .floating: return "Floating"
        }
    }
}

enum AnimationFeel: String, CaseIterable, Identifiable {
    case smooth, snappy, bouncy
    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var response: Double {
        switch self {
        case .smooth: return 0.52
        case .snappy: return 0.36
        case .bouncy: return 0.58
        }
    }

    var damping: Double {
        switch self {
        case .smooth: return 0.80
        case .snappy: return 0.86
        case .bouncy: return 0.66
        }
    }
}

enum DisplayChoice: String, CaseIterable, Identifiable {
    case builtIn, main
    var id: String { rawValue }
    var title: String {
        switch self {
        case .builtIn: return "Built-in Display"
        case .main: return "Main Display"
        }
    }
}

/// Every tweakable preference, with defaults. Both apps read through this so keys never drift.
struct DockyPrefs: Equatable {
    enum Key {
        static let style = "style"
        static let display = "display"
        static let showMenuBarIcon = "showMenuBarIcon"
        static let launchAtLogin = "launchAtLogin"
        static let hideWhenIdle = "hideWhenIdle"
        static let islandScale = "islandScale"
        static let animationFeel = "animationFeel"
        static let hoverGrow = "hoverGrow"
        static let swipeToExpand = "swipeToExpand"
        static let clickToExpand = "clickToExpand"
        static let hoverToExpand = "hoverToExpand"
        static let hoverDelay = "hoverDelay"
        static let collapseDelay = "collapseDelay"
        static let haptics = "haptics"
        static let nowPlayingEnabled = "nowPlayingEnabled"
        static let showEqualizer = "showEqualizer"
        static let tintFromArtwork = "tintFromArtwork"
        static let compactShowsTitle = "compactShowsTitle"
        static let trackChangePeek = "trackChangePeek"
        static let pausedLinger = "pausedLinger"
        static let showTimerBubble = "showTimerBubble"
        static let lockScreenEnabled = "lockScreenEnabled"
        static let alarmSound = "alarmSound"
        static let timerSound = "timerSound"
        static let reminderSound = "reminderSound"
        static let snoozeMinutes = "snoozeMinutes"
        static let use24Hour = "use24Hour"
        static let musicOnly = "musicOnly"
        static let hideInFullscreen = "hideInFullscreen"
        static let playIntro = "playIntro"
        static let showCalendar = "showCalendar"
        static let hudVolume = "hudVolume"
        static let hudBrightness = "hudBrightness"
        static let hudFocus = "hudFocus"
        static let hudDevices = "hudDevices"
        static let hudCharging = "hudCharging"
        static let replaceSystemHUD = "replaceSystemHUD"
        static let autoPauseOthers = "autoPauseOthers"
    }

    static let defaults: [String: Any] = [
        Key.style: IslandStyle.automatic.rawValue,
        Key.display: DisplayChoice.builtIn.rawValue,
        Key.showMenuBarIcon: true,
        Key.launchAtLogin: false,
        Key.hideWhenIdle: false,
        Key.islandScale: 1.0,
        Key.animationFeel: AnimationFeel.smooth.rawValue,
        Key.hoverGrow: true,
        Key.swipeToExpand: true,
        Key.clickToExpand: true,
        Key.hoverToExpand: false,
        Key.hoverDelay: 0.6,
        Key.collapseDelay: 0.35,
        Key.haptics: true,
        Key.nowPlayingEnabled: true,
        Key.showEqualizer: true,
        Key.tintFromArtwork: true,
        Key.compactShowsTitle: true,
        Key.trackChangePeek: true,
        Key.pausedLinger: 30.0,
        Key.showTimerBubble: true,
        Key.lockScreenEnabled: true,
        Key.alarmSound: "Radar",
        Key.timerSound: "Glass",
        Key.reminderSound: "Ping",
        Key.snoozeMinutes: 9,
        Key.use24Hour: false,
        Key.musicOnly: false,
        Key.hideInFullscreen: true,
        Key.playIntro: true,
        Key.showCalendar: true,
        Key.hudVolume: true,
        Key.hudBrightness: true,
        Key.hudFocus: true,
        Key.hudDevices: true,
        Key.hudCharging: true,
        Key.replaceSystemHUD: true,
        Key.autoPauseOthers: true,
    ]

    static let store: UserDefaults = {
        let d = UserDefaults(suiteName: DockyIPC.suiteName) ?? .standard
        d.register(defaults: defaults)
        return d
    }()

    var style: IslandStyle
    var display: DisplayChoice
    var showMenuBarIcon: Bool
    var launchAtLogin: Bool
    var hideWhenIdle: Bool
    var islandScale: Double
    var animationFeel: AnimationFeel
    var hoverGrow: Bool
    var swipeToExpand: Bool
    var clickToExpand: Bool
    var hoverToExpand: Bool
    var hoverDelay: Double
    var collapseDelay: Double
    var haptics: Bool
    var nowPlayingEnabled: Bool
    var showEqualizer: Bool
    var tintFromArtwork: Bool
    var compactShowsTitle: Bool
    var trackChangePeek: Bool
    var pausedLinger: Double
    var showTimerBubble: Bool
    var lockScreenEnabled: Bool
    var alarmSound: String
    var timerSound: String
    var reminderSound: String
    var snoozeMinutes: Int
    var use24Hour: Bool
    var musicOnly: Bool
    var hideInFullscreen: Bool
    var playIntro: Bool
    var showCalendar: Bool
    var hudVolume: Bool
    var hudBrightness: Bool
    var hudFocus: Bool
    var hudDevices: Bool
    var hudCharging: Bool
    var replaceSystemHUD: Bool
    var autoPauseOthers: Bool

    init(_ d: UserDefaults = DockyPrefs.store) {
        style = IslandStyle(rawValue: d.string(forKey: Key.style) ?? "") ?? .automatic
        display = DisplayChoice(rawValue: d.string(forKey: Key.display) ?? "") ?? .builtIn
        showMenuBarIcon = d.bool(forKey: Key.showMenuBarIcon)
        launchAtLogin = d.bool(forKey: Key.launchAtLogin)
        hideWhenIdle = d.bool(forKey: Key.hideWhenIdle)
        islandScale = min(1.3, max(0.8, d.double(forKey: Key.islandScale)))
        animationFeel = AnimationFeel(rawValue: d.string(forKey: Key.animationFeel) ?? "") ?? .smooth
        hoverGrow = d.bool(forKey: Key.hoverGrow)
        swipeToExpand = d.bool(forKey: Key.swipeToExpand)
        clickToExpand = d.bool(forKey: Key.clickToExpand)
        hoverToExpand = d.bool(forKey: Key.hoverToExpand)
        hoverDelay = max(0.1, d.double(forKey: Key.hoverDelay))
        collapseDelay = max(0, d.double(forKey: Key.collapseDelay))
        haptics = d.bool(forKey: Key.haptics)
        nowPlayingEnabled = d.bool(forKey: Key.nowPlayingEnabled)
        showEqualizer = d.bool(forKey: Key.showEqualizer)
        tintFromArtwork = d.bool(forKey: Key.tintFromArtwork)
        compactShowsTitle = d.bool(forKey: Key.compactShowsTitle)
        trackChangePeek = d.bool(forKey: Key.trackChangePeek)
        pausedLinger = max(0, d.double(forKey: Key.pausedLinger))
        showTimerBubble = d.bool(forKey: Key.showTimerBubble)
        lockScreenEnabled = d.bool(forKey: Key.lockScreenEnabled)
        alarmSound = d.string(forKey: Key.alarmSound) ?? "Radar"
        timerSound = d.string(forKey: Key.timerSound) ?? "Glass"
        reminderSound = d.string(forKey: Key.reminderSound) ?? "Ping"
        snoozeMinutes = max(1, d.integer(forKey: Key.snoozeMinutes))
        use24Hour = d.bool(forKey: Key.use24Hour)
        musicOnly = d.bool(forKey: Key.musicOnly)
        hideInFullscreen = d.bool(forKey: Key.hideInFullscreen)
        playIntro = d.bool(forKey: Key.playIntro)
        showCalendar = d.bool(forKey: Key.showCalendar)
        hudVolume = d.bool(forKey: Key.hudVolume)
        hudBrightness = d.bool(forKey: Key.hudBrightness)
        hudFocus = d.bool(forKey: Key.hudFocus)
        hudDevices = d.bool(forKey: Key.hudDevices)
        hudCharging = d.bool(forKey: Key.hudCharging)
        replaceSystemHUD = d.bool(forKey: Key.replaceSystemHUD)
        autoPauseOthers = d.bool(forKey: Key.autoPauseOthers)
    }
}

/// Sounds the user can choose for alerts. "Radar" is synthesized by Docky; the rest are system sounds.
enum DockySounds {
    static let synthesized = ["Radar", "Chime"]

    static var all: [String] {
        var names = synthesized
        for dir in soundDirectories {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            for f in files.sorted() where f.hasSuffix(".aiff") || f.hasSuffix(".wav") || f.hasSuffix(".caf") || f.hasSuffix(".m4a") {
                let name = (f as NSString).deletingPathExtension
                if !names.contains(name) { names.append(name) }
            }
        }
        return names
    }

    static var soundDirectories: [String] {
        ["/System/Library/Sounds", (NSHomeDirectory() as NSString).appendingPathComponent("Library/Sounds")]
    }

    static func url(for name: String) -> URL? {
        if let bundled = Bundle.main.url(forResource: name, withExtension: "wav", subdirectory: "Sounds") {
            return bundled
        }
        for dir in soundDirectories {
            for ext in ["aiff", "wav", "caf", "m4a"] {
                let path = (dir as NSString).appendingPathComponent("\(name).\(ext)")
                if FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
            }
        }
        return nil
    }
}

/// Proportions of the floating (no-notch) island, shared with the Settings preview.
/// Roughly iPhone-like: about 3.3 : 1 when idle.
enum FloatingGeometry {
    static let height: CGFloat = 34
    static let topOffset: CGFloat = 3
    static let idleWidth: CGFloat = 112
    static let lockWidth: CGFloat = 124
    static let musicWidth: CGFloat = 236
    static let musicWidthNoTitle: CGFloat = 180
    static let timerWidth: CGFloat = 172
    static let peekSize = CGSize(width: 350, height: 78)
    static let alertSize = CGSize(width: 410, height: 98)
    static let expandedWidth: CGFloat = 440
}

/// Decides whether a Now Playing item counts as music for the "Only show music" setting.
enum MusicClassifier {
    /// Apps that only ever play music, so anything they report is shown.
    static let musicApps: Set<String> = [
        "com.spotify.client", "com.apple.Music", "com.apple.iTunes", "com.tidal.desktop",
        "com.deezer.deezer-desktop", "com.amazon.music", "com.qobuz.QobuzDesktop",
        "com.github.th-ch.youtube-music", "com.coppertino.Vox", "com.swinsian.Swinsian",
        "com.roon.Roon", "tv.plex.plexamp", "com.audirvana.Audirvana-Studio", "sh.cider.electron",
        "com.ciderapp.Cider", "com.soundcloud.desktop", "com.pandora.desktop", "com.nugs.app",
    ]

    /// Anything else (browsers, video players) counts as music only if it is song-length:
    /// longer than a minute (so Shorts and Reels are skipped) and at most five minutes.
    static func isMusic(bundleID: String, duration: Double) -> Bool {
        if musicApps.contains(bundleID) { return true }
        return duration >= 60 && duration <= 300
    }
}
