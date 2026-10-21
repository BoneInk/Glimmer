import Darwin
import Foundation

/// Where the source a shader compiler step rejected is kept for inspection (CONTRIBUTING.md,
/// Debugging): a folder only the user can read, `<AppStorageLocation.appCachesDirectory>/
/// FailedShaders`, with one file per shader and stage.
///
/// The folder is created (or, if it exists, reset) with `directoryPermissions` and must be a real
/// folder, not a symbolic link. Each file is created afresh with `filePermissions` and never
/// written through a symbolic link: an existing entry of that name is removed first, then the file
/// is opened with `O_CREAT | O_EXCL | O_NOFOLLOW`.
struct FailedShaderDump {
    static let directoryPermissions: mode_t = 0o700
    static let filePermissions: mode_t = 0o600

    /// `~/Library/Caches/app.openwallpaperengine/FailedShaders` for the user's real launch;
    /// inside the isolated Caches folder for tests and development copies (`AppStorageLocation`).
    static var defaultDirectory: URL {
        AppStorageLocation.current.appCachesDirectory.appending(path: "FailedShaders", directoryHint: .isDirectory)
    }

    struct NotADirectory: Error, CustomStringConvertible {
        let path: String
        var description: String { "\(path) is not a folder (a symbolic link or a file is in its place)" }
    }

    let directory: URL

    /// Writes `contents` as `name` (a single path component) and returns the file's URL.
    @discardableResult
    func write(_ contents: String, named name: String) throws -> URL {
        try prepareDirectory()
        let url = directory.appending(path: name, directoryHint: .notDirectory)
        let data = Data(contents.utf8)
        // Two attempts: another thread may create the same name between the unlink and the open.
        var attempt = 0
        while true {
            attempt += 1
            if unlink(url.path) != 0, errno != ENOENT { throw Self.posixError() }
            let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, Self.filePermissions)
            if descriptor < 0 {
                if errno == EEXIST, attempt < 2 { continue }
                throw Self.posixError()
            }
            defer { close(descriptor) }
            // The umask may have dropped bits; the mode is set exactly.
            guard fchmod(descriptor, Self.filePermissions) == 0 else { throw Self.posixError() }
            try Self.writeAll(data, to: descriptor)
            return url
        }
    }

    /// Creates the folder with `directoryPermissions`, or resets an existing one to them.
    func prepareDirectory() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: Int(Self.directoryPermissions)])
        var info = stat()
        guard lstat(directory.path, &info) == 0 else { throw Self.posixError() }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw NotADirectory(path: directory.path) }
        if info.st_mode & 0o777 != Self.directoryPermissions {
            try fileManager.setAttributes([.posixPermissions: Int(Self.directoryPermissions)], ofItemAtPath: directory.path)
        }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, base + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw posixError()
                }
                offset += written
            }
        }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
