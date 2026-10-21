import Foundation
import CryptoKit
import Darwin

public enum SceneBackendFailure: String, Error { case invalidConfiguration, invalidRoot, digestMismatch, alreadyConfigured, notReady, unsupported, closed, stale, gpuFailure, timeout }

/// A backend failure with structured, bounded context. The helper turns it into a wire NSError
/// that keeps the stable `scene_backend_<code>` string while carrying a concise user message and
/// a local technical detail, so a missing resource is never reported as an unsupported scene.
public struct SceneBackendDetailedFailure: Error {
    public let failure: SceneBackendFailure
    public let detail: SceneBackendFailureDetail
    public init(failure: SceneBackendFailure, detail: SceneBackendFailureDetail) {
        self.failure = failure
        self.detail = detail
    }
}

/// Installed once per helper process, before upstream state can initialize. No environment or
/// app-defaults fallback is used by the public backend entrypoint.
public final class SceneBackendRuntimeContext: @unchecked Sendable {
    private static let lock = NSRecursiveLock()
    nonisolated(unsafe) private static var installed: SceneBackendRuntimeContext?
    static var current: SceneBackendRuntimeContext? { lock.withLock { installed } }
    static var isActive: Bool { current != nil }
    let roots: SceneBackendRoots
    let preferences = ResearchMemoryDefaults()
    private let diagnosticsLock = NSLock()
    private var errors: [String] = []
    private var errorSerial: UInt64 = 0
    static func install(_ roots: SceneBackendRoots) throws -> SceneBackendRuntimeContext {
        try lock.withLock {
            guard installed == nil else { throw SceneBackendFailure.alreadyConfigured }
            func canonicalDirectory(_ url: URL) throws -> URL {
                guard url.isFileURL, let path = ContainedPath.canonical(url) else { throw SceneBackendFailure.invalidRoot }
                var directory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue else { throw SceneBackendFailure.invalidRoot }
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            let project = try canonicalDirectory(roots.projectRoot), assets = try canonicalDirectory(roots.assetsRoot)
            // Caller grants this private write root; refuse symlinked ancestors and overlap with inputs.
            let cache = roots.cacheRoot.standardizedFileURL
            guard cache.isFileURL, cache.path.hasPrefix("/"),
                  ContainedPath.hasNoLinks(below: URL(fileURLWithPath: "/"), relativePath: String(cache.path.dropFirst())),
                  !ContainedPath.isInside(cache.path, root: project.path), !ContainedPath.isInside(cache.path, root: assets.path),
                  !ContainedPath.isInside(project.path, root: cache.path), !ContainedPath.isInside(assets.path, root: cache.path)
            else { throw SceneBackendFailure.invalidRoot }
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // Existing writable cache descendants must never redirect shader/storage writes.
            var rootInfo = stat()
            guard lstat(cache.path, &rootInfo) == 0, (rootInfo.st_mode & S_IFMT) == S_IFDIR,
                  rootInfo.st_uid == geteuid(), (rootInfo.st_mode & 0o077) == 0 else { throw SceneBackendFailure.invalidRoot }
            var cacheEnumerationFailed = false
            guard let files = FileManager.default.enumerator(at: cache, includingPropertiesForKeys: nil,
                errorHandler: { _, _ in cacheEnumerationFailed = true; return false }) else { throw SceneBackendFailure.invalidRoot }
            do {
                var count = 0
                for case let file as URL in files {
                    count += 1
                    var info = stat()
                    guard count <= 100_000, lstat(file.path, &info) == 0, info.st_uid == geteuid(),
                          (info.st_mode & 0o022) == 0,
                          (info.st_mode & S_IFMT) == S_IFDIR || ((info.st_mode & S_IFMT) == S_IFREG && info.st_nlink == 1)
                    else { throw SceneBackendFailure.invalidRoot }
                }
            }
            guard !cacheEnumerationFailed else { throw SceneBackendFailure.invalidRoot }
            guard let data = try AssetPathResolver.data("project.json", in: project),
                  Digest.hex(SHA256.hash(data: data)) == roots.projectDigest,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (object["type"] as? String)?.lowercased() == "scene",
                  let entry = object["file"] as? String, AssetPathResolver.sanitize(entry) == entry,
                  WallpaperEngineAssets.isAssetTree(assets),
                  AssetPathResolver.fileURL("scripts/jsclasses/baseclasses.js", in: assets) != nil,
                  roots.assetsManifestDigest.count == 64,
                  roots.assetsManifestDigest.allSatisfy({ $0.isHexDigit })
            else { throw SceneBackendFailure.digestMismatch }
            let value = SceneBackendRuntimeContext(roots: SceneBackendRoots(projectRoot: project, assetsRoot: assets, cacheRoot: cache,
                projectDigest: roots.projectDigest, assetsManifestDigest: roots.assetsManifestDigest))
            installed = value
            return value
        }
    }
    private init(roots: SceneBackendRoots) { self.roots = roots }
    func recordError(_ text: String) { diagnosticsLock.withLock { errorSerial &+= 1; if errors.count < 512 { errors.append(text) } } }
    var errorRevision: UInt64 { diagnosticsLock.withLock { errorSerial } }
    func errorSnapshot() -> [String] { diagnosticsLock.withLock { errors } }
    func clearErrors() { diagnosticsLock.withLock { errors.removeAll() } }
    var temporaryDirectory: URL { roots.cacheRoot.appending(path: "temporary", directoryHint: .isDirectory) }
}
