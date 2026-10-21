import Foundation
import CryptoKit
import Darwin

enum SceneRuntimeAssetRegistryError: String, Error, Equatable, Sendable {
    case invalidBundle = "scene_runtime_registry_invalid_bundle"
    case contentVerificationFailed = "scene_runtime_registry_content_verification_failed"
    case unsafeRegistry = "scene_runtime_registry_unsafe_registry"
    case invalidReceipt = "scene_runtime_registry_invalid_receipt"
    case publicationFailed = "scene_runtime_registry_publication_failed"
}

/// Selects one immutable, broker-verified Scene runtime dataset. The receipt
/// contains no filesystem authority; its content root is always derived from
/// the fixed app-owned SteamContent workspace and manifest fingerprint.
struct SceneRuntimeAssetRegistry: Sendable {
    static let maximumFiles = 4096
    static let maximumBytes: UInt64 = 128 * 1024 * 1024
    static let maximumFileBytes: UInt64 = 16 * 1024 * 1024
    private static let maximumReceiptBytes = 2 * 1024 * 1024
    private static let receiptName = "active-receipt.json"

    let contentWorkspaceURL: URL
    let registryURL: URL

    static var production: Self {
        #if GW_UI_REVIEW
        guard let root = ProcessInfo.processInfo.environment["GW_UI_REVIEW_ROOT"] else {
            preconditionFailure("UI review requires a temporary GW_UI_REVIEW_ROOT")
        }
        let appRoot = URL(fileURLWithPath: root, isDirectory: true)
        #else
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        let appRoot = base.appendingPathComponent(AppConstants.applicationSupportFolderName, isDirectory: true)
        #endif
        return Self(contentWorkspaceURL: appRoot.appendingPathComponent("Workshop/SteamContent", isDirectory: true),
                    registryURL: appRoot.appendingPathComponent("SceneBackend", isDirectory: true))
    }

    struct Resolved: Sendable {
        let assetsRootURL: URL
        let manifestFingerprint: String
        let depotID: UInt32
        let manifestID: UInt64
        let files: [SteamEngineAssetFile]
        var verifiedFiles: [String: String] {
            Dictionary(uniqueKeysWithValues: files.map { ($0.logicalPath, $0.sha256) })
        }
    }

    private struct Manifest: Codable, Sendable {
        let sha256: String
        let depotID: UInt32
        let manifestID: String
    }
    private struct File: Codable, Sendable {
        let logicalPath: String
        let sha256: String
        let sizeBytes: UInt64
    }
    private struct Receipt: Codable, Sendable {
        let schemaVersion: Int
        let appID: UInt32
        let manifestIdentity: Manifest
        let files: [File]
    }

    static var isAvailable: Bool { (try? loadRegisteredBundle()) != nil }
    var isAvailable: Bool { (try? loadRegisteredBundle()) != nil }

    static func registerVerifiedSteamBundle(_ bundle: SteamSceneRuntimeAssetBundle) throws {
        try production.registerVerifiedSteamBundle(bundle)
    }

    static func loadRegisteredBundle() throws -> Resolved? {
        try production.loadRegisteredBundle()
    }

