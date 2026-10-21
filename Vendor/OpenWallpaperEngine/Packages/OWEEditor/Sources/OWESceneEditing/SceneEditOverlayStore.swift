import Foundation

/// Where a wallpaper's editor overlay is kept: `<directory>/<identity>.json`, the identity being
/// the app's settings identity of the wallpaper (its Workshop id, else a hash of its project), so
/// moving the library keeps the edits, as it keeps the properties and presets.
public struct SceneEditOverlayStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func fileURL(for identity: String) -> URL {
        directory.appending(path: Self.fileName(identity) + ".json")
    }

    /// The folder of the files the editor added for the wallpaper (`EditorAssetStore`), beside its
    /// overlay: `<identity>.assets`.
    public func assetsDirectory(for identity: String) -> URL {
        directory.appending(path: Self.fileName(identity) + ".assets", directoryHint: .isDirectory)
    }

    /// The saved overlay; nil when the wallpaper has none.
    public func overlay(for identity: String) throws -> SceneEditOverlay? {
        let url = fileURL(for: identity)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try SceneEditOverlay.decoded(from: Data(contentsOf: url))
    }

    /// Saves `overlay`; an empty one removes the file, so Revert leaves nothing behind.
    public func save(_ overlay: SceneEditOverlay, for identity: String) throws {
        guard !overlay.isEmpty else { return try remove(identity) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try overlay.encoded().write(to: fileURL(for: identity), options: .atomic)
    }

    public func remove(_ identity: String) throws {
        let url = fileURL(for: identity)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// The identity as one file name: path separators and a leading dot can't escape the folder.
    static func fileName(_ identity: String) -> String {
        let cleaned = identity.map { $0 == "/" || $0 == ":" || $0 == "\\" ? "_" : $0 }
        let name = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return name.isEmpty ? "_" : name
    }
}
