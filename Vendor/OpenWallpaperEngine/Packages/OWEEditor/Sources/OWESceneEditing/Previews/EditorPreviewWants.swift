import Foundation

/// How a Wallpaper Editor window hands its browser's missing previews to the app's background
/// pre-warm while one runs (`EditorPreviewPrewarmLock`), so its visible tiles go first instead of
/// a second helper competing for the GPU: each request is a file in the build's folder
/// (`.wanted/<time>-<id>.json`, the subjects in tile order), which the pre-warm takes before each
/// preview it starts. The editor then watches the cache for the files.
public struct EditorPreviewWants: Sendable {
    public let folder: URL

    public init(cache: EditorPreviewCache) {
        folder = cache.directory.appending(path: ".wanted", directoryHint: .isDirectory)
    }

    /// Posts a request for `subjects`.
    public func post(_ subjects: [EditorPreviewSubject], at date: Date = Date(), fileManager: FileManager = .default) throws {
        guard !subjects.isEmpty else { return }
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = String(format: "%020llu", UInt64(max(0, date.timeIntervalSince1970) * 1_000_000))
        let url = folder.appending(path: "\(stamp)-\(UUID().uuidString).json")
        try JSONEncoder().encode(subjects).write(to: url, options: .atomic)
    }

    /// Takes every posted request and removes it: the latest request's subjects first, each in
    /// its order.
    public func take(fileManager: FileManager = .default) -> [EditorPreviewSubject] {
        // Optional: no folder, no requests.
        guard let names = try? fileManager.contentsOfDirectory(atPath: folder.path(percentEncoded: false)) else { return [] }
        var subjects: [EditorPreviewSubject] = []
        for name in names.filter({ $0.hasSuffix(".json") && !$0.hasPrefix(".") }).sorted().reversed() {
            let url = folder.appending(path: name)
            // Optional: a request that can't be read (removed meanwhile, or partial) is dropped;
            // the editor renders what it still misses itself once the pre-warm is done.
            if let data = try? Data(contentsOf: url),
               let posted = try? JSONDecoder().decode([EditorPreviewSubject].self, from: data) {
                subjects.append(contentsOf: posted)
            }
            try? fileManager.removeItem(at: url) // Optional: another reader may have removed it.
        }
        return subjects
    }
}
