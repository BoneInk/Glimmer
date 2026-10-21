import Foundation
import OWESceneEditing

/// The Depth Map Generation plugin on disk, shared by the app (which installs it, Settings ›
/// Plugins) and every process that generates depth maps (the app's Scene Edit / Export, the Wallpaper
/// Editor in its own process), which each read it from here rather than from the installer:
///
///     <Application Support>/Open Wallpaper Engine[ (isolated <tag>)]/Plugins/DepthMaps/
///         <version>/DepthAnythingV2SmallF16.mlmodelc   the compiled model
///         <version>/NOTICE.txt                          its source and licence (Apache-2.0)
///         <version>/.owe-depth-maps.json                written last: marks a complete install
///         .state.json                                   the active and the previous version
///         .staging-<uuid>/                              one install in progress
public enum DepthMapPluginLayout {
    /// Under the app's support directory (`AppStorageLocation.supportDirectory`).
    public static let folder = "Plugins/DepthMaps"
    public static let compiledModelName = "DepthAnythingV2SmallF16.mlmodelc"
    public static let manifestName = ".owe-depth-maps.json"
    public static let noticeName = "NOTICE.txt"
    public static let stagingPrefix = ".staging-"

    public static func root(supportDirectory: URL) -> URL {
        supportDirectory.appending(path: folder, directoryHint: .isDirectory)
    }

    /// Written last into a version folder.
    public struct Manifest: Codable, Equatable, Sendable {
        /// The folder's name.
        public var version: String
        /// The Hugging Face repository and the commit the files came from.
        public var repository: String
        public var revision: String
        /// Each downloaded file's SHA-256, by its path inside the `.mlpackage`.
        public var files: [String: String]

        public init(version: String, repository: String, revision: String, files: [String: String]) {
            self.version = version
            self.repository = repository
            self.revision = revision
            self.files = files
        }
    }

    /// `.state.json`: which install is active and which one came before it.
    public struct State: Codable, Equatable, Sendable {
        public var active: String?
        public var previous: String?

        public static let fileName = ".state.json"

        public init(active: String? = nil, previous: String? = nil) {
            self.active = active
            self.previous = previous
        }

        public static func read(in root: URL) -> State {
            // No file: nothing installed yet. One that can't be read or decoded logs and reads as none.
            EditorLog.attempt("Depth map plug-in state", quietIfMissing: true) {
                try JSONDecoder().decode(Self.self, from: Data(contentsOf: root.appending(path: fileName)))
            } ?? State()
        }

        public func write(in root: URL) throws {
            try JSONEncoder().encode(self).write(to: root.appending(path: Self.fileName), options: .atomic)
        }
    }

    /// The model a generator loads.
    public struct ActiveModel: Equatable, Sendable {
        public var version: String
        /// The compiled `.mlmodelc`.
        public var url: URL

        public init(version: String, url: URL) {
            self.version = version
            self.url = url
        }
    }

    /// The manifest of the install in `folder`, nil when it isn't a complete install.
    public static func manifest(in folder: URL) -> Manifest? {
        guard let data = try? Data(contentsOf: folder.appending(path: manifestName)),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.appending(path: compiledModelName).path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return manifest
    }

    /// The active, complete install under `root`; nil when the plugin isn't installed.
    public static func activeModel(in root: URL) -> ActiveModel? {
        guard let active = State.read(in: root).active else { return nil }
        let folder = root.appending(path: active, directoryHint: .isDirectory)
        guard manifest(in: folder) != nil else { return nil }
        return ActiveModel(version: active, url: folder.appending(path: compiledModelName, directoryHint: .isDirectory))
    }
}
