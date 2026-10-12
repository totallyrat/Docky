import AppKit
import CryptoKit
import Security

/// Keeps Docky up to date from the latest GitHub release.
///
/// Checks a little after launch and every few hours, downloads `Docky.dmg` in the background,
/// copies both apps out of it and checks they're signed by the same certificate as the running
/// copy. The island then offers to restart; otherwise the update is installed when Docky quits.
final class Updater {
    enum State: Equatable {
        case idle, checking
        case upToDate(String)
        case downloading(String)
        case ready(String)
        case installing(String)
        case failed(String)

        var wire: String {
            switch self {
            case .idle: return "idle"
            case .checking: return "checking"
            case .upToDate(let v): return "latest:\(v)"
            case .downloading(let v): return "downloading:\(v)"
            case .ready(let v): return "ready:\(v)"
            case .installing(let v): return "installing:\(v)"
            case .failed(let m): return "failed:\(m)"
            }
        }
    }

    private(set) var state: State = .idle { didSet { postState() } }
    /// Called on the main queue when a new version has been downloaded and verified.
    var onReady: ((String) -> Void)?
    var isEnabled: () -> Bool = { true }

    private var timer: Timer?
    private var staged: (version: String, docky: URL, settings: URL?)?
    private var busy = false
    private let session = URLSession(configuration: .ephemeral)

