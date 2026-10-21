import Foundation
import CoreFoundation

struct WebWallpaperFailure: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

struct WebWallpaperCapabilities: Sendable {
    let scalarPropertyTypes: Set<String> = ["bool", "color", "slider", "combo", "textinput"]
    let resourcePropertyTypes: Set<String> = ["file", "directory"]
    let resourcePropertiesRequireManifest = true
    let unsupportedPropertyTypes: Set<String> = []
    let cooperativePause = true
    let arbitraryJavaScriptSuspension = false
    let remoteResources: Bool
    init(remoteResources: Bool = false) { self.remoteResources = remoteResources }
    let childFrames = false
}

struct WebWallpaperProjectLocation: Sendable {
    static let scheme = "gw-wallpaper"
    static let host = "project"
    let projectURL: URL
    let rootURL: URL
    let entryURL: URL
    let documentURL: URL

    init(projectURL: URL, entryURL: URL) throws {
        guard projectURL.isFileURL, entryURL.isFileURL, projectURL.lastPathComponent == "project.json" else {
            throw WebWallpaperFailure(message: "Web wallpaper requires a local project.json and entry file.")
        }
        self.projectURL = projectURL.standardizedFileURL.resolvingSymlinksInPath()
        rootURL = self.projectURL.deletingLastPathComponent()
        self.entryURL = entryURL.standardizedFileURL.resolvingSymlinksInPath()
        guard Self.contains(self.entryURL, in: rootURL),
              (try? self.projectURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              (try? self.entryURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              ["html", "htm"].contains(self.entryURL.pathExtension.lowercased()) else {
            throw WebWallpaperFailure(message: "Web wallpaper entry must be an HTML file inside its project root.")
        }
        let relative = String(self.entryURL.path.dropFirst(rootURL.path.count + 1))
        var components = URLComponents()
        components.scheme = Self.scheme; components.host = Self.host; components.path = "/" + relative
        guard let url = components.url else { throw WebWallpaperFailure(message: "Invalid Web wallpaper entry URL.") }
        documentURL = url
    }

    func localURL(for url: URL) throws -> URL {
        guard url.scheme == Self.scheme, url.host == Self.host, url.user == nil, url.password == nil, url.port == nil,
              let encoded = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath,
              let path = encoded.removingPercentEncoding, !path.contains("\0"), !path.contains("\\"),
              !path.split(separator: "/").contains("..") else {
            throw WebWallpaperFailure(message: "Blocked resource outside the Web wallpaper project.")
        }
        let local = rootURL.appendingPathComponent(String(path.drop(while: { $0 == "/" })))
            .standardizedFileURL.resolvingSymlinksInPath()
        guard Self.contains(local, in: rootURL),
              (try? local.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw WebWallpaperFailure(message: "Blocked or missing local Web wallpaper resource.")
        }
        return local
    }

    static func contains(_ candidate: URL, in root: URL) -> Bool {
        candidate.path.hasPrefix(root.path + "/")
    }
}

struct WebWallpaperPropertyPayload: Sendable {
    let json: String
    let unsupportedKeys: [String]

    init(_ data: Data, resources: WebWallpaperResourceSnapshot? = nil) throws {
        guard data.count <= 1024 * 1024,
              let properties = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WebWallpaperFailure(message: "Author properties must be a JSON object smaller than 1 MiB.")
        }
        var accepted: [String: Any] = [:]
        var unsupported: [String] = []
        for (key, object) in properties {
            guard !key.isEmpty, key.utf8.count <= 256,
                  let property = object as? [String: Any], let type = property["type"] as? String else {
                throw WebWallpaperFailure(message: "Invalid author property definition.")
            }
            if type == "file" || type == "directory" {
                guard let resources else { unsupported.append(key); continue }
                guard let path = property["value"] as? String else { throw WebWallpaperFailure(message: "Resource property requires an opaque virtual path.") }
                if type == "file" {
                    guard path.isEmpty || resources.files[path] != nil else { throw WebWallpaperFailure(message: "File property has no matching native grant.") }
                } else {
                    guard path.isEmpty || resources.directoryModes[path] != nil else { throw WebWallpaperFailure(message: "Directory property has no matching native grant.") }
                    if resources.directoryModes[path] == .fetchall || property["mode"] as? String == "fetchall" { continue }
                }
                accepted[key] = property
                continue
            }
            guard let value = property["value"] else { throw WebWallpaperFailure(message: "Author property \(key) has no value.") }
            let number = value as? NSNumber
            let isBool = number.map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
            let valid: Bool
            switch type {
            case "bool": valid = isBool
            case "slider": valid = number != nil && !isBool && number!.doubleValue.isFinite
            case "combo": valid = value is String || (number != nil && number!.doubleValue.isFinite)
            case "textinput": valid = (value as? String).map { $0.utf8.count <= 64 * 1024 } ?? false
            case "color":
                let tokens = (value as? String)?.split(whereSeparator: \.isWhitespace) ?? []
                let values = tokens.compactMap { Double($0) }
                valid = tokens.count == 3 && values.count == 3 && values.allSatisfy { $0.isFinite && (0...1).contains($0) }
            default: throw WebWallpaperFailure(message: "Unsupported author property type: \(type).")
            }
            guard valid else { throw WebWallpaperFailure(message: "Invalid value for author property \(key).") }
            accepted[key] = property
        }
        let normalized = try JSONSerialization.data(withJSONObject: accepted, options: [.sortedKeys])
        json = String(decoding: normalized, as: UTF8.self)
        unsupportedKeys = unsupported.sorted()
    }

    static func generalJSON(_ data: Data) throws -> String {
        guard data.count <= 4096, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object.keys.allSatisfy({ $0 == "fps" }), let fps = object["fps"] as? NSNumber,
              CFGetTypeID(fps) != CFBooleanGetTypeID(), fps.doubleValue.isFinite, (1...240).contains(fps.doubleValue) else {
            throw WebWallpaperFailure(message: "General Web settings support only fps in 1...240.")
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }
}
