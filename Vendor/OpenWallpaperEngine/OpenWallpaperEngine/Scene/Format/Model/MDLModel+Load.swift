import Foundation

extension MDLModel {
    init(data: Data) throws {
        self = try MDLReader.read(data) { OWELog.debug(.scene, $0) }
    }

    init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    /// The model at `path`, from the wallpaper's package when it has the entry (the order the
    /// scene loader reads assets in), else the loose file in `directory`.
    static func load(path: String, package: PKGParser?, directory: URL) throws -> MDLModel {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        if let package {
            let entry = package.fileList.first { $0.replacingOccurrences(of: "\\", with: "/") == normalized }
            if let entry, let data = package.extractFile(named: entry) {
                return try MDLModel(data: data)
            }
        }
        let url = directory.appending(path: normalized)
        guard FileManager.default.fileExists(atPath: url.path) else { throw MDLError.missing(path: path) }
        return try MDLModel(contentsOf: url)
    }
}
