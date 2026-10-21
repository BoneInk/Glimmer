import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Full-resolution pictures of scene wallpapers' real frames, shown while a scene loads instead of
/// its Workshop preview (`ScenePreviewPlaceholder`). One per wallpaper and display pixel size,
/// written by the prepare-on-arrival helper (`ShaderPrewarm`) and refreshed by a running scene
/// (`SceneLoadingSnapshotCapture`).
///
/// Files live in `<Caches>/Open Wallpaper Engine/LoadingSnapshots/r<revision>/<wallpaper>/`, named
/// `<content key>-<width>x<height>.<heic|jpg>`. The content key hashes the wallpaper folder's
/// top-level files (names, sizes, modification dates), so an updated wallpaper never shows its
/// old picture. The folder is a size-capped LRU: reading a snapshot marks it used, and each write
/// removes the least recently used files over `capacityBytes`.
///
/// Blocking file IO and image encoding: call it off the main and render threads.
struct SceneLoadingSnapshotStore: Sendable {
    /// Bump when the stored pictures change meaning (what a snapshot shows, its encoding, names).
    static let revision = 1
    static let defaultCapacityBytes = 256 * 1024 * 1024
    static let quality: CGFloat = 0.9
    static let extensions: Set<String> = ["heic", "jpg"]

    /// This revision's folder; only files in it are ever written or removed, besides older
    /// revisions' folders, which `trim` deletes.
    let directory: URL
    let capacityBytes: Int

    static var current: SceneLoadingSnapshotStore {
        SceneLoadingSnapshotStore(cachesDirectory: AppStorageLocation.current.cachesDirectory)
    }

    init(cachesDirectory: URL, capacityBytes: Int = defaultCapacityBytes) {
        directory = Self.root(in: cachesDirectory).appending(path: "r\(Self.revision)", directoryHint: .isDirectory)
        self.capacityBytes = capacityBytes
    }

    static func root(in cachesDirectory: URL) -> URL {
        cachesDirectory.appending(path: "Open Wallpaper Engine/LoadingSnapshots", directoryHint: .isDirectory)
    }

    // MARK: Keys

