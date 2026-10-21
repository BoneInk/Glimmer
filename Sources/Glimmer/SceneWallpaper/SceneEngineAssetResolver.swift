import Foundation
import Darwin
import CryptoKit

/// A local receipt for broker-verified app 431960 resources. This type never
/// restores a session, launches a helper, or makes a network request.
struct SceneEngineAssetResolver: Sendable {
    static let requiredResources: Set<String> = [
        "materials/particle/halo.tex", "materials/particle/beam/beam_1.tex",
        "materials/particle/fog/fog1.tex", "materials/particle/beam/hose_2.tex",
        "materials/particle/beam/hose_2_normal.tex", "materials/util/noise.tex",
        "materials/gradient/gradient_iridescent.tex"
    ]
    static let allowedResources = requiredResources.union(["shaders/common_blending.h","fonts/Alcubierre.otf"])
    private static let maximumBytes: UInt64 = 64 * 1024 * 1024
    private static let receiptName = "active-receipt.json"
    let workspaceURL: URL

    /// Fixed production location; an author project or receipt cannot select it.
    static var production: Self {
        #if GW_UI_REVIEW
        guard let root = ProcessInfo.processInfo.environment["GW_UI_REVIEW_ROOT"] else {
            preconditionFailure("UI review requires a temporary GW_UI_REVIEW_ROOT")
        }
        let appRoot = URL(fileURLWithPath: root, isDirectory: true)
        #else
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        // Deliberately fixed, matching AppConstants.applicationSupportFolderName.
        let appRoot = base.appendingPathComponent(AppConstants.applicationSupportFolderName, isDirectory: true)
        #endif
        return Self(workspaceURL: appRoot.appendingPathComponent("Workshop/SteamContent", isDirectory: true))
    }

    struct Manifest: Codable, Sendable {
        let sha256: String
        let depotID: UInt32
        let manifestID: String
    }
    struct File: Codable, Sendable {
        let logicalPath: String
        let sha256: String
        let sizeBytes: UInt64
    }
    struct Receipt: Codable, Sendable {
        let schemaVersion: Int
        let appID: UInt32
        let manifestIdentity: Manifest
        let files: [File]
    }
    struct Resolution: Sendable {
        let inspection: SceneWallpaperInspection
        let engineAssets: SceneEngineAssetBundle?
    }

    static func loadRegisteredBundle() throws -> SceneEngineAssetBundle? {
        try production.loadBundle()
    }

    /// A renderable project returns before the provider is consulted. Explicit
    /// test bundles retain the same dependency retry semantics as the cache.
    func resolve(projectURL: URL, propertiesJSON: Data? = nil, limits: SceneReadLimits = SceneReadLimits(),
                 engineAssets: SceneEngineAssetBundle? = nil,
                 provider: (@Sendable () throws -> SceneEngineAssetBundle?)? = nil) throws -> Resolution {
        try Task.checkCancellation()
        let baseline = try SceneWallpaperInspector.inspect(projectURL: projectURL, propertiesJSON: propertiesJSON, limits: limits)
        guard !baseline.isRenderableSubset else { return .init(inspection: baseline, engineAssets: nil) }
        try Task.checkCancellation()
        do {
            let available: SceneEngineAssetBundle?
            if let engineAssets { available = engineAssets }
            else if let provider { available = try provider() }
            else { available = try loadBundle() }
            guard let bundle = available else { return .init(inspection: baseline, engineAssets: nil) }
            let retry = try SceneWallpaperInspector.inspect(projectURL: projectURL, propertiesJSON: propertiesJSON, limits: limits, engineAssets: bundle)
            return .init(inspection: retry, engineAssets: bundle)
        } catch is CancellationError { throw CancellationError() }
        catch { return .init(inspection: baseline, engineAssets: nil) }
    }

    func loadBundle() throws -> SceneEngineAssetBundle? {
        guard FileManager.default.fileExists(atPath: workspaceURL.path) else { return nil }
        let workspace = try Self.openPrivateRoot(workspaceURL)
        defer { close(workspace) }
        let directory = openat(workspace, "engine-assets", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if directory < 0, errno == ENOENT { return nil }
        guard directory >= 0 else { throw Self.invalid() }
        defer { close(directory) }
        try Self.checkPrivateDirectory(directory)
        let descriptor = openat(directory, Self.receiptName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if descriptor < 0, errno == ENOENT { return nil }
        guard descriptor >= 0 else { throw Self.invalid() }
        defer { close(descriptor) }
        let data = try Self.readFile(descriptor, maximum: 64 * 1024)
        // Codable alone ignores unknown keys. Reject author-supplied root/path
        // fields rather than giving them any role in resource authority.
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(json.keys) == ["schemaVersion", "appID", "manifestIdentity", "files"],
              let identity = json["manifestIdentity"] as? [String: Any], Set(identity.keys) == ["sha256", "depotID", "manifestID"],
              let files = json["files"] as? [[String: Any]], files.allSatisfy({ Set($0.keys) == ["logicalPath", "sha256", "sizeBytes"] }) else { throw Self.invalid() }
        let receipt = try JSONDecoder().decode(Receipt.self, from: data)
        return try verifiedBundle(receipt, workspace: workspace)
    }

    /// Called by the Steam-type adapter only after broker completion. Rechecks
    /// the retained files before atomically selecting this immutable manifest.
    func register(_ receipt: Receipt, expectedContentRoot: URL) throws {
        try Self.validate(receipt)
        let expected = workspaceURL.appendingPathComponent("engine-assets/\(receipt.manifestIdentity.sha256)/content", isDirectory: true)
        guard expectedContentRoot.isFileURL, expectedContentRoot.path == expected.path else { throw Self.invalid() }
        let workspace = try Self.openPrivateRoot(workspaceURL)
        defer { close(workspace) }
        _ = try verifiedBundle(receipt, workspace: workspace)
        let directory = try Self.openDirectory(workspace, path: "engine-assets")
        defer { close(directory) }
        let data = try JSONEncoder().encode(receipt)
        guard data.count <= 64 * 1024 else { throw Self.invalid() }
        let temporary = ".active-receipt-\(UUID().uuidString)"
        let descriptor = openat(directory, temporary, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Self.invalid() }
        defer { close(descriptor); _ = unlinkat(directory, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            var position = 0
            while position < bytes.count {
                try Task.checkCancellation()
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: position), bytes.count - position)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Self.invalid() }
                position += count
            }
        }
        try Task.checkCancellation()
        guard fsync(descriptor) == 0, renameat(directory, temporary, directory, Self.receiptName) == 0 else { throw Self.invalid() }
        _ = fsync(directory)
    }

