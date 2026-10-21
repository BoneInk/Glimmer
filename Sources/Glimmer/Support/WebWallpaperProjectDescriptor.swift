import Foundation
import Darwin

enum WebProjectError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}

enum WebProjectPaths {
    /// Foundation rewrites /private/var aliases differently for enumerated URLs.
    /// Use the same POSIX canonical representation before containment/relative math.
    static func canonical(_ url: URL) throws -> URL {
        guard url.isFileURL, let buffer = realpath(url.path, nil) else {
            throw WebProjectError.invalid("项目路径不存在或不可访问")
        }
        defer { free(buffer) }
        return URL(fileURLWithPath: String(cString: buffer))
    }

    static func readProject(_ url: URL) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw WebProjectError.invalid("无法安全读取项目配置") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_size <= 2_097_152 else { throw WebProjectError.invalid("项目配置不是常规文件或超过 2 MB") }
        var bytes = Data()
        while let next = try handle.read(upToCount: min(65_536, 2_097_153 - bytes.count)), !next.isEmpty {
            try Task.checkCancellation(); bytes.append(next)
            guard bytes.count <= 2_097_152 else { throw WebProjectError.invalid("项目配置超过 2 MB") }
        }
        return bytes
    }

}

/// Local Web projects keep all resources inside their selected project directory.
struct WebWallpaperProjectDescriptor: Sendable {
    let projectURL: URL
    let root: URL
    let entryURL: URL
    let posterURL: URL?
    let title: String

    init(projectURL: URL) throws {
        let file = try WebProjectPaths.canonical(projectURL)
        guard file.lastPathComponent == "project.json" else { throw WebProjectError.invalid("请选择 Web 项目的 project.json") }
        let root = file.deletingLastPathComponent()
        let size = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard size.isRegularFile == true, (size.fileSize ?? Int.max) <= 2_097_152 else {
            throw WebProjectError.invalid("项目配置无效或超过 2 MB")
        }
        guard let json = try JSONSerialization.jsonObject(with: WebProjectPaths.readProject(file)) as? [String: Any],
              (json["type"] as? String)?.lowercased() == "web",
              let entry = json["file"] as? String, !entry.isEmpty else {
            throw WebProjectError.invalid("该项目不是可运行的 Web 壁纸（需要 type: web 和 file 入口）")
        }
        func resource(_ relative: String) -> URL? {
            guard !relative.hasPrefix("/"), !relative.contains(":"), !relative.contains("\\"), !relative.contains("\0") else { return nil }
            guard let candidate = try? WebProjectPaths.canonical(root.appendingPathComponent(relative)) else { return nil }
            guard candidate.path.hasPrefix(root.path + "/"),
                  (try? candidate.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
            return candidate
        }
        guard let entryURL = resource(entry), ["html", "htm"].contains(entryURL.pathExtension.lowercased()) else {
            throw WebProjectError.invalid("网页入口不存在或超出项目目录")
        }
        self.projectURL = file
        self.root = root
        self.entryURL = entryURL
        self.posterURL = (json["preview"] as? String).flatMap(resource)
        self.title = (json["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? root.lastPathComponent
    }
}