    /// The wallpaper's id in the store: its folder name and a hash of its full path, so two
    /// libraries' copies of one Workshop item never share pictures.
    static func wallpaperKey(for wallpaperDirectory: URL) -> String {
        let path = wallpaperDirectory.standardizedFileURL.path(percentEncoded: false)
        let name = String(wallpaperDirectory.standardizedFileURL.lastPathComponent.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? Character($0) : "_"
        }.prefix(40))
        return "\(name)-\(hex(Data(path.utf8), bytes: 6))"
    }

    /// What the wallpaper's files are now: a hash of its top-level files' names, sizes and
    /// modification dates. Nil when the folder can't be read.
    static func contentKey(for wallpaperDirectory: URL) -> String? {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: wallpaperDirectory, includingPropertiesForKeys: keys,
                                                                options: .skipsHiddenFiles)
        } catch {
            OWELog.error(.scene, "Loading snapshot: can't read \(wallpaperDirectory.lastPathComponent): \(error)")
            return nil
        }
        var lines: [String] = []
        for file in files {
            do {
                let values = try file.resourceValues(forKeys: Set(keys))
                guard values.isRegularFile == true else { continue }
                let modified = values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
                lines.append("\(file.lastPathComponent)|\(values.fileSize ?? 0)|\(modified)")
            } catch {
                // Optional: a file removed while listing isn't part of the content.
                continue
            }
        }
        return hex(Data(lines.sorted().joined(separator: "\n").utf8), bytes: 8)
    }

    private static func hex(_ data: Data, bytes: Int) -> String {
        Digest.hex(SHA256.hash(data: data).prefix(bytes))
    }

    // MARK: Reading

    struct Entry: Equatable {
        var url: URL
        var contentKey: String
        var pixelSize: SIMD2<Int>
    }

    /// The name's parts, or nil for a file this store didn't write.
    static func entry(_ url: URL) -> Entry? {
        guard extensions.contains(url.pathExtension.lowercased()) else { return nil }
        let parts = url.deletingPathExtension().lastPathComponent.split(separator: "-")
        guard parts.count == 2 else { return nil }
        let size = parts[1].split(separator: "x")
        guard size.count == 2, let width = Int(size[0]), let height = Int(size[1]), width > 0, height > 0 else { return nil }
        return Entry(url: url, contentKey: String(parts[0]), pixelSize: SIMD2(width, height))
    }

    func folder(for wallpaperDirectory: URL) -> URL {
        directory.appending(path: Self.wallpaperKey(for: wallpaperDirectory), directoryHint: .isDirectory)
    }

    func entries(for wallpaperDirectory: URL) -> [Entry] {
        let folder = folder(for: wallpaperDirectory)
        guard FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) else { return [] }
        do {
            return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                               options: .skipsHiddenFiles).compactMap(Self.entry)
        } catch {
            OWELog.error(.scene, "Loading snapshot: can't list \(folder.lastPathComponent): \(error)")
            return []
        }
    }

    /// The snapshot to show on a display of `pixelSize` for the wallpaper as it is now: the one at
    /// that size, else the nearest (same aspect first), which the caller scales. Marks it used.
    func bestSnapshot(forWallpaperAt wallpaperDirectory: URL, pixelSize: SIMD2<Int>) -> URL? {
        guard let contentKey = Self.contentKey(for: wallpaperDirectory) else { return nil }
        return bestSnapshot(forWallpaperAt: wallpaperDirectory, contentKey: contentKey, pixelSize: pixelSize)
    }

    func bestSnapshot(forWallpaperAt wallpaperDirectory: URL, contentKey: String, pixelSize: SIMD2<Int>) -> URL? {
        let candidates = entries(for: wallpaperDirectory).filter { $0.contentKey == contentKey }
        guard let best = Self.nearest(candidates.map(\.pixelSize), to: pixelSize),
              let entry = candidates.first(where: { $0.pixelSize == best }) else { return nil }
        markUsed(entry.url)
        return entry.url
    }

    /// The size in `sizes` closest to `target`: an exact match, else the least difference in
    /// scale and (weighted well above it, since the placement crops by aspect) in aspect, as log
    /// ratios; the larger on a tie.
    static func nearest(_ sizes: [SIMD2<Int>], to target: SIMD2<Int>) -> SIMD2<Int>? {
        guard target.x > 0, target.y > 0 else { return sizes.first }
        func distance(_ size: SIMD2<Int>) -> (Double, Int) {
            let width = log(Double(size.x) / Double(target.x))
            let height = log(Double(size.y) / Double(target.y))
            return (10 * abs(width - height) + abs(width + height), -(size.x * size.y))
        }
        return sizes.min { distance($0) < distance($1) }
    }

    /// LRU: the modification date is the last use (the content key is in the name).
    private func markUsed(_ url: URL) {
        do {
            try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path(percentEncoded: false))
        } catch {
            OWELog.debug(.scene, "Loading snapshot: can't mark \(url.lastPathComponent) used: \(error)")
        }
    }

    // MARK: Writing

    /// Encodes `image` (HEIC, or JPEG where HEIC can't be written) and stores it as the wallpaper's
    /// snapshot at its size for `contentKey`, replacing that size's older one and every snapshot
    /// of other content; then trims the store.
    @discardableResult
    func write(_ image: CGImage, forWallpaperAt wallpaperDirectory: URL, contentKey: String) throws -> URL {
        guard let (data, fileExtension) = Self.encoded(image) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "The snapshot could not be encoded"])
        }
        let folder = folder(for: wallpaperDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "\(contentKey)-\(image.width)x\(image.height).\(fileExtension)",
                                   directoryHint: .notDirectory)
        try data.write(to: url, options: .atomic)
        for entry in entries(for: wallpaperDirectory) where entry.url.lastPathComponent != url.lastPathComponent
            && (entry.contentKey != contentKey || entry.pixelSize == SIMD2(image.width, image.height)) {
            remove(entry.url)
        }
        trim()
        return url
    }

    static func encoded(_ image: CGImage) -> (Data, String)? {
        for (type, fileExtension) in [(UTType.heic, "heic"), (UTType.jpeg, "jpg")] {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            if CGImageDestinationFinalize(destination), data.length > 0 { return (data as Data, fileExtension) }
        }
        return nil
    }

    // MARK: Cleanup

    /// Removes the wallpaper's snapshots (it was deleted).
    func removeSnapshots(forWallpaperAt wallpaperDirectory: URL) {
        let folder = folder(for: wallpaperDirectory)
        guard FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) else { return }
        remove(folder)
    }

    /// Removes the least recently used snapshots until the store holds at most `capacityBytes`,
    /// empty wallpaper folders, and older revisions' folders.
    func trim() {
        let fileManager = FileManager.default
        let root = directory.deletingLastPathComponent()
        if let revisions = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) { // Optional: no store yet.
            for folder in revisions where folder.lastPathComponent != directory.lastPathComponent { remove(folder) }
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: keys,
                                                      options: .skipsHiddenFiles) else { return }
        var files: [(url: URL, size: Int, used: Date)] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), // Optional: removed while listing.
                  values.isRegularFile == true else { continue }
            files.append((url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast))
        }
        var total = files.reduce(0) { $0 + $1.size }
        for file in files.sorted(by: { $0.used < $1.used }) where total > capacityBytes {
            remove(file.url)
            total -= file.size
            let folder = file.url.deletingLastPathComponent()
            if (try? fileManager.contentsOfDirectory(atPath: folder.path(percentEncoded: false)))?.isEmpty == true { // Optional.
                remove(folder)
            }
        }
    }

    private func remove(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            // Another writer removed it first.
        } catch {
            OWELog.error(.scene, "Loading snapshot: can't remove \(url.lastPathComponent): \(error)")
        }
    }
}
