import AppKit
import SwiftUI

private typealias K = DockyPrefs.Key
private let store = DockyPrefs.store

// MARK: - General

struct GeneralPane: View {
    @EnvironmentObject var status: IslandStatus
    @AppStorage(K.launchAtLogin, store: store) private var launchAtLogin = false
    @AppStorage(K.showMenuBarIcon, store: store) private var showMenuBarIcon = true
    @AppStorage(K.display, store: store) private var display: DisplayChoice = .builtIn
    @AppStorage(K.style, store: store) private var style: IslandStyle = .automatic
    @AppStorage(K.use24Hour, store: store) private var use24Hour = false
    @AppStorage(K.playIntro, store: store) private var playIntro = true
    @AppStorage(K.autoUpdate, store: store) private var autoUpdate = true

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: islandIcon)
                        .resizable()
                        .frame(width: 54, height: 54)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Docky")
                            .font(.system(size: 15, weight: .semibold))
                        Text(status.isRunning ? "The island is running at the top of your screen." : "The island isn't running.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if status.isRunning {
                        Button("Setup…") { status.send(.showOnboarding) }
                        Button("Show Island") { status.preview() }
                        Button("Restart") { status.restart() }
                        Button("Quit") { status.quit() }
                    } else {
                        Button("Open Docky") { status.launch(then: .preview) }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                Toggle("Open Docky at login", isOn: $launchAtLogin)
                Toggle("Show Docky in the menu bar", isOn: $showMenuBarIcon)
                Toggle("Use 24-hour time", isOn: $use24Hour)
                LabeledContent {
                    HStack(spacing: 10) {
                        Button("Play Now") { status.send(.playIntro) }
                            .controlSize(.small)
                            .disabled(!status.isRunning)
                        Toggle("", isOn: $playIntro).labelsHidden().toggleStyle(.switch)
                    }
                } label: {
                    Text("Play the intro when Docky opens")
                    Text("The screen's edge lights up, sparks fly and the island drops in.")
                }
            }

            Section {
                LabeledContent {
                    HStack(spacing: 10) {
                        if status.update.hasPrefix("ready:") {
                            Button("Restart to Update") { status.send(.installUpdate) }
                                .buttonStyle(.borderedProminent)
                        } else {
                            Button("Check Now") { status.send(.checkForUpdates) }
                                .disabled(!status.isRunning || status.update == "checking" || status.update.hasPrefix("downloading:"))
                        }
                    }
                } label: {
                    Text("Docky \(DockyRelease.currentVersion)")
                    Text(updateText).foregroundStyle(status.update.hasPrefix("failed:") ? Color.orange : Color.secondary)
                }
                Toggle("Update Docky automatically", isOn: $autoUpdate)
            } header: {
                Text("Updates")
            } footer: {
                Text("Docky checks GitHub for new versions every few hours, downloads them in the background and installs them when it restarts.")
                    .settingsFootnote()
            }

            Section {
                Picker("Island style", selection: $style) {
                    ForEach(IslandStyle.allCases) { Text($0.title).tag($0) }
                }
                Picker("Show on", selection: $display) {
                    ForEach(DisplayChoice.allCases) { Text($0.title).tag($0) }
                }
            } footer: {
                Text("Automatic hugs the camera notch on MacBooks that have one, and floats as a capsule in the menu bar on displays that don't.")
                    .settingsFootnote()
            }
        }
        .formStyle(.grouped)
    }

    private var updateText: String {
        let u = status.update
        func value(_ prefix: String) -> String { String(u.dropFirst(prefix.count)) }
        if !status.isRunning { return "Open Docky to check for updates." }
        if u == "checking" { return "Checking for updates…" }
        if u.hasPrefix("latest:") { return "You're up to date." }
        if u.hasPrefix("downloading:") { return "Downloading Docky \(value("downloading:"))…" }
        if u.hasPrefix("ready:") { return "Docky \(value("ready:")) is ready to install." }
        if u.hasPrefix("installing:") { return "Installing Docky \(value("installing:"))…" }
        if u.hasPrefix("failed:") { return value("failed:") }
        return "Updates come from github.com/\(DockyRelease.repo)."
    }

    private var islandIcon: NSImage {
        if let url = status.islandURL { return NSWorkspace.shared.icon(forFile: url.path) }
        return NSApp.applicationIconImage
    }
}

// MARK: - Appearance