    private static var folder: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("com.totallyrat.docky/Updates", isDirectory: true)
    }

    func start() {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        cleanUp()
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in
            guard let self, self.isEnabled() else { return }
            self.check(userInitiated: false)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            guard let self, self.isEnabled() else { return }
            self.check(userInitiated: false)
        }
    }

    func postState() {
        DistributedNotificationCenter.default().postNotificationName(
            DockyIPC.updateStatus, object: state.wire, userInfo: nil, deliverImmediately: true)
    }

    // MARK: Checking and downloading

    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
            let size: Int
            let digest: String?
        }
        let tag_name: String
        let draft: Bool?
        let prerelease: Bool?
        let assets: [Asset]
    }

    func check(userInitiated: Bool) {
        if busy { return }
        if case .ready = state { postState(); return }
        busy = true
        state = .checking
        var request = URLRequest(url: DockyRelease.latestAPI, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Docky/\(DockyRelease.currentVersion) (macOS)", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async { self?.handleRelease(data: data, response: response, error: error) }
        }.resume()
    }

    private func handleRelease(data: Data?, response: URLResponse?, error: Error?) {
        let current = DockyRelease.currentVersion
        guard let data, (response as? HTTPURLResponse)?.statusCode == 200,
              let release = try? JSONDecoder().decode(Release.self, from: data) else {
            finish(.failed(error?.localizedDescription ?? "Couldn't reach GitHub."))
            return
        }
        let version = release.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
        guard DockyRelease.isNewer(version, than: current), release.draft != true, release.prerelease != true else {
            finish(.upToDate(current))
            return
        }
        guard let asset = release.assets.first(where: { $0.name == "Docky.dmg" }) else {
            finish(.failed("Docky \(version) has no Mac download yet."))
            return
        }
        state = .downloading(version)
        session.downloadTask(with: asset.browser_download_url) { [weak self] location, response, error in
            guard let self else { return }
            // The temporary file disappears when this closure returns, so move it first.
            var dmg: URL?
            if let location, (response as? HTTPURLResponse)?.statusCode == 200 {
                try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
                let target = Self.folder.appendingPathComponent("Docky-\(version).dmg")
                try? FileManager.default.removeItem(at: target)
                if (try? FileManager.default.moveItem(at: location, to: target)) != nil { dmg = target }
            }
            guard let dmg else {
                DispatchQueue.main.async { self.finish(.failed(error?.localizedDescription ?? "The download didn't finish.")) }
                return
            }
            let result = Self.stage(dmg: dmg, version: version, expectedSize: asset.size, digest: asset.digest)
            DispatchQueue.main.async {
                switch result {
                case .success(let apps):
                    self.staged = (version, apps.docky, apps.settings)
                    self.finish(.ready(version))
                    self.onReady?(version)
                case .failure(let error):
                    self.finish(.failed(error.message))
                }
            }
        }.resume()
    }

    private func finish(_ state: State) {
        busy = false
        self.state = state
    }

    private struct UpdateError: Error { let message: String }

    /// Checks the download, copies the apps out of the disk image and verifies their signatures.
    private static func stage(dmg: URL, version: String, expectedSize: Int, digest: String?) -> Result<(docky: URL, settings: URL?), UpdateError> {
        let fm = FileManager.default
        defer { try? fm.removeItem(at: dmg) }
        let size = (try? fm.attributesOfItem(atPath: dmg.path)[.size] as? Int) ?? -1
        guard size == expectedSize else { return .failure(UpdateError(message: "The download was incomplete.")) }
        if let digest, digest.hasPrefix("sha256:"), let data = try? Data(contentsOf: dmg, options: .mappedIfSafe) {
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard hash == digest.dropFirst(7).lowercased() else { return .failure(UpdateError(message: "The download didn't match its checksum.")) }
        }

        let stageDir = folder.appendingPathComponent(version, isDirectory: true)
        let mount = folder.appendingPathComponent("mount-\(version)", isDirectory: true)
        try? fm.removeItem(at: stageDir)
        try? fm.createDirectory(at: stageDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: mount, withIntermediateDirectories: true)
        guard run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-noautoopen", "-readonly", "-mountpoint", mount.path]) else {
            return .failure(UpdateError(message: "Couldn't open the update."))
        }
        defer {
            _ = run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
            try? fm.removeItem(at: mount)
        }
        let docky = stageDir.appendingPathComponent("Docky.app")
        let settings = stageDir.appendingPathComponent("Docky Settings.app")
        guard run("/usr/bin/ditto", [mount.appendingPathComponent("Docky.app").path, docky.path]) else {
            return .failure(UpdateError(message: "The update is missing Docky.app."))
        }
        let hasSettings = run("/usr/bin/ditto", [mount.appendingPathComponent("Docky Settings.app").path, settings.path])

        // Only accept apps signed exactly like the copy that's running now.
        guard signedLikeThisApp(docky), !hasSettings || signedLikeThisApp(settings, identifierFrom: settingsInstalledURL) else {
            try? fm.removeItem(at: stageDir)
            return .failure(UpdateError(message: "The update isn't signed like this copy of Docky."))
        }
        return .success((docky, hasSettings ? settings : nil))
    }

    private static var settingsInstalledURL: URL? {
        let sibling = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Docky Settings.app")
        if FileManager.default.fileExists(atPath: sibling.path) { return sibling }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: DockyIPC.settingsBundleID)
    }

    /// True when `app` satisfies the designated requirement of the installed app it replaces
    /// (same bundle identifier, same signing certificate).
    private static func signedLikeThisApp(_ app: URL, identifierFrom installed: URL? = Bundle.main.bundleURL) -> Bool {
        var newCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &newCode) == errSecSuccess, let newCode,
              SecStaticCodeCheckValidity(newCode, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode), nil) == errSecSuccess
        else { return false }
        // Nothing installed to compare against (e.g. Docky Settings was never installed): the
        // new copy must still be signed with the same certificate as Docky itself.
        let reference = installed ?? Bundle.main.bundleURL
        var oldCode: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(reference as CFURL, [], &oldCode) == errSecSuccess, let oldCode,
              SecCodeCopyDesignatedRequirement(oldCode, [], &requirement) == errSecSuccess, let requirement
        else { return false }
        if installed == nil {
            // Compare certificates only, since the identifiers differ.
            return sameLeafCertificate(oldCode, newCode)
        }
        return SecStaticCodeCheckValidity(newCode, [], requirement) == errSecSuccess
    }

    private static func sameLeafCertificate(_ a: SecStaticCode, _ b: SecStaticCode) -> Bool {
        func leaf(_ code: SecStaticCode) -> Data? {
            var info: CFDictionary?
            guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
                  let dict = info as? [String: Any],
                  let certs = dict[kSecCodeInfoCertificates as String] as? [SecCertificate], let first = certs.first
            else { return nil }
            return SecCertificateCopyData(first) as Data
        }
        guard let x = leaf(a), let y = leaf(b) else { return false }
        return x == y
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    // MARK: Installing

    var hasStagedUpdate: Bool { staged != nil }

    /// Swaps in the new apps once Docky has quit (a tiny shell script waits for this process
    /// to exit), then reopens Docky if `relaunch` is set.
    @discardableResult
    func install(relaunch: Bool) -> Bool {
        guard let staged else { return false }
        let fm = FileManager.default
        let dockyDest = Bundle.main.bundleURL
        let folderDest = dockyDest.deletingLastPathComponent()
        guard fm.isWritableFile(atPath: folderDest.path) else {
            state = .failed("Docky can't write to \(folderDest.path). Download the update from GitHub instead.")
            NSWorkspace.shared.open(DockyRelease.releasesPage)
            return false
        }
        let settingsDest = Self.settingsInstalledURL ?? folderDest.appendingPathComponent("Docky Settings.app")
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: DockyIPC.settingsBundleID) { app.terminate() }

        let script = Self.folder.appendingPathComponent("install.sh")
        let body = """
        #!/bin/sh
        # Waits for Docky to quit, swaps in the new apps (restoring the old ones if a copy fails) and reopens Docky.
        PID="$1"; NEW_DOCKY="$2"; DOCKY="$3"; NEW_SETTINGS="$4"; SETTINGS="$5"; STAGE="$6"; RELAUNCH="$7"
        n=0
        while kill -0 "$PID" 2>/dev/null && [ $n -lt 150 ]; do sleep 0.2; n=$((n+1)); done
        replace() {
            [ -d "$1" ] || return 0
            rm -rf "$2.update-old"
            if [ -e "$2" ]; then mv "$2" "$2.update-old" || return 1; fi
            if /usr/bin/ditto "$1" "$2"; then rm -rf "$2.update-old"; else rm -rf "$2"; mv "$2.update-old" "$2"; return 1; fi
        }
        replace "$NEW_DOCKY" "$DOCKY"
        replace "$NEW_SETTINGS" "$SETTINGS"
        rm -rf "$STAGE"
        if [ "$RELAUNCH" = "1" ]; then /usr/bin/open "$DOCKY"; fi
        """
        do { try body.write(to: script, atomically: true, encoding: .utf8) } catch {
            state = .failed("Couldn't prepare the update.")
            return false
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier), staged.docky.path, dockyDest.path,
                       staged.settings?.path ?? "", settingsDest.path, staged.docky.deletingLastPathComponent().path, relaunch ? "1" : "0"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch {
            state = .failed("Couldn't start the update.")
            return false
        }
        state = .installing(staged.version)
        self.staged = nil
        return true
    }

    /// Removes leftovers: downloads and staged copies for versions that are already installed.
    private func cleanUp() {
        let fm = FileManager.default
        let current = DockyRelease.currentVersion
        for item in (try? fm.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? [] {
            var name = item.lastPathComponent
            if name.hasSuffix(".dmg") { name = String(name.dropLast(4)) }
            let version = name.replacingOccurrences(of: "Docky-", with: "").replacingOccurrences(of: "mount-", with: "")
            if item.lastPathComponent == "install.sh" || !DockyRelease.isNewer(version, than: current) {
                try? fm.removeItem(at: item)
            }
        }
        // A staged copy from last time that never got installed: offer it again.
        if let dir = (try? fm.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil))?
            .first(where: { DockyRelease.isNewer($0.lastPathComponent, than: current) && fm.fileExists(atPath: $0.appendingPathComponent("Docky.app").path) }) {
            let settings = dir.appendingPathComponent("Docky Settings.app")
            staged = (dir.lastPathComponent, dir.appendingPathComponent("Docky.app"), fm.fileExists(atPath: settings.path) ? settings : nil)
            state = .ready(dir.lastPathComponent)
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.onReady?(dir.lastPathComponent) }
        }
    }
}
