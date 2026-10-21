import AVFoundation
import CryptoKit

/// Finds and opens a scene's sound files (docs/scenescript-plan.md, sound layers). A file comes
/// from the wallpaper's package (copied once into the app's caches, since AVFoundation reads
/// files), its folder, another Workshop item, or WE's assets, in that order. AVFoundation decodes
/// what WE's SFML decoders read (mp3, Ogg Vorbis, FLAC, WAV) and streams it. A file that can't be
/// found or opened is logged once and left out; a layer with no file left plays nothing.
/// Off the main thread, with the content.
struct SceneSoundContentBuilder {
    var wallpaperDirectory: URL
    /// The file's bytes inside the wallpaper's package, if it has one.
    var packagedData: (String) -> Data?
    var workshopURL: (String) -> URL?
    /// A dependency path's bytes and the file they come from (`WorkshopAssetResolver.located`).
    var workshopData: (String) -> (data: Data, source: URL?)?
    var cacheDirectory = Self.defaultCacheDirectory
    /// The wallpaper's `.pkg` that `packagedData` reads, which keys its cached copies.
    var packageURL: URL?

    static var defaultCacheDirectory: URL {
        AppStorageLocation.current.cachesDirectory
            .appending(path: "Open Wallpaper Engine/SceneAudio")
    }

    func sounds(in objects: [WESceneObject], context: SceneValueContext) -> [SceneSoundContent] {
        objects.compactMap { object in
            guard let sound = object.sound, let id = object.id else { return nil }
            let files = sound.files.compactMap(file)
            return SceneSoundContent(id: id, name: object.name ?? "", sound: sound, files: files,
                                     volume: Self.value(sound.volume, in: context),
                                     attenuation: Self.value(sound.attenuation, in: context),
                                     minDistance: Self.value(sound.minDistance, in: context))
        }
    }

    /// A float of a sound (`volume`, `attenuation`, `mindistance`): the value as the document
    /// holds it, its user binding resolved (`UserPropertyBindingTable`; a script's value comes from
    /// the runtime), else WE's default 1.
    static func value(_ raw: SceneRawValue?, in context: SceneValueContext) -> Float {
        raw?.literalDouble.map(Float.init) ?? 1
    }

    private func file(_ path: String) -> SceneSoundContent.File? {
        guard let url = locate(path) else {
            OWELog.error(.audio, "Sound '\(path)' is in neither the wallpaper, its Workshop items nor WE's assets")
            return nil
        }
        do {
            let audio = try AVAudioFile(forReading: url)
            let rate = audio.processingFormat.sampleRate
            return SceneSoundContent.File(path: path, url: url, duration: rate > 0 ? Double(audio.length) / rate : 0,
                                          channels: Int(audio.processingFormat.channelCount))
        } catch {
            OWELog.error(.audio, "Sound '\(path)' can't be decoded: \(error)")
            return nil
        }
    }

    private func locate(_ path: String) -> URL? {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        if let data = packagedData(path) ?? packagedData(normalized) {
            return cached(data, entry: normalized, source: packageURL)
        }
        if let loose = AssetPathResolver.fileURL(normalized, in: wallpaperDirectory) { return loose }
        if let url = workshopURL(normalized) { return url }
        if let found = workshopData(normalized) {
            return cached(found.data, entry: normalized, source: found.source)
        }
        return WallpaperEngineAssets.locate([normalized], in: WallpaperEngineAssets.searchDirectories)
    }

    /// A packaged file's copy in the caches, named by the wallpaper, entry and content so every
    /// screen and launch reuses it and an updated package gets a fresh copy.
    private func cached(_ data: Data, entry: String, source: URL?) -> URL? {
        let destination = cacheDirectory.appending(path: Self.cacheName(entry: entry, wallpaperDirectory: wallpaperDirectory,
                                                                        source: source, fallbackSize: data.count))
        let files = FileManager.default
        if files.fileExists(atPath: destination.path) {
            // The modification date is the LRU's last use.
            try? files.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)
            return destination
        }
        do {
            try files.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
        } catch {
            OWELog.error(.audio, "Sound '\(entry)' can't be copied to \(destination.path): \(error)")
            return nil
        }
        Self.prune(cacheDirectory, byteLimit: Self.cacheByteLimit, keeping: destination)
        return destination
    }

    /// The audio cache's size cap; the least recently used copies go first.
    static let cacheByteLimit = 512 << 20

    /// A packaged entry's cache file name: stable across launches (`hashValue` is seeded per
    /// process), distinct per wallpaper since entry paths repeat across packages, and per content
    /// (the size and modification date of the file its bytes come from: the `.pkg`, a loose file
    /// or a dependency's resolved file), as `SceneLoadingSnapshotStore.contentKey`.
    static func cacheName(entry: String, wallpaperDirectory: URL?, source: URL?, fallbackSize: Int) -> String {
        // Fresh values: a URL caches what it read, and the file may have changed since.
        var source = source
        source?.removeAllCachedResourceValues()
        let values = try? source?.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return cacheName(entry: entry, wallpaperDirectory: wallpaperDirectory, size: values?.fileSize ?? fallbackSize,
                         modified: values?.contentModificationDate)
    }

    static func cacheName(entry: String, wallpaperDirectory: URL?, size: Int, modified: Date?) -> String {
        let stamp = modified?.timeIntervalSinceReferenceDate ?? 0
        let key = "\(wallpaperDirectory?.standardizedFileURL.path ?? "")|\(entry)|\(size)|\(stamp)"
        return "\(hex(Data(key.utf8))).\(URL(fileURLWithPath: entry).pathExtension)"
    }

    private static func hex(_ data: Data) -> String {
        Digest.hex(SHA256.hash(data: data))
    }

    /// Whether a cache file name is this scheme's (a 64-digit hex stem), not the old per-launch
    /// `hashValue` one (a signed decimal), which left a copy behind every launch.
    static func isCurrentCacheName(_ name: String) -> Bool {
        let stem = (name as NSString).deletingPathExtension
        return stem.count == 64 && stem.allSatisfy(\.isHexDigit)
    }

    /// Marks a cache folder whose old-scheme copies are gone, so that sweep runs once.
    static let migrationMarker = ".named-by-content"

    /// Removes the old naming scheme's copies (once per folder), then the least recently used
    /// copies until the folder fits `byteLimit`, never `keeping`.
    static func prune(_ directory: URL, byteLimit: Int, keeping: URL? = nil) {
        let files = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let urls = try? files.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys),
                                                        options: .skipsHiddenFiles) else { return }
        let marker = directory.appending(path: migrationMarker)
        let migrate = !files.fileExists(atPath: marker.path)
        var entries: [(url: URL, size: Int, used: Date)] = []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            if migrate && !isCurrentCacheName(url.lastPathComponent) {
                try? files.removeItem(at: url)
                continue
            }
            entries.append((url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast))
        }
        if migrate { files.createFile(atPath: marker.path, contents: Data()) }
        var total = entries.reduce(0) { $0 + $1.size }
        let keep = keeping?.standardizedFileURL.path
        for entry in entries.sorted(by: { $0.used < $1.used }) where total > byteLimit {
            guard entry.url.standardizedFileURL.path != keep else { continue }
            if (try? files.removeItem(at: entry.url)) != nil { total -= entry.size }
        }
    }
}
