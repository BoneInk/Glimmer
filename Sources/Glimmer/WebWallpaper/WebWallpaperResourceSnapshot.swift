import Foundation
import Darwin

struct WebWallpaperResourceSnapshot: Sendable {
    let itemID: UUID
    let rootURL: URL
    let files: [String: URL]
    let directoryModes: [String: WebWallpaperDirectoryMode]
    let directoriesJSON: String

    /// Foundation normalizes /private/tmp back to /tmp on some OS versions. Match
    /// the producer's POSIX realpath, permitting only Apple's two system aliases.
    private static func canonicalManagedURL(_ url: URL) throws -> URL {
        guard url.isFileURL else { throw WebWallpaperFailure(message: "Unsafe resource grant URL.") }
        var expected = url.standardizedFileURL.path
        if expected == "/tmp" || expected.hasPrefix("/tmp/") || expected == "/var" || expected.hasPrefix("/var/") { expected = "/private" + expected }
        guard let pointer = realpath(url.path, nil) else { throw WebWallpaperFailure(message: "Unsafe or missing resource grant path.") }
        defer { free(pointer) }
        let resolved = String(cString: pointer)
        guard resolved == expected else { throw WebWallpaperFailure(message: "Resource manifest contains an unsafe symbolic link.") }
        return URL(fileURLWithPath: resolved)
    }

    init(_ manifest: WebWallpaperResourceManifest) throws {
        let root = try Self.canonicalManagedURL(manifest.rootURL)
        guard root.isFileURL,
              (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              manifest.assets.count <= 5000, manifest.directories.count <= 128 else {
            throw WebWallpaperFailure(message: "Invalid or oversized resource manifest root.")
        }
        func token(_ value: String) -> Bool {
            (16...128).contains(value.utf8.count) && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
        }
        var map: [String: URL] = [:]
        var definitions: [String: WebWallpaperGrantedAsset] = [:]
        for asset in manifest.assets {
            let file = try Self.canonicalManagedURL(asset.url)
            guard token(asset.token), !asset.name.isEmpty, asset.name != ".", asset.name != "..",
                  asset.name.utf8.count <= 255, !asset.name.contains("/"), !asset.name.contains("\\"), !asset.name.contains("\0"),
                  asset.contentIdentity.count == 64, asset.contentIdentity.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  file.isFileURL, WebWallpaperProjectLocation.contains(file, in: root),
                  (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  definitions[asset.virtualPath] == nil || definitions[asset.virtualPath] == asset else {
                throw WebWallpaperFailure(message: "Resource manifest contains an unsafe or conflicting file grant.")
            }
            map[asset.virtualPath] = file; definitions[asset.virtualPath] = asset
        }
        var directories: [String: Any] = [:]
        var modes: [String: WebWallpaperDirectoryMode] = [:]
        for directory in manifest.directories {
            let prefix = "__gw_assets__/"
            guard !directory.propertyKey.isEmpty, directory.propertyKey.utf8.count <= 256,
                  directories[directory.propertyKey] == nil, directory.virtualPath.hasPrefix(prefix),
                  token(String(directory.virtualPath.dropFirst(prefix.count))),
                  !directory.revision.isEmpty, directory.revision.utf8.count <= 256,
                  directory.assets.allSatisfy({ definitions[$0.virtualPath] == $0 }),
                  Set(directory.assets.map(\.virtualPath)).count == directory.assets.count else {
                throw WebWallpaperFailure(message: "Resource manifest contains an unsafe directory grant.")
            }
            modes[directory.virtualPath] = directory.mode
            directories[directory.propertyKey] = ["mode": directory.mode.rawValue, "revision": directory.revision,
                "path": directory.virtualPath, "files": directory.assets.sorted { $0.virtualPath < $1.virtualPath }.map { ["path": $0.virtualPath, "identity": $0.contentIdentity] }]
        }
        let data = try JSONSerialization.data(withJSONObject: directories, options: [.sortedKeys])
        guard data.count <= 1024 * 1024 else { throw WebWallpaperFailure(message: "Directory manifest exceeds 1 MiB.") }
        itemID = manifest.itemID; rootURL = root; files = map; directoryModes = modes
        directoriesJSON = String(decoding: data, as: UTF8.self)
    }
}
