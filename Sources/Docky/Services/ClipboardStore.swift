import AppKit
import Combine
import QuickLookThumbnailing
import UniformTypeIdentifiers

struct ClipItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var path: String
    var addedAt = Date()

    var url: URL { URL(fileURLWithPath: path) }
    var name: String { FileManager.default.displayName(atPath: path) }
}

/// The island's file shelf: things dropped on the Clipboard tab stay until removed, and can
/// be dragged back out into any app or shared.
final class ClipboardStore: ObservableObject {
    @Published private(set) var items: [ClipItem] = []
    @Published private(set) var thumbnails: [UUID: NSImage] = [:]

    static let supportedTypes: [UTType] = [.fileURL, .image, .plainText]

    private static var baseURL: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Docky", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Where dropped text and images (things that aren't files yet) are saved.
    private static var droppedFolder: URL {
        let url = baseURL.appendingPathComponent("Clipboard", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static var fileURL: URL { baseURL.appendingPathComponent("clipboard.json") }

    init() {
        load()
    }

    // MARK: Adding

    func add(_ urls: [URL]) {
        var changed = false
        for raw in urls where raw.isFileURL {
            // Finder often hands over file *reference* URLs (file:///.file/id=…); resolve them.
            let url = (raw as NSURL).filePathURL ?? raw
            let path = url.standardizedFileURL.path
            guard FileManager.default.fileExists(atPath: path), !items.contains(where: { $0.path == path }) else { continue }
            let item = ClipItem(path: path)
            items.insert(item, at: 0)
            makeThumbnail(for: item)
            changed = true
        }
        if changed { save() }
        #if DOCKY_DEBUG
        dockyDebugLog("clipboard add \(urls.map(\.path)) -> \(items.count) items")
        #endif
    }

    /// Accepts files, images and text from a drop and keeps them. Returns true if anything was usable.
    @discardableResult
    func add(providers: [NSItemProvider]) -> Bool {
        Self.resolve(providers) { [weak self] urls in self?.add(urls) }
    }

    /// Turns dropped items into file URLs (saving text and images as files), without keeping them.
    @discardableResult
    static func resolve(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) -> Bool {
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()
        func collect(_ url: URL?) {
            guard let url else { return }
            lock.lock(); urls.append(url); lock.unlock()
        }

        var accepted = false
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                accepted = true
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    #if DOCKY_DEBUG
                    dockyDebugLog("drop provided url \(url?.absoluteString ?? "nil")")
                    #endif
                    collect(url?.isFileURL == true ? ((url! as NSURL).filePathURL ?? url) : nil)
                    group.leave()
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                accepted = true
                group.enter()
                _ = provider.loadObject(ofClass: NSImage.self) { image, _ in
                    if let image = image as? NSImage,
                       let tiff = image.tiffRepresentation,
                       let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                        collect(writeDropped(png, ext: "png", base: "Image"))
                    }
                    group.leave()
                }
            } else if provider.canLoadObject(ofClass: NSString.self) {
                accepted = true
                group.enter()
                _ = provider.loadObject(ofClass: NSString.self) { text, _ in
                    if let text = text as? String, !text.isEmpty {
                        collect(writeDropped(Data(text.utf8), ext: "txt", base: textTitle(text)))
                    }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) { completion(urls) }
        return accepted
    }

    private static func textTitle(_ text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Text"
        let cleaned = firstLine.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        return String(cleaned.prefix(40)).isEmpty ? "Text" : String(cleaned.prefix(40))
    }

    private static func writeDropped(_ data: Data, ext: String, base: String) -> URL? {
        var url = droppedFolder.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = droppedFolder.appendingPathComponent("\(base) \(n).\(ext)")
            n += 1
        }
        return (try? data.write(to: url)) != nil ? url : nil
    }

    // MARK: Removing

    func remove(_ item: ClipItem) {
        items.removeAll { $0.id == item.id }
        thumbnails[item.id] = nil
        // Files Docky created itself (dropped text/images) are cleaned up with the item.
        if item.path.hasPrefix(Self.droppedFolder.path) {
            try? FileManager.default.removeItem(atPath: item.path)
        }
        save()
    }

    func clear() {
        items.forEach { item in
            if item.path.hasPrefix(Self.droppedFolder.path) { try? FileManager.default.removeItem(atPath: item.path) }
        }
        items.removeAll()
        thumbnails.removeAll()
        save()
    }

    // MARK: Thumbnails

    private func makeThumbnail(for item: ClipItem) {
        thumbnails[item.id] = NSWorkspace.shared.icon(forFile: item.path)
        let request = QLThumbnailGenerator.Request(fileAt: item.url, size: CGSize(width: 96, height: 96),
                                                   scale: 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            guard let rep else { return }
            DispatchQueue.main.async { self?.thumbnails[item.id] = rep.nsImage }
        }
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let saved = try? JSONDecoder().decode([ClipItem].self, from: data) else { return }
        items = saved.filter { FileManager.default.fileExists(atPath: $0.path) }
        items.forEach(makeThumbnail)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}
