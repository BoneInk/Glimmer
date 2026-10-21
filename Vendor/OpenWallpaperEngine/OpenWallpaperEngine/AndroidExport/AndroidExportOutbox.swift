import Foundation

/// "Android exports": every package an Android export wrote (from the library, Scene Edit / Export's
/// Android Export tab or MCP) and every `.mpkg` added by hand, so "Send over Wi-Fi" can share
/// exports made one by one all at once. Kept in `<Application Support>/Android Exports/`:
/// `exports.json` and each entry's preview picture (the wallpaper's own, so a GIF stays animated).
/// Entries whose package is gone are dropped when the list loads or is shown.
@MainActor
final class AndroidExportOutbox: ObservableObject {
    struct Entry: Codable, Equatable, Identifiable {
        /// Never reused: the Wi-Fi page addresses the file by it.
        var number: Int
        var url: URL
        var title: String
        var kind: AndroidWiFiFile.Kind
        var size: Int64
        /// The Android device the export was framed for, when it chose one.
        var device: String?
        var date: Date
        /// The preview's file name in `previews`.
        var preview: String?
        /// The devices (IPv4 addresses) that downloaded it whole.
        var downloadedBy: [String] = []

        var id: Int { number }
        var isDownloaded: Bool { !downloadedBy.isEmpty }
    }

    private struct Stored: Codable {
        var next: Int
        var entries: [Entry]
    }

    static let shared = AndroidExportOutbox(
        directory: AppStorageLocation.current.supportDirectory.appending(path: "Android Exports", directoryHint: .isDirectory))

    @Published private(set) var entries: [Entry] = []
    let directory: URL
    var previews: URL { directory.appending(path: "previews", directoryHint: .isDirectory) }
    private var file: URL { directory.appending(path: "exports.json") }
    private var next = 1

    init(directory: URL) {
        self.directory = directory
        do {
            let stored = try JSONDecoder().decode(Stored.self, from: Data(contentsOf: file))
            entries = stored.entries
            next = stored.next
        } catch CocoaError.fileReadNoSuchFile {
            // Nothing exported yet.
        } catch {
            OWELog.error(.app, "Android exports: \(file.path(percentEncoded: false)) can't be read: \(error)")
        }
        prune()
    }

    /// The preview picture of `entry`, if it has one.
    func previewURL(of entry: Entry) -> URL? { entry.preview.map { previews.appending(path: $0) } }

    /// Adds a finished export's packages (replacing older entries of the same files), with a copy
    /// of each wallpaper's preview.
    func record(_ batch: AndroidExportBatch, device: String? = nil) {
        for output in batch.outputs {
            add(url: output.url, title: output.title, kind: AndroidWiFiFile.kind(type: output.type, mode: output.mode),
                size: output.size, device: device, preview: output.previewURL.map(PreviewSource.file))
        }
    }

    /// Adds `.mpkg` files chosen by hand, read from their own project.json and preview; only WE
    /// mobile packages (`PKGM`).
    func add(packages: [URL]) async throws {
        let found = try await Task.detached(priority: .userInitiated) {
            try packages.map { url in (url, try AndroidExportOutbox.describe(package: url)) }
        }.value
        for (url, package) in found {
            add(url: url, title: package.title, kind: package.kind, size: package.size, device: nil,
                preview: package.preview.map { PreviewSource.data($0.data, extension: $0.extension) })
        }
    }

    func remove(_ numbers: Set<Int>) {
        let removed = entries.filter { numbers.contains($0.number) }
        guard !removed.isEmpty else { return }
        entries.removeAll { numbers.contains($0.number) }
        removePreviews(of: removed)
        save()
    }

    func markDownloaded(_ number: Int, by device: String) {
        guard let index = entries.firstIndex(where: { $0.number == number }), !entries[index].downloadedBy.contains(device) else { return }
        entries[index].downloadedBy.append(device)
        save()
    }

    /// Drops the entries whose package no longer exists.
    func prune() {
        let gone = entries.filter { !FileManager.default.fileExists(atPath: $0.url.path(percentEncoded: false)) }
        guard !gone.isEmpty else { return }
        OWELog.info(.app, "Android exports: dropping \(gone.count) whose package is gone")
        let numbers = Set(gone.map(\.number))
        entries.removeAll { numbers.contains($0.number) }
        removePreviews(of: gone)
        save()
    }

