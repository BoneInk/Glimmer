import Foundation

/// The one place that finds and reads a wallpaper folder's project.json, for the app
/// (`WEProject`'s file helpers forward here) and the editor. Each reader keeps the tolerance it
/// had: `object(in:)` is strict (as `JSONSerialization` is), and a caller that accepts WE's
/// looser JSON reads `data(in:)` with `TolerantJSON` or `decodeTolerant` itself.
public enum WEProjectFile {
    /// The project file's name inside a wallpaper folder.
    public static let fileName = "project.json"

    /// project.json in `directory`.
    public static func url(in directory: URL) -> URL {
        directory.appending(path: fileName)
    }

    /// Whether `directory` has a project.json.
    public static func exists(in directory: URL, fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: url(in: directory).path)
    }

    /// project.json's bytes as written; throws when it can't be read.
    public static func data(in directory: URL) throws -> Data {
        try Data(contentsOf: url(in: directory))
    }

    /// project.json parsed by `JSONSerialization`, for callers that need fields a model doesn't
    /// have; throws when it can't be read or parsed.
    public static func object(in directory: URL) throws -> Any {
        try JSONSerialization.jsonObject(with: data(in: directory))
    }

    /// project.json's root object; nil when the root isn't an object. Throws as `object(in:)`.
    public static func json(in directory: URL) throws -> [String: Any]? {
        try object(in: directory) as? [String: Any]
    }
}