    private func verifiedBundle(_ receipt: Receipt, workspace: Int32) throws -> SceneEngineAssetBundle {
        try Self.validate(receipt)
        let relative = "engine-assets/\(receipt.manifestIdentity.sha256)/content/assets"
        let assets = try Self.openDirectory(workspace, path: relative)
        defer { close(assets) }
        for file in receipt.files {
            try Task.checkCancellation()
            let parts = file.logicalPath.split(separator: "/").map(String.init)
            let parent = try Self.openDirectory(assets, path: parts.dropLast().joined(separator: "/"))
            defer { close(parent) }
            let descriptor = openat(parent, parts.last!, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard descriptor >= 0 else { throw Self.invalid() }
            defer { close(descriptor) }
            let data = try Self.readFile(descriptor, maximum: Int(Self.maximumBytes), expected: file.sizeBytes)
            guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == file.sha256 else { throw Self.invalid() }
        }
        return SceneEngineAssetBundle(rootURL: workspaceURL.appendingPathComponent(relative, isDirectory: true),
            manifestIdentity: receipt.manifestIdentity.sha256,
            verifiedFiles: Dictionary(uniqueKeysWithValues: receipt.files.map { ($0.logicalPath, $0.sha256) }), requiresPrivateRoot: true)
    }

    private static func validate(_ receipt: Receipt) throws {
        let identity = receipt.manifestIdentity
        guard receipt.schemaVersion == 1, receipt.appID == 431960, isDigest(identity.sha256), identity.depotID > 0,
              let manifest = UInt64(identity.manifestID), manifest > 0, String(manifest) == identity.manifestID,
              (requiredResources.count...allowedResources.count).contains(receipt.files.count) else { throw invalid() }
        var paths = Set<String>(), total: UInt64 = 0
        for file in receipt.files {
            guard allowedResources.contains(file.logicalPath), paths.insert(file.logicalPath).inserted,
                  isDigest(file.sha256), file.sizeBytes > 0, file.sizeBytes <= maximumBytes,
                  total <= maximumBytes - file.sizeBytes else { throw invalid() }
            total += file.sizeBytes
        }
        guard requiredResources.isSubset(of: paths) else { throw invalid() }
    }
    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func openPrivateRoot(_ url: URL) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("//"),
              url.path.split(separator:"/").allSatisfy({ $0 != "." && $0 != ".." }) else { throw invalid() }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw invalid() }
        do {
            for part in url.path.split(separator: "/") {
                let next = openat(descriptor, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                guard next >= 0 else { throw invalid() }
                close(descriptor); descriptor = next
            }
            try checkPrivateDirectory(descriptor)
            return descriptor
        } catch { close(descriptor); throw error }
    }
    private static func openDirectory(_ root: Int32, path: String) throws -> Int32 {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw invalid() }
        var descriptor = dup(root)
        guard descriptor >= 0 else { throw invalid() }
        do {
            for part in parts {
                let next = openat(descriptor, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                guard next >= 0 else { throw invalid() }
                close(descriptor); descriptor = next
                try checkPrivateDirectory(descriptor)
            }
            return descriptor
        } catch { close(descriptor); throw error }
    }
    private static func checkPrivateDirectory(_ descriptor: Int32) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw invalid() }
    }
    private static func readFile(_ descriptor: Int32, maximum: Int, expected: UInt64? = nil) throws -> Data {
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == getuid(), before.st_nlink == 1, before.st_size >= 0, before.st_size <= maximum,
              before.st_mode & 0o077 == 0, expected == nil || UInt64(before.st_size) == expected else { throw invalid() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0, count <= maximum - data.count else { throw invalid() }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, data.count == before.st_size, after.st_size == before.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw invalid() }
        return data
    }
    private static func invalid() -> SceneWallpaperFailure {
        SceneWallpaperFailure(message: "已登记的 Wallpaper Engine 内置资源不可用或校验失败。")
    }
}

extension SceneWallpaperInspector {
    static func inspectUsingAvailableEngineAssets(projectURL: URL, propertiesJSON: Data? = nil,
        limits: SceneReadLimits = SceneReadLimits(), resolver: SceneEngineAssetResolver = .production) throws -> SceneWallpaperInspection {
        try resolver.resolve(projectURL: projectURL, propertiesJSON: propertiesJSON, limits: limits).inspection
    }
}