struct AppearancePane: View {
    @AppStorage(K.islandScale, store: store) private var scale = 1.0
    @AppStorage(K.animationFeel, store: store) private var feel: AnimationFeel = .smooth
    @AppStorage(K.hoverGrow, store: store) private var hoverGrow = true
    @AppStorage(K.hideWhenIdle, store: store) private var hideWhenIdle = false
    @AppStorage(K.compactShowsTitle, store: store) private var compactShowsTitle = true
    @AppStorage(K.showTimerBubble, store: store) private var showTimerBubble = true
    @AppStorage(K.hideInFullscreen, store: store) private var hideInFullscreen = true

    var body: some View {
        Form {
            Section {
                IslandPreview()
                    .listRowInsets(EdgeInsets())
            }

            Section {
                LabeledContent("Island size") {
                    HStack(spacing: 10) {
                        Image(systemName: "capsule.fill").font(.system(size: 9)).foregroundStyle(.secondary)
                        Slider(value: $scale, in: 0.8...1.3, step: 0.05)
                            .frame(width: 220)
                        Image(systemName: "capsule.fill").font(.system(size: 14)).foregroundStyle(.secondary)
                    }
                }
                Picker("Animation", selection: $feel) {
                    ForEach(AnimationFeel.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("Smooth is closest to iPhone. Snappy settles faster; Bouncy overshoots a little more.")
                    .settingsFootnote()
            }

            Section {
                Toggle("Grow slightly when the pointer is over the island", isOn: $hoverGrow)
                Toggle("Show the song title in the compact island", isOn: $compactShowsTitle)
                Toggle("Split a running timer into its own bubble while music plays", isOn: $showTimerBubble)
                Toggle("Hide the island when there's nothing to show", isOn: $hideWhenIdle)
                Toggle("Hide the island in fullscreen apps", isOn: $hideInFullscreen)
            } footer: {
                Text("A hidden island comes back as soon as you point at the top of the screen. Alarms, timers and reminders always show.")
                    .settingsFootnote()
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Interaction

struct InteractionPane: View {
    @AppStorage(K.swipeToExpand, store: store) private var swipe = true
    @AppStorage(K.clickToExpand, store: store) private var click = true
    @AppStorage(K.hoverToExpand, store: store) private var hover = false
    @AppStorage(K.hoverDelay, store: store) private var hoverDelay = 0.6
    @AppStorage(K.collapseDelay, store: store) private var collapseDelay = 0.35
    @AppStorage(K.haptics, store: store) private var haptics = true

    var body: some View {
        Form {
            Section {
                GestureIllustration()
                    .listRowInsets(EdgeInsets())
            }
            Section {
                Toggle(isOn: $swipe) {
                    Text("Swipe down to open")
                    Text("Point at the island and swipe down with two fingers. Swipe up to close.")
                }
                Toggle("Click to open", isOn: $click)
                Toggle("Open when the pointer rests on the island", isOn: $hover)
                if hover {
                    LabeledContent("Rest for") {
                        HStack {
                            Slider(value: $hoverDelay, in: 0.2...2.0, step: 0.1).frame(width: 200)
                            Text(String(format: "%.1f s", hoverDelay)).monospacedDigit().foregroundStyle(.secondary).frame(width: 44)
                        }
                    }
                }
            }
            Section {
                LabeledContent("Close after pointer leaves") {
                    HStack {
                        Slider(value: $collapseDelay, in: 0...1.5, step: 0.05).frame(width: 200)
                        Text(String(format: "%.2f s", collapseDelay)).monospacedDigit().foregroundStyle(.secondary).frame(width: 48)
                    }
                }
                Toggle(isOn: $haptics) {
                    Text("Haptic feedback")
                    Text("A gentle click on Force Touch trackpads when the island opens.")
                }
            }
        }
        .formStyle(.grouped)
        .animation(.easeInOut(duration: 0.2), value: hover)
    }
}

// MARK: - Now Playing

struct NowPlayingPane: View {
    @AppStorage(K.nowPlayingEnabled, store: store) private var enabled = true
    @AppStorage(K.showEqualizer, store: store) private var equalizer = true
    @AppStorage(K.tintFromArtwork, store: store) private var tint = true
    @AppStorage(K.trackChangePeek, store: store) private var peek = true
    @AppStorage(K.pausedLinger, store: store) private var linger = 30.0
    @AppStorage(K.musicOnly, store: store) private var musicOnly = false
    @AppStorage(K.compactShowsTitle, store: store) private var showsTitle = true
    @AppStorage(K.autoPauseOthers, store: store) private var autoPause = true

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $enabled) {
                    Text("Show what's playing")
                    Text("Works with Music, Spotify, Podcasts, TV, browsers and any app that reports Now Playing to macOS.")
                }
            }
            Section {
                Toggle(isOn: $musicOnly) {
                    Text("Only show music")
                    Text("Always shows Spotify, Music and other music apps. From browsers and video apps, only song-length media (1–5 minutes) shows, so Shorts and long videos stay out of the island.")
                }
                Toggle(isOn: $autoPause) {
                    Text("Pause other media when something starts playing")
                    Text("Start a video and your music pauses; start music and the video pauses — one thing plays at a time.")
                }
                Toggle(isOn: $showsTitle) {
                    Text("Show the song title in the island")
                    Text("When off, the compact island shows only artwork and the waveform, and new songs don't pop up their name.")
                }
            }
            .disabled(!enabled)
            Section {
                Toggle("Animated waveform", isOn: $equalizer)
                Toggle("Tint controls with the artwork's colors", isOn: $tint)
                Toggle("Briefly show the new song when the track changes", isOn: $peek)
                    .disabled(!showsTitle)
                LabeledContent("Keep paused media in the island") {
                    Picker("", selection: $linger) {
                        Text("Hide right away").tag(0.0)
                        Text("10 seconds").tag(10.0)
                        Text("30 seconds").tag(30.0)
                        Text("1 minute").tag(60.0)
                        Text("5 minutes").tag(300.0)
                        Text("Always").tag(86_400.0 * 365)
                    }
                    .labelsHidden()
                    .frame(width: 170)
                }
            }
            .disabled(!enabled)
        }
        .formStyle(.grouped)
    }
}

// MARK: - System indicators

struct IndicatorsPane: View {
    @EnvironmentObject var status: IslandStatus
    @AppStorage(K.hudVolume, store: store) private var volume = true
    @AppStorage(K.hudBrightness, store: store) private var brightness = true
    @AppStorage(K.hudFocus, store: store) private var focus = true
    @AppStorage(K.hudDevices, store: store) private var devices = true
    @AppStorage(K.hudCharging, store: store) private var charging = true
    @AppStorage(K.replaceSystemHUD, store: store) private var replace = true

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $volume) { Label("Volume", systemImage: "speaker.wave.2.fill") }
                Toggle(isOn: $brightness) { Label("Brightness", systemImage: "sun.max.fill") }
                Toggle(isOn: $focus) { Label("Focus on and off", systemImage: "moon.fill") }
                Toggle(isOn: $devices) { Label("AirPods, Bluetooth devices and drives", systemImage: "airpodspro") }
                Toggle(isOn: $charging) { Label("Plugging in your Mac", systemImage: "battery.100percent.bolt") }
            } header: {
                Text("Show in the island")
            }
            Section {
                Toggle(isOn: $replace) {
                    Text("Only show volume and brightness in the island")
                    Text("Docky takes over the volume and brightness keys so the macOS overlay doesn't appear.")
                }
                PermissionRow(title: "Accessibility", state: status.permissions["ax"],
                              explanation: "Needed to take over the volume and brightness keys.") {
                    status.send(.requestAccessibility)
                }
                PermissionRow(title: "Focus status", state: status.permissions["focus"],
                              explanation: "Needed to see when a Focus turns on or off.") {
                    status.send(.requestFocus)
                }
            } footer: {
                Text("To show which Focus is on (Work, Sleep…) with its icon, also add Docky under Privacy & Security → Full Disk Access. Without it the island shows \"Focus On\" and \"Focus Off\".")
                    .settingsFootnote()
            }
        }
        .formStyle(.grouped)
    }
}

