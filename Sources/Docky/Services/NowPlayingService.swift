import AppKit
import Combine
import SwiftUI

struct NowPlayingInfo: Equatable {
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var elapsed: Double
    var timestamp: Date
    var rate: Double
    var isPlaying: Bool
    var bundleID: String

    var hasContent: Bool { !title.isEmpty || !artist.isEmpty }
    var trackKey: String { "\(title)\u{1}\(artist)\u{1}\(album)" }

    /// Playback position extrapolated from the last report.
    func position(at date: Date = Date()) -> Double {
        guard isPlaying else { return min(max(0, elapsed), max(duration, elapsed)) }
        let speed = rate > 0 ? rate : 1
        let value = elapsed + date.timeIntervalSince(timestamp) * speed
        return duration > 0 ? min(max(0, value), duration) : max(0, value)
    }
}

/// Streams Now Playing state out of MediaRemote through the perl-hosted bridge
/// (see MediaBridge.m) and sends transport commands back.
final class NowPlayingService: ObservableObject {
    @Published private(set) var info: NowPlayingInfo?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var accent: Color = .white
    @Published private(set) var appIcon: NSImage?
    @Published private(set) var appName: String = ""
    /// Last time playback stopped; used to keep a paused track around for a little while.
    @Published private(set) var pausedAt: Date?
    /// Changes every time a new track starts. Used for the "track changed" peek.
    @Published private(set) var trackChangeCount = 0

    /// Decides which items are shown at all (used for "Only show music"). Call `refilter()`
    /// after changing it.
    var filter: (NowPlayingInfo) -> Bool = { _ in true }
    /// When true, starting playback in one app pauses the app that was playing before.
    var pauseOthersWhenSwitching: () -> Bool = { false }
    private lazy var arbiter = MediaArbiter(
        isEnabled: { [weak self] in self?.pauseOthersWhenSwitching() ?? false },
        send: { [weak self] command in self?.send(command) })
    /// Everything MediaRemote reports, including items the filter hides.
    private var rawInfo: NowPlayingInfo?

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private let ioQueue = DispatchQueue(label: "docky.nowplaying.io")
    private var stopping = false
    private var restartDelay: TimeInterval = 1
    private var currentArtworkKey = ""
    private var lastTrackKey: String?

    // MARK: Lifecycle

    func start() {
        stopping = false
        arbiter.start()
        guard process == nil else { return }
        launchBridge()
    }

    func stop() {
        stopping = true
        try? input?.close()
        process?.terminate()
        process = nil
    }

