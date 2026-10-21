import CryptoKit
import Foundation

/// A folder of pinned, versioned installs that the app downloads on demand (the Chromium engine,
/// the depth model), and the steps every such install shares, off the main actor:
///
///     <version>/          one folder per installed version
///     .state.json         the active and the previous version (`VersionedInstallState`)
///     .staging-<uuid>/    one install in progress
///
/// `install(version:build:)` gives the specialization a fresh staging folder to fill: it downloads
/// each file with `fetch`, which checks it against its pinned SHA-256 before keeping it, and returns
/// the finished version folder. Only then is that folder renamed into place, so a cancelled, failed
/// or mismatched install never leaves a half install. Replacing a folder of the same version keeps
/// the old one until the new one is in place, and puts it back if that fails. Only the active and
/// the previous version are kept.
struct VersionedInstallStore: Sendable {
    /// A downloaded file's SHA-256 isn't its pin.
    struct ChecksumMismatch: Error, Equatable {
        let expected: String
        let actual: String
    }

    static let stagingPrefix = ".staging-"

    let root: URL
    /// Where its log lines go, and what they call the install ("Chromium engine").
    let category: OWELog.Category
    let subject: String

    /// Runs one install of `version`: `build` fills the staging folder it is given and returns the
    /// folder to install, which is then committed.
    func install(version: String, build: (_ staging: URL) async throws -> URL) async throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        removeStaleStaging()
        let staging = root.appending(path: "\(Self.stagingPrefix)\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { remove(staging) }
        let unpacked = try await build(staging)
        try commit(unpacked, version: version, staging: staging)
    }

    /// Downloads `url` to `destination`'s `.partial` sibling, checks it against `sha256` and only
    /// then renames it to `destination`. `verifying` runs between the two; `mismatch` turns a wrong
    /// checksum into the specialization's own error.
    func fetch(_ url: URL, sha256: String, to destination: URL,
               downloader: SteamCmdPackageDownloading,
               progress: @escaping @Sendable (Double?) -> Void,
               verifying: () -> Void = {},
               mismatch: (ChecksumMismatch) -> Error = { $0 }) async throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = destination.appendingPathExtension("partial")
        try await downloader.download(url, to: partial, progress: progress)
        try Task.checkCancellation()
        verifying()
        do {
            try Self.verify(partial, sha256: sha256)
        } catch let error as ChecksumMismatch {
            throw mismatch(error)
        }
        try fileManager.moveItem(at: partial, to: destination)
    }

    /// Renames `unpacked` into place as `version`, records it as active and prunes. A folder of
    /// the same version is set aside first and restored if the rename fails.
    func commit(_ unpacked: URL, version: String, staging: URL) throws {
        let fileManager = FileManager.default
        let target = root.appending(path: version, directoryHint: .isDirectory)
        let setAside = staging.appending(path: "replaced", directoryHint: .isDirectory)
        let hadTarget = fileManager.fileExists(atPath: target.path)
        if hadTarget {
            try fileManager.moveItem(at: target, to: setAside)
        }
        do {
            try fileManager.moveItem(at: unpacked, to: target)
        } catch {
            if hadTarget {
                do {
                    try fileManager.moveItem(at: setAside, to: target)
                } catch let restoreError {
                    OWELog.error(category, "Can't restore the \(subject) at \(target.path): \(restoreError)")
                }
            }
            throw error
        }
        var state = VersionedInstallState.read(in: root)
        if state.active != version {
            state.previous = state.active
            state.active = version
        }
        try state.write(in: root)
        prune(keeping: [state.active, state.previous].compactMap { $0 })
    }

    // MARK: Versions

    /// Version folders under `root`: every visible folder.
    var installedVersions: [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.filter { name in
            var isDirectory: ObjCBool = false
            return !name.hasPrefix(".")
                && FileManager.default.fileExists(atPath: root.appending(path: name).path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }.sorted()
    }

    /// Bytes every installed version takes together, nil without any.
    var installedSize: Int64? {
        let versions = installedVersions
        return versions.isEmpty ? nil : versions.reduce(Int64(0)) {
            $0 + SteamCmdPackage.size(of: root.appending(path: $1, directoryHint: .isDirectory))
        }
    }

    /// Deletes every version folder not in `keeping`.
    func prune(keeping: [String]) {
        for version in installedVersions where !keeping.contains(version) {
            OWELog.info(category, "Removing \(subject) \(version)")
            remove(root.appending(path: version, directoryHint: .isDirectory))
        }
    }

    /// Staging folders a crashed or killed install left behind.
    func removeStaleStaging() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for name in names where name.hasPrefix(Self.stagingPrefix) {
            remove(root.appending(path: name, directoryHint: .isDirectory))
        }
    }

    private func remove(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            OWELog.error(category, "Can't remove \(url.path): \(error)")
        }
    }

    // MARK: SHA-256

    /// Lowercase hex SHA-256 of `file`, read in 1 MiB chunks.
    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() } // Closing a read handle has nothing to report.
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return Digest.hex(hasher.finalize())
    }

    /// Throws `ChecksumMismatch` unless `file`'s SHA-256 is `expected`.
    static func verify(_ file: URL, sha256 expected: String) throws {
        let actual = try sha256(of: file)
        guard actual == expected.lowercased() else {
            throw ChecksumMismatch(expected: expected.lowercased(), actual: actual)
        }
    }
}
