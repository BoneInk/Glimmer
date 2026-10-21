import Foundation
import WEFormat

/// The editor's previews of effects and particle systems on disk:
/// `<Caches>/EditorPreviews/<assets build>-r<revision>/<subject>.heic` for a still preview, `.mov`
/// (HEVC) for a moving one. A preview shows WE's files, so the folder is keyed by the build of WE's
/// assets it was rendered from: another build gets a folder of its own. The background pre-warm
/// carries each preview whose inputs didn't change into it (`carryOver`, by the fingerprints in
/// each folder's `.inputs.json`, `EditorPreviewInputs`) and then removes the others (`prune`).
/// Each kind's revision is bumped whenever its rendering changes; the app's version isn't part of
/// the key, so an app update keeps the previews.
public struct EditorPreviewCache: Sendable {
    /// Bump when what an effect's preview shows changes (its scene, test card, size, length or
    /// encoding).
    public static let effectRevision = 3
    /// Bump when what a particle system's preview shows changes.
    public static let particleRevision = 2
    /// The folder's revision, both kinds': a bump of one kind's carries the other's previews over.
    public static var revision: String { "\(effectRevision).\(particleRevision)" }

    /// The revision of the subject's kind.
    public static func revision(of subject: EditorPreviewSubject) -> Int {
        subject.isParticle ? particleRevision : effectRevision
    }

    /// What a folder's `.inputs.json` holds for one preview (by its `cacheName`).
    public struct InputRecord: Codable, Equatable, Sendable {
        /// `EditorPreviewInputs.fingerprint(of:)` of the assets it was rendered from; empty for a
        /// preview without one (a Workshop effect).
        public var fingerprint: String
        /// When rendering it failed: it isn't tried again in the background until its inputs change.
        public var failedAt: Date?

        public init(fingerprint: String, failedAt: Date? = nil) {
            self.fingerprint = fingerprint
            self.failedAt = failedAt
        }
    }

    /// The file in each folder recording its previews' inputs.
    public static let inputsFileName = ".inputs.json"
    /// A preview's file types: a still, a loop.
    public static let stillExtension = "heic"
    public static let movieExtension = "mov"

    /// `EditorPreviews`, the folder holding every build's previews.
    public let root: URL
    /// The assets build (`assetsBuild(of:)`).
    public let build: String

    public init(root: URL, build: String) {
        self.root = root
        self.build = build
    }

    /// `<root>/EditorPreviews`.
    public init(cachesDirectory: URL, build: String) {
        self.init(root: cachesDirectory.appending(path: "EditorPreviews", directoryHint: .isDirectory), build: build)
    }

    /// This build's folder.
    public var directory: URL {
        root.appending(path: "\(EditorPreviewSubject.fileSafe(build))-r\(Self.revision)", directoryHint: .isDirectory)
    }

    /// Where the subject's preview goes, without its extension (the renderer picks it).
    public func outputBase(for subject: EditorPreviewSubject) -> URL {
        directory.appending(path: subject.cacheName, directoryHint: .notDirectory)
    }

    /// The subject's preview when it was rendered for this build: its still, else its loop.
    public func cachedPreview(for subject: EditorPreviewSubject, fileManager: FileManager = .default) -> URL? {
        let base = outputBase(for: subject)
        for fileExtension in [Self.stillExtension, Self.movieExtension] {
            let url = base.appendingPathExtension(fileExtension)
            if fileManager.fileExists(atPath: url.path(percentEncoded: false)) { return url }
        }
        return nil
    }

    /// Removes the previews of every other build and revision. Hidden files of the root (the
    /// pre-warm's lock) stay.
    public func prune(fileManager: FileManager = .default) throws {
        for folder in try otherFolders(fileManager: fileManager) { try fileManager.removeItem(at: folder) }
    }

    // MARK: Inputs

    /// This folder's records, by `cacheName`; empty when it has none or they can't be read.
    public func inputs() -> [String: InputRecord] {
        Self.inputs(in: directory)
    }

    /// Adds `records` to this folder's, replacing those of the same names.
    public func record(_ records: [String: InputRecord], fileManager: FileManager = .default) throws {
        guard !records.isEmpty else { return }
        var all = inputs()
        all.merge(records) { _, new in new }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(all).write(to: directory.appending(path: Self.inputsFileName), options: .atomic)
    }

