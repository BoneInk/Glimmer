import CryptoKit
import Darwin
import Foundation

/// Read-only Scene lock-screen inputs. Author values come from the same
/// validated payload used by desktop/preview; nothing is applied or saved.
@MainActor
enum SceneWallpaperLockScreenConfiguration {
    static func payload(item: WallpaperItem, storage: AppStorage) async throws -> Data {
        guard item.isSceneWallpaper else {
            throw RenderedLockScreenVideoFailure(message: "该素材不是 Scene 壁纸。")
        }
        return try await AuthorPropertyServices.payload(item: item, storage: storage)
    }

    /// Cache identity = complete project bytes + saved author payload + actual
    /// engine binary/official asset manifest identity.
    static func material(item: WallpaperItem, storage: AppStorage) async throws
        -> RenderedLockScreenVideoCache.Material {
        let payload = try await payload(item: item, storage: storage)
        let project = try AuthorPropertyProject.load(projectURL: item.fileURL,
            allowedRoot: item.fileURL.deletingLastPathComponent())
        guard project.projectType.lowercased() == "scene" else {
            throw RenderedLockScreenVideoFailure(message: "Scene 项目配置无效。")
        }
        let projectHash = try await RenderedLockScreenVideoCache.projectHash(
            root: project.projectURL.deletingLastPathComponent())
        let engineIdentity = try await SceneLockScreenEngineIdentity.current()
        let identityHash = RenderedLockScreenVideoCache.contentHash(
            Data("\(projectHash)\u{0}engine:\(engineIdentity)".utf8))
        return .init(identityHash: identityHash,
                     payloadHash: RenderedLockScreenVideoCache.contentHash(payload),
                     payload: payload)
    }
}