/// "Granted" / "Not allowed" plus a button that asks the island to request the permission.
struct PermissionRow: View {
    let title: String
    let state: Int?
    let explanation: String
    let request: () -> Void

    var body: some View {
        LabeledContent {
            HStack(spacing: 10) {
                if state == 1 {
                    Label("Allowed", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .labelStyle(.titleAndIcon)
                } else {
                    Button(state == 2 ? "Open Settings…" : "Allow…", action: request)
                }
            }
        } label: {
            Text(title)
            Text(explanation)
        }
    }
}

// MARK: - Calendar

struct CalendarPane: View {
    @EnvironmentObject var status: IslandStatus
    @AppStorage(K.showCalendar, store: store) private var showCalendar = true

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $showCalendar) {
                    Text("Show the Calendar tab")
                    Text("The next seven days at a glance, with a Join button for video calls.")
                }
                PermissionRow(title: "Calendar access", state: status.permissions["cal"],
                              explanation: "Docky reads events from the Calendar app.") {
                    status.send(.requestCalendar)
                }
            }
            Section {
                LabeledContent {
                    Button("Add Google Account…") {
                        for s in ["x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension",
                                  "x-apple.systempreferences:com.apple.preferences.internetaccounts"] {
                            if let u = URL(string: s), NSWorkspace.shared.open(u) { break }
                        }
                    }
                } label: {
                    Text("Google Calendar")
                    Text("Add your Google account to macOS with Calendars turned on, and its events appear in Docky.")
                }
                LabeledContent("Apple Calendar") {
                    Button("Open Calendar") {
                        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
                            NSWorkspace.shared.openApplication(at: app, configuration: .init())
                        }
                    }
                }
            } footer: {
                Text("Any calendar you see in the Calendar app shows in Docky: iCloud, Google, Exchange, Outlook and subscribed calendars.")
                    .settingsFootnote()
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Alarms & Reminders

struct ClockPane: View {
    @EnvironmentObject var status: IslandStatus
    @AppStorage(K.alarmSound, store: store) private var alarmSound = "Radar"
    @AppStorage(K.timerSound, store: store) private var timerSound = "Glass"
    @AppStorage(K.reminderSound, store: store) private var reminderSound = "Ping"
    @AppStorage(K.snoozeMinutes, store: store) private var snooze = 9

    var body: some View {
        Form {
            Section {
                SoundPicker(title: "Alarm sound", selection: $alarmSound)
                SoundPicker(title: "Timer sound", selection: $timerSound)
                SoundPicker(title: "Reminder sound", selection: $reminderSound)
            }
            Section {
                Stepper(value: $snooze, in: 1...30) {
                    LabeledContent("Snooze for", value: "\(snooze) minute\(snooze == 1 ? "" : "s")")
                }
            }
            Section {
                LabeledContent("Try it") {
                    HStack {
                        Button("Ring a Test Alarm") { run(.testAlarm) }
                        Button("Clear Completed Reminders") { run(.clearCompleted) }
                    }
                }
            } footer: {
                Text("Timers, alarms and reminders live inside the island. Point at it, swipe down, and pick the Timers or Reminders & Alarms tab at the top to add your own.")
                    .settingsFootnote()
            }
        }
        .formStyle(.grouped)
    }

    private func run(_ command: DockyIPC.Command) {
        if status.isRunning { status.send(command) } else { status.launch(then: command) }
    }
}

struct SoundPicker: View {
    let title: String
    @Binding var selection: String
    @State private var player: NSSound?

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Picker("", selection: $selection) {
                    ForEach(DockySounds.all, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 160)
                Button {
                    play()
                } label: {
                    Image(systemName: "play.circle.fill").font(.system(size: 16))
                }
                .buttonStyle(.borderless)
                .help("Preview")
            }
        }
        .onChange(of: selection) { _, _ in play() }
    }

    private func play() {
        player?.stop()
        guard let url = DockySounds.url(for: selection) else { return }
        player = NSSound(contentsOf: url, byReference: true)
        player?.play()
    }
}

// MARK: - Lock screen

struct LockScreenPane: View {
    @AppStorage(K.lockScreenEnabled, store: store) private var enabled = true

    var body: some View {
        Form {
            Section {
                LockIllustration(enabled: enabled)
                    .listRowInsets(EdgeInsets())
            }
            Section {
                Toggle(isOn: $enabled) {
                    Text("Show the island on the Lock Screen")
                    Text("While your Mac is locked the island shows a lock. Unlock with Touch ID or your password and it springs open before tucking away.")
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - About

struct AboutPane: View {
    @EnvironmentObject var status: IslandStatus

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            if let url = status.islandURL {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 128, height: 128)
                    .shadow(color: .black.opacity(0.2), radius: 10, y: 6)
            }
            Text("Docky")
                .font(.system(size: 28, weight: .bold))
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                .foregroundStyle(.secondary)
            Text("A Dynamic Island for your Mac — music, timers, alarms and reminders, right at the top of your screen.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
            Spacer()
            Text("Docky reads Now Playing information through macOS's media system. Nothing leaves your Mac.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension Text {
    func settingsFootnote() -> some View {
        self.font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