    private func launchBridge() {
        guard let dylib = Bundle.main.url(forResource: "DockyMediaBridge", withExtension: "dylib", subdirectory: nil)
            ?? Bundle.main.privateFrameworksURL?.appendingPathComponent("DockyMediaBridge.dylib")
        else {
            NSLog("Docky: media bridge missing from bundle")
            return
        }
        let script = """
        use DynaLoader;
        my $h = DynaLoader::dl_load_file($ARGV[0], 0) or die DynaLoader::dl_error();
        my $s = DynaLoader::dl_find_symbol($h, $ARGV[1]) or die DynaLoader::dl_error();
        DynaLoader::dl_install_xsub("main::bridge", $s);
        bridge();
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = ["-e", script, dylib.path, "docky_bridge_main"]
        let out = Pipe()
        let inp = Pipe()
        p.standardOutput = out
        p.standardInput = inp
        p.standardError = FileHandle.nullDevice

        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self.ioQueue.async { self.consume(chunk) }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.process = nil
                self.input = nil
                guard !self.stopping else { return }
                let delay = self.restartDelay
                self.restartDelay = min(30, self.restartDelay * 2)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, !self.stopping, self.process == nil else { return }
                    self.launchBridge()
                }
            }
        }
        do {
            try p.run()
            process = p
            input = inp.fileHandleForWriting
        } catch {
            NSLog("Docky: could not start media bridge: \(error)")
        }
    }

    private func consume(_ chunk: Data) {
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  object["type"] as? String == "now"
            else { continue }
            handle(object)
        }
    }

    /// Runs on the IO queue; decodes artwork off the main thread.
    private func handle(_ o: [String: Any]) {
        let next = NowPlayingInfo(
            title: o["title"] as? String ?? "",
            artist: o["artist"] as? String ?? "",
            album: o["album"] as? String ?? "",
            duration: (o["duration"] as? NSNumber)?.doubleValue ?? 0,
            elapsed: (o["elapsed"] as? NSNumber)?.doubleValue ?? 0,
            timestamp: Date(timeIntervalSince1970: (o["timestamp"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970),
            rate: (o["rate"] as? NSNumber)?.doubleValue ?? 0,
            isPlaying: (o["playing"] as? NSNumber)?.boolValue ?? false,
            bundleID: {
                let parent = o["parentBundleID"] as? String ?? ""
                return parent.isEmpty ? (o["bundleID"] as? String ?? "") : parent
            }()
        )

        var newArtwork: NSImage??
        var newAccent: Color?
        if let encoded = o["artwork"] as? String {
            if encoded.isEmpty {
                newArtwork = .some(nil)
            } else if let data = Data(base64Encoded: encoded), let image = NSImage(data: data) {
                newArtwork = .some(image)
                newAccent = image.islandAccentColor()
            }
        }

        DispatchQueue.main.async { [weak self] in
            self?.apply(next, artwork: newArtwork, accent: newAccent)
        }
    }

    private func apply(_ next: NowPlayingInfo, artwork newArtwork: NSImage??, accent newAccent: Color?) {
        let previous = rawInfo
        restartDelay = 1

        if let newArtwork {
            artwork = newArtwork
            accent = newAccent ?? .white
        }

        arbiter.noteNowPlaying(next.bundleID)
        if previous?.bundleID != next.bundleID {
            updateApp(bundleID: next.bundleID)
            // Something new started playing while another app was still going: pause the old one,
            // just like iPhone hands audio from one app to the next.
            if let previous, previous.isPlaying, next.isPlaying, !previous.bundleID.isEmpty,
               !next.bundleID.isEmpty, pauseOthersWhenSwitching() {
                arbiter.pause(previous.bundleID)
            }
        }

        if next.hasContent {
            if let last = lastTrackKey, last != next.trackKey, next.isPlaying, filter(next) {
                trackChangeCount += 1
            }
            lastTrackKey = next.trackKey
        }

        if next.isPlaying {
            pausedAt = nil
        } else if previous?.isPlaying == true {
            pausedAt = Date()
        } else if pausedAt == nil {
            // Already paused when we first saw it: don't resurrect it in the compact island.
            pausedAt = .distantPast
        }

        rawInfo = next.hasContent ? next : nil
        if !next.hasContent { artwork = nil }
        refilter()
    }

    func refilter() {
        let visible = rawInfo.flatMap { filter($0) ? $0 : nil }
        if visible != info { info = visible }
    }

    private func updateApp(bundleID: String) {
        guard !bundleID.isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else {
            appIcon = nil
            appName = ""
            return
        }
        appIcon = NSWorkspace.shared.icon(forFile: url.path)
        appName = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    #if DOCKY_DEBUG
    func debugFakeTrack(playing: Bool, title: String = "Midnight City", artist: String = "M83") {
        let size = NSSize(width: 300, height: 300)
        let image = NSImage(size: size, flipped: false) { rect in
            NSGradient(colors: [NSColor(srgbRed: 0.98, green: 0.3, blue: 0.55, alpha: 1),
                                NSColor(srgbRed: 0.45, green: 0.2, blue: 0.85, alpha: 1)])!.draw(in: rect, angle: -60)
            NSColor.white.withAlphaComponent(0.85).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 110, dy: 110)).fill()
            return true
        }
        artwork = image
        accent = image.islandAccentColor() ?? .white
        if rawInfo?.title != title { trackChangeCount += rawInfo == nil ? 0 : 1 }
        rawInfo = NowPlayingInfo(title: title, artist: artist, album: "Hurry Up, We're Dreaming", duration: 243,
                              elapsed: 61, timestamp: Date(), rate: playing ? 1 : 0, isPlaying: playing, bundleID: "com.apple.Music")
        pausedAt = playing ? nil : Date()
        updateApp(bundleID: "com.apple.Music")
        refilter()
    }
    #endif

    // MARK: Commands

    private func send(_ command: String) {
        guard let input else { return }
        ioQueue.async {
            try? input.write(contentsOf: Data((command + "\n").utf8))
        }
    }

    func togglePlayPause() {
        if var current = rawInfo {
            // Optimistic update so the button flips instantly.
            current.elapsed = current.position()
            current.timestamp = Date()
            current.isPlaying.toggle()
            current.rate = current.isPlaying ? 1 : 0
            rawInfo = current
            pausedAt = current.isPlaying ? nil : Date()
            refilter()
        }
        send("toggle")
    }

    func next() { send("next") }
    func previous() { send("prev") }

    func seek(to seconds: Double) {
        if var current = rawInfo {
            current.elapsed = seconds
            current.timestamp = Date()
            rawInfo = current
            refilter()
        }
        send("seek \(seconds)")
    }
}

extension NSImage {
    /// Average colour of the artwork, lifted so it reads well on black — like the
    /// tinted waveform on iPhone.
    func islandAccentColor() -> Color? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let size = 12
        guard let ctx = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let data = ctx.data else { return nil }
        let px = data.bindMemory(to: UInt8.self, capacity: size * size * 4)

        // Weight saturated pixels higher so a colourful cover doesn't average to grey.
        var r = 0.0, g = 0.0, b = 0.0, total = 0.0
        for i in 0..<(size * size) {
            let pr = Double(px[i * 4]) / 255, pg = Double(px[i * 4 + 1]) / 255, pb = Double(px[i * 4 + 2]) / 255
            let maxC = max(pr, pg, pb), minC = min(pr, pg, pb)
            let sat = maxC == 0 ? 0 : (maxC - minC) / maxC
            let weight = 0.15 + sat * sat * 2 + maxC * 0.3
            r += pr * weight; g += pg * weight; b += pb * weight; total += weight
        }
        guard total > 0 else { return nil }
        let color = NSColor(srgbRed: r / total, green: g / total, blue: b / total, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        color.usingColorSpace(.sRGB)?.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        if s < 0.12 { return Color(white: 0.92) }
        return Color(hue: Double(h), saturation: Double(min(1, s * 1.15)), brightness: Double(max(0.78, v)))
    }
}