/// Identity of the actually installed universal Scene engine. Immutable app
/// binaries/resources are memoized; registered official-asset identity is read
/// on every cache lookup so registration changes take effect immediately.
enum SceneLockScreenEngineIdentity {
    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?
        func get() -> String? { lock.lock(); defer { lock.unlock() }; return value }
        func store(_ candidate: String) -> String {
            lock.lock(); defer { lock.unlock() }
            if let value { return value }
            value = candidate
            return candidate
        }
    }
    private static let immutableCache = Cache()

    static func current() async throws -> String {
        #if GW_UNIVERSAL_SCENE_BACKEND
        let appIdentity = try await immutableAppIdentity()
        let assetsIdentity = try await Task.detached(priority: .utility) {
            try registeredAssetsIdentity()
        }.value
        var digest = SHA256()
        feed("scene-lock-engine-v2", into: &digest)
        feed(appIdentity, into: &digest)
        feed(assetsIdentity, into: &digest)
        return hex(digest)
        #else
        return "universal-scene-backend-unavailable"
        #endif
    }

    private static func immutableAppIdentity() async throws -> String {
        #if GW_UNIVERSAL_SCENE_BACKEND
        if let value = immutableCache.get() { return value }
        let value = try await Task.detached(priority: .utility) {
            try computeImmutableAppIdentity()
        }.value
        return immutableCache.store(value)
        #else
        return "universal-scene-backend-unavailable"
        #endif
    }

    private static func computeImmutableAppIdentity() throws -> String {
        #if GW_UNIVERSAL_SCENE_BACKEND
        var digest = SHA256()
        feed("scene-lock-app-v2", into: &digest)
        let appRoot = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL

        let framework = appRoot.appendingPathComponent(
            "Contents/Frameworks/OpenWallpaperEngine.framework", isDirectory: true)
        guard FileManager.default.fileExists(atPath: framework.path) else {
            throw RenderedLockScreenVideoFailure(message: "缺少 Scene 渲染引擎。")
        }
        let frameworkRoot = framework.resolvingSymlinksInPath().standardizedFileURL
        guard isInsideOrEqual(frameworkRoot, root: appRoot) else {
            throw RenderedLockScreenVideoFailure(message: "Scene 渲染引擎路径不安全。")
        }
        feed("OpenWallpaperEngine.framework", into: &digest)
        try hashBundle(frameworkRoot, allowedRoot: frameworkRoot, into: &digest)

        let services = appRoot.appendingPathComponent("Contents/XPCServices", isDirectory: true)
        for name in SceneBackendServiceCatalog.bundleNames {
            feed(name, into: &digest)
            let bundle = services.appendingPathComponent(name, isDirectory: true)
            guard FileManager.default.fileExists(atPath: bundle.path) else {
                feed("missing", into: &digest)
                continue
            }
            let bundleRoot = bundle.resolvingSymlinksInPath().standardizedFileURL
            guard isInsideOrEqual(bundleRoot, root: appRoot) else {
                throw RenderedLockScreenVideoFailure(message: "Scene 辅助进程路径不安全。")
            }
            try hashBundle(bundleRoot, allowedRoot: bundleRoot, into: &digest)
        }
        return hex(digest)
        #else
        return "universal-scene-backend-unavailable"
        #endif
    }

    private static func registeredAssetsIdentity() throws -> String {
        var digest = SHA256()
        feed("official-assets-v2", into: &digest)
        if let assets = try SceneRuntimeAssetRegistry.loadRegisteredBundle() {
            feed("registered", into: &digest)
            feed(assets.manifestFingerprint, into: &digest)
            feed(String(assets.depotID), into: &digest)
            feed(String(assets.manifestID), into: &digest)
            for file in assets.files.sorted(by: { $0.logicalPath < $1.logicalPath }) {
                feed(file.logicalPath, into: &digest)
                feed(file.sha256, into: &digest)
                feed(String(file.sizeBytes), into: &digest)
            }
        } else {
            feed("unregistered", into: &digest)
        }
        return hex(digest)
    }

    private static func hashBundle(_ bundle: URL, allowedRoot: URL,
                                   into digest: inout SHA256) throws {
        let root = allowedRoot.resolvingSymlinksInPath().standardizedFileURL
        var visitedDirectories = Set<String>()
        var fileDigests: [String: String] = [:]
        var fileCount = 0

        func walk(_ url: URL, logicalPath: String, depth: Int) throws {
            try Task.checkCancellation()
            guard depth <= 32 else {
                throw RenderedLockScreenVideoFailure(message: "Scene 引擎包目录层级异常。")
            }
            let canonical = url.standardizedFileURL
                .resolvingSymlinksInPath().standardizedFileURL
            guard isInsideOrEqual(canonical, root: root) else {
                throw RenderedLockScreenVideoFailure(message: "Scene 引擎包包含越界链接。")
            }
            feed(logicalPath, into: &digest)
            feed(relativePath(canonical, root: root), into: &digest)
            let values = try canonical.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values.isDirectory == true {
                guard visitedDirectories.insert(canonical.path).inserted else { return }
                let children = try FileManager.default.contentsOfDirectory(
                    at: canonical, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                    options: [])
                for child in children.sorted(by: { $0.path < $1.path }) {
                    let name = child.lastPathComponent
                    try walk(child, logicalPath: logicalPath.isEmpty ? name : logicalPath + "/" + name,
                             depth: depth + 1)
                }
            } else if values.isRegularFile == true {
                fileCount += 1
                guard fileCount <= 4_096 else {
                    throw RenderedLockScreenVideoFailure(message: "Scene 引擎包文件数量异常。")
                }
                let hash: String
                if let cached = fileDigests[canonical.path] {
                    hash = cached
                } else {
                    hash = try fileDigest(canonical)
                    fileDigests[canonical.path] = hash
                }
                feed(hash, into: &digest)
            } else {
                throw RenderedLockScreenVideoFailure(message: "Scene 引擎包包含非普通文件。")
            }
        }
        try walk(bundle, logicalPath: "", depth: 0)
        guard fileCount > 0 else {
            throw RenderedLockScreenVideoFailure(message: "Scene 引擎包为空。")
        }
    }

    private static func feed(_ text: String, into digest: inout SHA256) {
        digest.update(data: Data(text.utf8))
        digest.update(data: Data([0]))
    }

    private static func hex(_ digest: SHA256) -> String {
        digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func relativePath(_ url: URL, root: URL) -> String {
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard url.path.hasPrefix(prefix) else { return "/" }
        return String(url.path.dropFirst(prefix.count))
    }

    private static func isInsideOrEqual(_ url: URL, root: URL) -> Bool {
        if url.path == root.path { return true }
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return url.path.hasPrefix(prefix)
    }

    private static func fileDigest(_ url: URL) throws -> String {
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            throw RenderedLockScreenVideoFailure(message: "无法读取 Scene 引擎文件。")
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_uid == getuid(), info.st_nlink == 1, info.st_size >= 0,
              info.st_size <= 536_870_912 else {
            throw RenderedLockScreenVideoFailure(message: "Scene 引擎文件节点不安全。")
        }
        var hash = SHA256(), buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            try Task.checkCancellation()
            let count = read(fd, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; throw POSIXError(.EIO) }
            if count == 0 { break }
            hash.update(data: buffer.prefix(count))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
