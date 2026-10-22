import Foundation
import Darwin
import os

let GWBundleID = "com.boneinkzhong.glimmer.wallpaper-extension"
let GWChoiceID = "glimmer.native-video"
let GWLogger = Logger(subsystem: GWBundleID, category: "NativeWallpaper")
func GWLog(_ message: String) { GWLogger.notice("\(message, privacy: .public)") }
func GWError(_ code: Int, _ message: String) -> NSError {
    NSError(domain: GWBundleID, code: code, userInfo: [NSLocalizedDescriptionKey: message])
}

struct GWConfiguration: Codable, Sendable {
    let schemaVersion: Int
    let assetID: UUID
    let videoFileName: String
    let gravity: String
    let isMuted: Bool
    var liveDirectoryName: String? = nil

    static var directory: URL {
        URL(fileURLWithPath: "/Users/Shared/GlimmerNativeLockScreen", isDirectory: true)
            .appendingPathComponent(String(getuid()), isDirectory: true)
    }

    /// This extension never accepts arbitrary host-provided files. Its only media source is
    /// a same-user 0700 staging directory with owned, non-symlink, 0600 files.
    static func load(directory: URL = Self.directory, isolatedProbe: Bool = false) throws -> (GWConfiguration, URL) {
        let directory = directory.standardizedFileURL
        if !isolatedProbe {
            let root = directory.deletingLastPathComponent()
            let metadata = try inspect(root)
            guard metadata.st_mode & S_IFMT == S_IFDIR,
                  metadata.st_uid == 0 || metadata.st_uid == getuid(),
                  metadata.st_mode & 0o022 == 0,
                  root.resolvingSymlinksInPath() == root else {
                throw GWError(10, "Unsafe shared staging root")
            }
        }
        let folder = try inspect(directory)
        guard folder.st_mode & S_IFMT == S_IFDIR, folder.st_uid == getuid(), folder.st_mode & 0o077 == 0,
              directory.resolvingSymlinksInPath() == directory else {
            throw GWError(11, "Staging directory must be private to this user")
        }
        let configURL = directory.appendingPathComponent("config.json")
        try validateFile(configURL, maximumBytes: 64 * 1024)
        let config = try JSONDecoder().decode(Self.self, from: Data(contentsOf: configURL))
        if config.schemaVersion == 2, let name = config.liveDirectoryName {
            guard name == "live-" + config.assetID.uuidString, ["fill", "fit"].contains(config.gravity), config.isMuted else {
                throw GWError(12, "Invalid live wallpaper configuration")
            }
            let live = directory.appendingPathComponent(name)
            let metadata = try inspect(live)
            guard metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_uid == getuid(), metadata.st_mode & 0o077 == 0,
                  live.resolvingSymlinksInPath() == live else { throw GWError(14, "Unsafe live wallpaper directory") }
            return (config, live)
        }
        guard config.schemaVersion == 1, ["fill", "fit"].contains(config.gravity), config.isMuted,
              config.videoFileName == URL(fileURLWithPath: config.videoFileName).lastPathComponent,
              !config.videoFileName.contains("/"), !config.videoFileName.contains("\\"),
              ["mp4", "mov", "m4v"].contains((config.videoFileName as NSString).pathExtension.lowercased()),
              UUID(uuidString: (config.videoFileName as NSString).deletingPathExtension) == config.assetID else {
            throw GWError(12, "Invalid or unsafe native wallpaper configuration")
        }
        let video = directory.appendingPathComponent(config.videoFileName)
        try validateFile(video, maximumBytes: 64 * 1024 * 1024 * 1024)
        return (config, video)
    }

    private static func inspect(_ url: URL) throws -> stat {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw GWError(13, "Staged file is unavailable") }
        return info
    }

    private static func validateFile(_ url: URL, maximumBytes: Int64) throws {
        let info = try inspect(url)
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              info.st_size > 0, info.st_size <= maximumBytes,
              url.resolvingSymlinksInPath() == url else { throw GWError(14, "Unsafe staged file") }
    }
}

func GWField(_ name: String, in object: Any?, depth: Int = 0) -> Any? {
    guard let object, depth < 7 else { return nil }
    let mirror = Mirror(reflecting: object)
    for child in mirror.children where child.label == name { return child.value }
    for child in mirror.children {
        if let result = GWField(name, in: child.value, depth: depth + 1) { return result }
    }
    return nil
}

struct GWRequest {
    let size: CGSize
    let scale: CGFloat
    let displayID: UInt32?
    let preview: Bool
    let mode: String?
    let activity: String?
    init(_ value: Any?) {
        let proposed = GWField("size", in: value) as? CGSize ?? CGSize(width: 1920, height: 1080)
        size = CGSize(width: min(8192, max(1, proposed.width.isFinite ? proposed.width : 1920)),
                      height: min(8192, max(1, proposed.height.isFinite ? proposed.height : 1080)))
        let factor = GWField("scaleFactor", in: value) as? CGFloat ?? 1
        scale = factor.isFinite ? min(4, max(1, factor)) : 1
        displayID = GWField("directDisplayID", in: value) as? UInt32
        preview = GWField("isPreview", in: value) as? Bool ?? false
        mode = GWField("presentationMode", in: value).map { String(describing: $0) }
        activity = GWField("activityState", in: value).map { String(describing: $0) }
    }
    var shouldPlay: Bool {
        let state = activity?.lowercased() ?? ""
        if ["inactive", "sleep", "hidden", "suspended"].contains(where: state.contains) { return false }
        // presentationMode describes the host surface, not its visibility.
        // Real lock-screen acquisitions also arrive as "default". Only an
        // explicit inactive state, sleep or invalidation may freeze the clock.
        return true
    }
}