    func registerVerifiedSteamBundle(_ bundle: SteamSceneRuntimeAssetBundle) throws {
        try Task.checkCancellation()
        let identity = bundle.manifestIdentity
        let files = try bundle.files.map { value -> File in
            guard value.relativePath == "assets/" + value.logicalPath else {
                throw SceneRuntimeAssetRegistryError.invalidBundle
            }
            return .init(logicalPath: value.logicalPath, sha256: value.sha256, sizeBytes: value.sizeBytes)
        }.sorted { $0.logicalPath < $1.logicalPath }
        let receipt = Receipt(schemaVersion: 1, appID: 431960,
            manifestIdentity: .init(sha256: identity.sha256, depotID: identity.depotID,
                                    manifestID: String(identity.manifestID)), files: files)
        do { try Self.validate(receipt) }
        catch is CancellationError { throw CancellationError() }
        catch { throw SceneRuntimeAssetRegistryError.invalidBundle }
        let expected = contentWorkspaceURL.appendingPathComponent(
            "scene-runtime-assets/\(identity.sha256)/content", isDirectory: true)
        guard bundle.cacheRoot.isFileURL, bundle.cacheRoot.path == expected.path else {
            throw SceneRuntimeAssetRegistryError.invalidBundle
        }
        do { _ = try verified(receipt) }
        catch is CancellationError { throw CancellationError() }
        catch { throw SceneRuntimeAssetRegistryError.contentVerificationFailed }
        do { try ensureRegistryDirectory() }
        catch is CancellationError { throw CancellationError() }
        catch { throw SceneRuntimeAssetRegistryError.unsafeRegistry }
        let directory: Int32
        do { directory = try Self.openPrivateRoot(registryURL) }
        catch { throw SceneRuntimeAssetRegistryError.unsafeRegistry }
        defer { close(directory) }
        let data = try JSONEncoder().encode(receipt)
        guard data.count <= Self.maximumReceiptBytes else {
            throw SceneRuntimeAssetRegistryError.invalidBundle
        }
        let temporary = ".active-receipt-\(UUID().uuidString)"
        let descriptor = openat(directory, temporary, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw SceneRuntimeAssetRegistryError.publicationFailed }
        defer { close(descriptor); _ = unlinkat(directory, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw SceneRuntimeAssetRegistryError.publicationFailed }
                offset += count
            }
        }
        try Task.checkCancellation()
        guard fsync(descriptor) == 0,
              renameat(directory, temporary, directory, Self.receiptName) == 0,
              fsync(directory) == 0 else { throw SceneRuntimeAssetRegistryError.publicationFailed }
    }

    func loadRegisteredBundle() throws -> Resolved? {
        guard FileManager.default.fileExists(atPath: registryURL.path) else { return nil }
        let directory: Int32
        do { directory = try Self.openPrivateRoot(registryURL) }
        catch { throw SceneRuntimeAssetRegistryError.unsafeRegistry }
        defer { close(directory) }
        let descriptor = openat(directory, Self.receiptName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if descriptor < 0, errno == ENOENT { return nil }
        guard descriptor >= 0 else { throw SceneRuntimeAssetRegistryError.invalidReceipt }
        defer { close(descriptor) }
        let data: Data
        do { data = try Self.readRegularFile(descriptor, maximum: Self.maximumReceiptBytes) }
        catch is CancellationError { throw CancellationError() }
        catch { throw SceneRuntimeAssetRegistryError.invalidReceipt }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(json.keys) == ["schemaVersion", "appID", "manifestIdentity", "files"],
              let identity = json["manifestIdentity"] as? [String: Any],
              Set(identity.keys) == ["sha256", "depotID", "manifestID"],
              let files = json["files"] as? [[String: Any]],
              files.allSatisfy({ Set($0.keys) == ["logicalPath", "sha256", "sizeBytes"] }) else {
            throw SceneRuntimeAssetRegistryError.invalidReceipt
        }
        let receipt: Receipt
        do { receipt = try JSONDecoder().decode(Receipt.self, from: data) }
        catch { throw SceneRuntimeAssetRegistryError.invalidReceipt }
        do { return try verified(receipt) }
        catch is CancellationError { throw CancellationError() }
        catch { throw SceneRuntimeAssetRegistryError.contentVerificationFailed }
    }

    private func verified(_ receipt: Receipt) throws -> Resolved {
        try Self.validate(receipt)
        let workspace = try Self.openPrivateRoot(contentWorkspaceURL)
        defer { close(workspace) }
        let relative = "scene-runtime-assets/\(receipt.manifestIdentity.sha256)/content/assets"
        let assets = try Self.openDirectory(workspace, path: relative)
        defer { close(assets) }
        var expected: [String: File] = [:]
        var expectedDirectories = Set<String>()
        for file in receipt.files {
            expected[file.logicalPath] = file
            var path = file.logicalPath
            while let slash = path.lastIndex(of: "/") {
                path = String(path[..<slash]); expectedDirectories.insert(path)
            }
        }
        var seen = Set<String>(), nodes = 0
        try Self.verifyTree(assets, prefix: "", depth: 0, expected: expected,
                            expectedDirectories: expectedDirectories, seen: &seen, nodes: &nodes)
        guard seen.count == expected.count else { throw Self.invalid() }
        let identity = receipt.manifestIdentity
        let files = receipt.files.map {
            SteamEngineAssetFile(logicalPath: $0.logicalPath, relativePath: "assets/" + $0.logicalPath,
                                 sha256: $0.sha256, sizeBytes: $0.sizeBytes)
        }
        return .init(assetsRootURL: contentWorkspaceURL.appendingPathComponent(relative, isDirectory: true),
                     manifestFingerprint: identity.sha256, depotID: identity.depotID,
                     manifestID: UInt64(identity.manifestID)!, files: files)
    }

    private static func validate(_ receipt: Receipt) throws {
        let identity = receipt.manifestIdentity
        guard receipt.schemaVersion == 1, receipt.appID == 431960, isDigest(identity.sha256), identity.depotID > 0,
              let manifestID = UInt64(identity.manifestID), manifestID > 0,
              String(manifestID) == identity.manifestID,
              (1...maximumFiles).contains(receipt.files.count) else { throw invalid() }
        var paths = Set<String>(), total: UInt64 = 0, previous = ""
        for file in receipt.files {
            guard try normalized(file.logicalPath) == file.logicalPath, file.logicalPath > previous,
                  paths.insert(file.logicalPath).inserted, isDigest(file.sha256),
                  file.sizeBytes > 0, file.sizeBytes <= maximumFileBytes,
                  total <= maximumBytes - file.sizeBytes else { throw invalid() }
            total += file.sizeBytes; previous = file.logicalPath
        }
    }

    private func ensureRegistryDirectory() throws {
        guard registryURL.isFileURL, registryURL.path.hasPrefix("/"),
              registryURL.standardizedFileURL.path == registryURL.path,
              !registryURL.lastPathComponent.isEmpty else { throw SceneRuntimeAssetRegistryError.unsafeRegistry }
        // The long-lived app-support root predates this registry and may be
        // owner-readable (0755). It is still a safe creation authority when it
        // is owned by this user and has no group/other write bit. The newly
        // created registry remains strictly private (0700).
        let parent = try Self.openOwnedNonWritableRoot(registryURL.deletingLastPathComponent())
        defer { close(parent) }
        if mkdirat(parent, registryURL.lastPathComponent, 0o700) != 0, errno != EEXIST {
            throw SceneRuntimeAssetRegistryError.unsafeRegistry
        }
        let directory = openat(parent, registryURL.lastPathComponent,
                               O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard directory >= 0 else { throw SceneRuntimeAssetRegistryError.unsafeRegistry }
        defer { close(directory) }
        try Self.checkPrivateDirectory(directory)
    }

    private static func verifyFile(_ parent: Int32, name: String, file: File) throws {
        let descriptor = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw invalid() }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == getuid(), before.st_nlink == 1, before.st_mode & 0o077 == 0,
              before.st_size >= 0, UInt64(before.st_size) == file.sizeBytes else { throw invalid() }
        var digest = SHA256(), count: UInt64 = 0, buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try Task.checkCancellation()
            let length = Darwin.read(descriptor, &buffer, buffer.count)
            if length < 0, errno == EINTR { continue }
            guard length >= 0, count <= file.sizeBytes - UInt64(length) else { throw invalid() }
            if length == 0 { break }
            digest.update(data: Data(buffer.prefix(length))); count += UInt64(length)
        }
        var after = stat()
        guard count == file.sizeBytes, fstat(descriptor, &after) == 0,
              after.st_size == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
              digest.finalize().map({ String(format: "%02x", $0) }).joined() == file.sha256 else { throw invalid() }
    }

    private static func verifyTree(_ directory: Int32, prefix: String, depth: Int,
                                   expected: [String: File], expectedDirectories: Set<String>,
                                   seen: inout Set<String>, nodes: inout Int) throws {
        guard depth <= 32, let stream = fdopendir(dup(directory)) else { throw invalid() }
        defer { closedir(stream) }
        errno = 0
        while let entry = readdir(stream) {
            try Task.checkCancellation()
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            nodes += 1; guard nodes <= 40_000 else { throw invalid() }
            let path = prefix.isEmpty ? name : prefix + "/" + name
            var info = stat()
            guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_uid == getuid() else { throw invalid() }
            if info.st_mode & S_IFMT == S_IFDIR {
                guard info.st_mode & 0o077 == 0, expectedDirectories.contains(path) else { throw invalid() }
                let child = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                guard child >= 0 else { throw invalid() }
                do {
                    try checkPrivateDirectory(child)
                    try verifyTree(child, prefix: path, depth: depth + 1, expected: expected,
                                   expectedDirectories: expectedDirectories, seen: &seen, nodes: &nodes)
                    close(child)
                } catch {
                    close(child)
                    throw error
                }
            } else {
                guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_mode & 0o077 == 0,
                      info.st_size >= 0, let file = expected[path], UInt64(info.st_size) == file.sizeBytes,
                      seen.insert(path).inserted else { throw invalid() }
                // Hash through the already-open, checked parent while walking
                // the complete tree. Reopening every ancestor for every file
                // performed the same validation thousands of times per load.
                try verifyFile(directory, name: name, file: file)
            }
            errno = 0
        }
        guard errno == 0 else { throw invalid() }
    }

    private static func openPrivateRoot(_ url: URL) throws -> Int32 {
        let descriptor = try openOwnedRoot(url)
        do { try checkPrivateDirectory(descriptor); return descriptor }
        catch { close(descriptor); throw error }
    }

    private static func openOwnedNonWritableRoot(_ url: URL) throws -> Int32 {
        let descriptor = try openOwnedRoot(url)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o022 == 0 else {
            close(descriptor); throw SceneRuntimeAssetRegistryError.unsafeRegistry
        }
        return descriptor
    }

    private static func openOwnedRoot(_ url: URL) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("//"),
              url.path.split(separator: "/").allSatisfy({ $0 != "." && $0 != ".." }) else { throw invalid() }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw invalid() }
        do {
            for part in url.path.split(separator: "/") {
                let next = openat(descriptor, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                guard next >= 0 else { throw invalid() }
                close(descriptor); descriptor = next
            }
            return descriptor
        } catch { close(descriptor); throw error }
    }

    private static func openDirectory(_ root: Int32, path: String) throws -> Int32 {
        let normalized = try normalized(path)
        var descriptor = dup(root)
        guard descriptor >= 0 else { throw invalid() }
        do {
            for part in normalized.split(separator: "/") {
                let next = openat(descriptor, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                guard next >= 0 else { throw invalid() }
                close(descriptor); descriptor = next; try checkPrivateDirectory(descriptor)
            }
            return descriptor
        } catch { close(descriptor); throw error }
    }

    private static func checkPrivateDirectory(_ descriptor: Int32) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw invalid() }
    }

    private static func readRegularFile(_ descriptor: Int32, maximum: Int) throws -> Data {
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == getuid(), before.st_nlink == 1, before.st_mode & 0o077 == 0,
              before.st_size >= 0, before.st_size <= maximum else { throw invalid() }
        var data = Data(count: Int(before.st_size)), offset = 0
        try data.withUnsafeMutableBytes { bytes in
            while offset < bytes.count {
                try Task.checkCancellation()
                let count = Darwin.read(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw invalid() }
                offset += count
            }
        }
        var extra: UInt8 = 0
        var after = stat()
        guard Darwin.read(descriptor, &extra, 1) == 0, fstat(descriptor, &after) == 0,
              after.st_size == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec else { throw invalid() }
        return data
    }

    private static func normalized(_ value: String) throws -> String {
        guard !value.isEmpty, value.utf8.count <= 1024, !value.hasPrefix("/"), !value.hasPrefix("\\"),
              value.precomposedStringWithCanonicalMapping == value,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw invalid() }
        let parts = value.replacingOccurrences(of: "\\", with: "/").split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count <= 32, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 200 &&
            !$0.contains(":") && !$0.hasSuffix(".") && !$0.hasSuffix(" ") }) else { throw invalid() }
        return parts.joined(separator: "/")
    }

    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func invalid() -> SceneRuntimeAssetRegistryError { .contentVerificationFailed }
}
