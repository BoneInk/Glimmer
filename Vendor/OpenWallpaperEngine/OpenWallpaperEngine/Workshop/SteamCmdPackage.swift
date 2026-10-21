import Foundation

/// Valve's SteamCMD package for macOS: fetched from Valve at runtime, never shipped with the app.
/// The URL is the one on developer.valvesoftware.com/wiki/SteamCMD ("Manually" › macOS).
enum SteamCmdPackage {
    static let downloadURL = URL(string: "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_osx.tar.gz")!

    enum Failure: LocalizedError, Equatable {
        case notGzip
        case extractionFailed(String)
        case missingExecutable

        var errorDescription: String? {
            switch self {
            case .notGzip:
                return String(localized: "The SteamCMD download from Valve isn't a valid archive. Try again later.",
                              comment: "SteamCMD install error; SteamCMD is a program name")
            case .extractionFailed(let reason):
                return String(localized: "Can't extract SteamCMD: \(reason)",
                              comment: "SteamCMD install error; %@ is the system's reason")
            case .missingExecutable:
                return String(localized: "The SteamCMD package from Valve has no runnable steamcmd.sh.",
                              comment: "SteamCMD install error; steamcmd.sh is a file name")
            }
        }
    }

    /// Throws unless `archive` starts with the gzip magic bytes.
    static func checkGzip(_ archive: URL) throws {
        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() } // Closing a read handle has nothing to report.
        let magic = try handle.read(upToCount: 2) ?? Data()
        guard magic == Data([0x1F, 0x8B]) else { throw Failure.notGzip }
    }

    /// Extracts the gzipped tar `archive` into `directory` (created if needed) with the system's
    /// `tar`, clears the quarantine flag, and returns the verified `steamcmd.sh`.
    static func extract(_ archive: URL, into directory: URL) throws -> URL {
        try checkGzip(archive)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let process = Process()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        // -o: don't restore the archive's owner; -P is not given, so no path leaves `directory`.
        process.arguments = ["-xzof", archive.path, "-C", directory.path]
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure.extractionFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        removeQuarantine(under: directory)
        let executable = SteamCmdLocator.ownExecutable(in: directory)
        guard SteamCmdLocator.isExecutableFile(executable.path) else { throw Failure.missingExecutable }
        return executable
    }

    static let quarantineAttribute = "com.apple.quarantine"

    /// Removes Gatekeeper's quarantine flag from every file under `directory`, so the shell script
    /// and the binaries it starts run without a prompt. Files the app downloads itself are normally
    /// not flagged; this covers a copy that was.
    static func removeQuarantine(under directory: URL) {
        let paths = [directory.path] + (FileManager.default.enumerator(atPath: directory.path)?
            .compactMap { ($0 as? String).map { directory.appending(path: $0).path } } ?? [])
        for path in paths where hasQuarantine(path) {
            if removexattr(path, quarantineAttribute, XATTR_NOFOLLOW) != 0 {
                OWELog.error(.workshop, "Can't clear the quarantine flag of \(path): errno \(errno)")
            }
        }
    }

    static func hasQuarantine(_ path: String) -> Bool {
        getxattr(path, quarantineAttribute, nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    /// The bytes `directory` takes on disk.
    static func size(of directory: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            // A file that vanished while counting just doesn't count.
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