    /// The entries numbered `numbers`, as "Send over Wi-Fi" serves them, in the list's order and
    /// with download names unique among them.
    func wifiFiles(_ numbers: Set<Int>) -> [AndroidWiFiFile] {
        let chosen = entries.filter { numbers.contains($0.number) }
        let names = AndroidExportNaming.uniqueNames(chosen.map(\.title), taken: [])
        return zip(chosen, names).map { entry, name in
            AndroidWiFiFile(index: entry.number, title: entry.title, kind: entry.kind, url: entry.url, size: entry.size,
                            previewURL: previewURL(of: entry), downloadName: name, device: entry.device)
        }
    }

    // MARK: Adding

    private enum PreviewSource {
        case file(URL)
        case data(Data, extension: String)
    }

    private func add(url: URL, title: String, kind: AndroidWiFiFile.Kind, size: Int64, device: String?, preview: PreviewSource?) {
        let replaced = entries.filter { $0.url.standardizedFileURL == url.standardizedFileURL }
        entries.removeAll { $0.url.standardizedFileURL == url.standardizedFileURL }
        removePreviews(of: replaced)
        var entry = Entry(number: next, url: url, title: title, kind: kind, size: size, device: device, date: Date())
        next += 1
        if let preview {
            let name: String
            do {
                try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
                switch preview {
                case .file(let source):
                    name = "\(entry.number).\(source.pathExtension.lowercased())"
                    try FileManager.default.copyItem(at: source, to: previews.appending(path: name))
                case .data(let data, let pathExtension):
                    name = "\(entry.number).\(pathExtension)"
                    try data.write(to: previews.appending(path: name), options: .atomic)
                }
                entry.preview = name
            } catch {
                OWELog.error(.app, "Android exports: no preview for \(url.lastPathComponent): \(error)")
            }
        }
        entries.insert(entry, at: 0)
        save()
    }

    private func removePreviews(of removed: [Entry]) {
        for url in removed.compactMap(previewURL(of:)) {
            do {
                try FileManager.default.removeItem(at: url) // The list's own copy, not the wallpaper's.
            } catch {
                OWELog.error(.app, "Android exports: removing \(url.lastPathComponent) failed: \(error)")
            }
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(Stored(next: next, entries: entries)).write(to: file, options: .atomic)
        } catch {
            OWELog.error(.app, "Android exports: saving the list failed: \(error)")
        }
    }

    // MARK: Packages

    struct Package {
        var title: String
        var kind: AndroidWiFiFile.Kind
        var size: Int64
        var preview: (data: Data, extension: String)?
    }

    struct NotAPackage: LocalizedError {
        var name: String
        var reason: String?

        var errorDescription: String? {
            String(localized: "\(name) isn't a Wallpaper Engine mobile package (.mpkg).") + (reason.map { " \($0)" } ?? "")
        }
    }

    /// A WE mobile package's title, type and preview, from its own project.json.
    nonisolated static func describe(package url: URL) throws -> Package {
        guard url.pathExtension.lowercased() == AndroidExportNaming.fileExtension,
              let size = AndroidWiFiRouter.size(of: url) else {
            throw NotAPackage(name: url.lastPathComponent, reason: nil)
        }
        let package: PKGParser
        do {
            package = try PKGParser(url: url, magic: "PKGM")
        } catch {
            throw NotAPackage(name: url.lastPathComponent, reason: error.localizedDescription)
        }
        let project = try package.extractFile(named: "project.json").map { try JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? nil
        let type = (project?["type"] as? String)?.lowercased() ?? "scene"
        let file = project?["file"] as? String
        let kind: AndroidWiFiFile.Kind = type == "video" ? .video : file == AndroidPackageBuilder.videoFileName ? .scenePreRendered : .sceneDynamic
        let previewName = project?["preview"] as? String
        let preview = previewName.flatMap { name in
            package.extractFile(named: name).map { (data: $0, extension: URL(filePath: name).pathExtension.lowercased()) }
        }
        return Package(title: (project?["title"] as? String) ?? url.deletingPathExtension().lastPathComponent, kind: kind, size: size,
                       preview: preview)
    }
}