    /// Moves into this folder each preview of another build's or revision's folder whose recorded
    /// fingerprint is the subject's in `fingerprints` (its inputs didn't change), with its record.
    /// Returns the subjects carried over.
    @discardableResult
    public func carryOver(_ fingerprints: [EditorPreviewSubject: String],
                          fileManager: FileManager = .default) throws -> Set<EditorPreviewSubject> {
        var carried = Set<EditorPreviewSubject>()
        var records: [String: InputRecord] = [:]
        for folder in try otherFolders(fileManager: fileManager) {
            let old = Self.inputs(in: folder)
            guard !old.isEmpty else { continue }
            for (subject, fingerprint) in fingerprints where !fingerprint.isEmpty && !carried.contains(subject) {
                let name = subject.cacheName
                guard let record = old[name], record.fingerprint == fingerprint,
                      cachedPreview(for: subject, fileManager: fileManager) == nil else { continue }
                if record.failedAt != nil {
                    records[name] = record
                    continue
                }
                for fileExtension in [Self.stillExtension, Self.movieExtension] {
                    let source = folder.appending(path: name).appendingPathExtension(fileExtension)
                    guard fileManager.fileExists(atPath: source.path(percentEncoded: false)) else { continue }
                    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                    try fileManager.moveItem(at: source, to: outputBase(for: subject).appendingPathExtension(fileExtension))
                    records[name] = record
                    carried.insert(subject)
                    break
                }
            }
        }
        try record(records, fileManager: fileManager)
        return carried
    }

    /// The other builds' and revisions' folders.
    private func otherFolders(fileManager: FileManager) throws -> [URL] {
        guard fileManager.fileExists(atPath: root.path(percentEncoded: false)) else { return [] }
        let keep = directory.standardizedFileURL.lastPathComponent
        return try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent != keep && !$0.lastPathComponent.hasPrefix(".") }
    }

    private static func inputs(in folder: URL) -> [String: InputRecord] {
        // Optional: a folder without records (rendered before they were kept) carries nothing over.
        guard let data = try? Data(contentsOf: folder.appending(path: inputsFileName)) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // Optional: unreadable records only cost a render.
        return (try? decoder.decode([String: InputRecord].self, from: data)) ?? [:]
    }

    // MARK: The assets build

    /// The build of the WE assets in `assets` (an `assets` folder, or a copy of one), most exact
    /// first: Steam's build id from the app's copy (`.owe-assets-info.json`), the CI copy
    /// (`.build`) or a Steam install's app manifest; else WE's version (`version.json` of an
    /// install); else the modification dates of the folders previews read.
    public static func assetsBuild(of assets: URL, fileManager: FileManager = .default) -> String {
        let parent = assets.deletingLastPathComponent()
        for folder in [assets, parent] {
            if let id = infoBuildID(in: folder) { return "steam-\(id)" }
            // Optional: a copy without a `.build` file is looked up the next way.
            if let text = try? String(contentsOf: folder.appending(path: ".build"), encoding: .utf8) {
                let id = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !id.isEmpty { return "steam-\(id)" }
            }
        }
        // `steamapps/common/wallpaper_engine/assets` → `steamapps/appmanifest_431960.acf`.
        let manifest = parent.deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "appmanifest_431960.acf")
        if let id = manifestBuildID(manifest) { return "steam-\(id)" }
        // Optional: an install without version.json falls through to the folder dates.
        if let data = try? Data(contentsOf: parent.appending(path: "version.json")),
           let root = try? TolerantJSON.object(from: data) as? [String: Any],
           let version = root["version"] as? String, !version.isEmpty {
            return "we-\(version)"
        }
        var stamps: [String] = []
        for name in ["effects", "particles", "presets", "shaders", "materials"] {
            let url = assets.appending(path: name, directoryHint: .isDirectory)
            // Optional: a folder the copy doesn't have is no part of the stamp.
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let date = values.contentModificationDate else { continue }
            stamps.append("\(name)=\(Int(date.timeIntervalSince1970))")
        }
        return "files-" + EditorPreviewSubject.fileSafe(String(stamps.joined(separator: ",").hashValueStable, radix: 16))
    }

    /// `steamBuildID` of the app's own copy's info file.
    private static func infoBuildID(in folder: URL) -> String? {
        // Optional: only the app's and the CI's copies have the file.
        guard let data = try? Data(contentsOf: folder.appending(path: ".owe-assets-info.json")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = root["steamBuildID"] as? String, !id.isEmpty else { return nil }
        return id
    }

    /// `"buildid" "23967692"` of a Steam app manifest.
    static func manifestBuildID(_ url: URL) -> String? {
        // Optional: only a Steam install has the manifest.
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let regex = try? NSRegularExpression(pattern: #""buildid"\s+"(\d+)""#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}

private extension String {
    /// FNV-1a over the UTF-8 bytes: the same in every run (Swift's `hashValue` isn't).
    var hashValueStable: UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return hash
    }
}
