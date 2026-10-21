import Foundation

/// A wallpaper folder's project.json, found and read through WEFormat's `WEProjectFile` (the one
/// implementation, which the editor uses too). `read(in:)` is strict, as `JSONDecoder` is.
extension WEProject {
    /// The project file's name inside a wallpaper folder.
    static let fileName = WEProjectFile.fileName

    /// project.json in `directory`.
    static func url(in directory: URL) -> URL {
        WEProjectFile.url(in: directory)
    }

    /// Whether `directory` has a project.json.
    static func exists(in directory: URL) -> Bool {
        WEProjectFile.exists(in: directory)
    }

    /// project.json's bytes as written; throws when it can't be read.
    static func data(in directory: URL) throws -> Data {
        try WEProjectFile.data(in: directory)
    }

    /// project.json decoded as a `WEProject`; throws when it can't be read or decoded.
    static func read(in directory: URL) throws -> WEProject {
        try JSONDecoder().decode(WEProject.self, from: data(in: directory))
    }

    /// project.json parsed by `JSONSerialization`, for callers that need fields `WEProject` doesn't
    /// model; throws when it can't be read or parsed.
    static func object(in directory: URL) throws -> Any {
        try WEProjectFile.object(in: directory)
    }

    /// project.json's root object; nil when the root isn't an object. Throws as `object(in:)`.
    static func json(in directory: URL) throws -> [String: Any]? {
        try WEProjectFile.json(in: directory)
    }
}
