import Foundation
import CryptoKit
import Darwin

private struct RegistryTestFailure: Error { let message: String }

@main enum SceneRuntimeAssetRegistryTests {
    static func main() async throws {
        let manager = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp/gw-scene-runtime-registry-\(UUID())", isDirectory: true)
        defer { try? manager.removeItem(at: root) }
        var checks = [String]()
        func check(_ condition: Bool, _ name: String) throws {
            guard condition else { throw RegistryTestFailure(message: name) }
            checks.append(name); print("PASS \(name)")
        }
        func rejects(_ name: String, _ operation: () throws -> Void) throws {
            do { try operation(); throw RegistryTestFailure(message: name) }
            catch is RegistryTestFailure { throw RegistryTestFailure(message: name) }
            catch { checks.append(name); print("PASS \(name)") }
        }
        func rejectsRegistry(_ expected: SceneRuntimeAssetRegistryError, _ name: String,
                             _ operation: () throws -> Void) throws {
            do { try operation(); throw RegistryTestFailure(message: name) }
            catch let error as SceneRuntimeAssetRegistryError where error == expected {
                checks.append(name); print("PASS \(name)")
            } catch { throw RegistryTestFailure(message: name) }
        }
        func mkdir(_ url: URL) throws {
            try manager.createDirectory(at: url, withIntermediateDirectories: true)
            var current = url
            while current.path.hasPrefix(root.path) {
                try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: current.path)
                current.deleteLastPathComponent()
            }
        }
        func write(_ data: Data, to url: URL) throws {
            try mkdir(url.deletingLastPathComponent()); try data.write(to: url)
            guard chmod(url.path, 0o600) == 0 else { throw RegistryTestFailure(message: "chmod") }
        }
        func digest(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }

        try mkdir(root)
        let appRoot = root.appendingPathComponent("Application Support/Glimmer", isDirectory: true)
        let workspace = appRoot.appendingPathComponent("Workshop/SteamContent", isDirectory: true)
        let registryURL = appRoot.appendingPathComponent("SceneBackend", isDirectory: true)
        try mkdir(workspace)
        let registry = SceneRuntimeAssetRegistry(contentWorkspaceURL: workspace, registryURL: registryURL)
        try check(try registry.loadRegisteredBundle() == nil && !registry.isAvailable,
                  "missing registry is unavailable without creating state")
        try check(!manager.fileExists(atPath: registryURL.path), "availability check is read-only")

        let fingerprint = String(repeating: "a", count: 64)
        let content = workspace.appendingPathComponent("scene-runtime-assets/\(fingerprint)/content", isDirectory: true)
        let assets = content.appendingPathComponent("assets", isDirectory: true)
        var files = [SteamEngineAssetFile]()
        for index in 0..<2935 {
            let path = String(format: "materials/group%02d/resource%04d.bin", index % 37, index)
            let data = Data("runtime-asset-\(index)".utf8)
            try write(data, to: assets.appendingPathComponent(path))
            files.append(.init(logicalPath: path, relativePath: "assets/" + path,
                               sha256: digest(data), sizeBytes: UInt64(data.count)))
        }
        let identity = SteamEngineAssetManifestIdentity(sha256: fingerprint, depotID: 431961,
                                                         manifestID: 3687007859740550172)
        let bundle = SteamSceneRuntimeAssetBundle(cacheRoot: content, manifestIdentity: identity, files: files)
        guard chmod(appRoot.path, 0o755) == 0 else { throw RegistryTestFailure(message: "app root chmod") }
        try registry.registerVerifiedSteamBundle(bundle)
        let receiptURL = registryURL.appendingPathComponent("active-receipt.json")
        let receipt = try Data(contentsOf: receiptURL)
        let loaded = try registry.loadRegisteredBundle()
        try check(loaded?.assetsRootURL.path == assets.path && loaded?.files.count == 2935 &&
                  loaded?.manifestFingerprint == fingerprint && loaded?.verifiedFiles.count == 2935,
                  "realistic 2935-file receipt survives registration and a fresh full verification")
        try check(receipt.count < 2 * 1024 * 1024, "full receipt stays inside its two MiB bound")
        var receiptInfo = stat(); guard lstat(receiptURL.path, &receiptInfo) == 0 else { throw RegistryTestFailure(message: "receipt stat") }
        try check(receiptInfo.st_mode & S_IFMT == S_IFREG && receiptInfo.st_nlink == 1 && receiptInfo.st_mode & 0o077 == 0,
                  "active receipt is a private single-link regular file")
        let raw = try JSONSerialization.jsonObject(with: receipt) as! [String: Any]
        try check(Set(raw.keys) == ["schemaVersion", "appID", "manifestIdentity", "files"] && raw["rootURL"] == nil,
                  "receipt schema carries identity and files but no filesystem authority")
        var appRootInfo = stat()
        try check(lstat(appRoot.path, &appRootInfo) == 0 && appRootInfo.st_mode & 0o777 == 0o755,
                  "an owner-controlled non-writable legacy app root can host the new private registry")

        let target = assets.appendingPathComponent(files[17].logicalPath)
        let original = try Data(contentsOf: target)
        try write(Data(repeating: 7, count: original.count), to: target)
        try rejectsRegistry(.contentVerificationFailed,
            "same-size content tampering fails SHA256 verification with a stable content error") {
            _ = try registry.loadRegisteredBundle()
        }
        try write(original, to: target)
        let extra = assets.appendingPathComponent("materials/unlisted.bin")
        try write(Data([1]), to: extra)
        try rejects("unlisted content in the controlled tree rejects") { _ = try registry.loadRegisteredBundle() }
        try manager.removeItem(at: extra)
        guard chmod(target.path, 0o644) == 0 else { throw RegistryTestFailure(message: "chmod") }
        try rejects("nonprivate asset permissions reject") { _ = try registry.loadRegisteredBundle() }
        guard chmod(target.path, 0o600) == 0 else { throw RegistryTestFailure(message: "chmod") }
        let secondLink = root.appendingPathComponent("hardlink")
        try manager.linkItem(at: target, to: secondLink)
        try rejects("hardlinked asset rejects") { _ = try registry.loadRegisteredBundle() }
        try manager.removeItem(at: secondLink)
        let outside = root.appendingPathComponent("outside"); try write(original, to: outside)
        try manager.removeItem(at: target); try manager.createSymbolicLink(at: target, withDestinationURL: outside)
        try rejects("asset symlink rejects without reading its target") { _ = try registry.loadRegisteredBundle() }
        try manager.removeItem(at: target); try write(original, to: target)

        let originalReceipt = try Data(contentsOf: receiptURL)
        var unknown = raw; unknown["cacheRoot"] = "/tmp/external"
        try write(try JSONSerialization.data(withJSONObject: unknown), to: receiptURL)
        try rejectsRegistry(.invalidReceipt, "unknown receipt authority key rejects with a stable receipt error") {
            _ = try registry.loadRegisteredBundle()
        }
        let baseIdentity = raw["manifestIdentity"]!
        let sampleSHA = files[0].sha256
        let overflowFiles: [[String: Any]] = (0...4096).map {
            ["logicalPath": String(format: "overflow/file%04d.bin", $0), "sha256": sampleSHA, "sizeBytes": 1]
        }
        let overflow: [String: Any] = ["schemaVersion": 1, "appID": 431960,
                                       "manifestIdentity": baseIdentity, "files": overflowFiles]
        try write(try JSONSerialization.data(withJSONObject: overflow), to: receiptURL)
        try rejects("more than 4096 manifest files reject before filesystem traversal") { _ = try registry.loadRegisteredBundle() }
        let excessiveTotal: [[String: Any]] = (0..<9).map {
            ["logicalPath": "oversize/file\($0).bin", "sha256": sampleSHA, "sizeBytes": 16 * 1024 * 1024]
        }
        var totalReceipt = overflow; totalReceipt["files"] = excessiveTotal
        try write(try JSONSerialization.data(withJSONObject: totalReceipt), to: receiptURL)
        try rejects("more than 128 MiB declared content rejects before filesystem traversal") { _ = try registry.loadRegisteredBundle() }
        var largeFile = excessiveTotal; largeFile[0]["sizeBytes"] = 16 * 1024 * 1024 + 1
        totalReceipt["files"] = largeFile
        try write(try JSONSerialization.data(withJSONObject: totalReceipt), to: receiptURL)
        try rejects("a file larger than 16 MiB rejects before filesystem traversal") { _ = try registry.loadRegisteredBundle() }
        try write(Data(repeating: 0x20, count: 2 * 1024 * 1024 + 1), to: receiptURL)
        try rejects("receipt larger than two MiB rejects before JSON decoding") { _ = try registry.loadRegisteredBundle() }
        try write(originalReceipt, to: receiptURL)
        try manager.removeItem(at: receiptURL); guard mkfifo(receiptURL.path, 0o600) == 0 else { throw RegistryTestFailure(message: "mkfifo") }
        try rejects("FIFO receipt rejects without blocking") { _ = try registry.loadRegisteredBundle() }
        try manager.removeItem(at: receiptURL); try write(originalReceipt, to: receiptURL)

        let wrong = SteamSceneRuntimeAssetBundle(cacheRoot: root, manifestIdentity: identity, files: files)
        try rejectsRegistry(.invalidBundle, "bundle cannot select a root outside the fixed manifest workspace") {
            try registry.registerVerifiedSteamBundle(wrong)
        }
        try check(try Data(contentsOf: receiptURL) == originalReceipt,
                  "failed registration preserves the prior active receipt")
        var wrongFiles = files
        wrongFiles[0] = .init(logicalPath: files[0].logicalPath, relativePath: "../outside",
                              sha256: files[0].sha256, sizeBytes: files[0].sizeBytes)
        try rejects("relative mappings must exactly match assets plus logical path") {
            try registry.registerVerifiedSteamBundle(.init(cacheRoot: content, manifestIdentity: identity, files: wrongFiles))
        }

        let secondRoot = root.appendingPathComponent("second/Application Support/Glimmer", isDirectory: true)
        try mkdir(secondRoot)
        let externalRegistry = root.appendingPathComponent("external-registry", isDirectory: true); try mkdir(externalRegistry)
        try manager.createSymbolicLink(at: secondRoot.appendingPathComponent("SceneBackend"), withDestinationURL: externalRegistry)
        let secondRegistry = SceneRuntimeAssetRegistry(contentWorkspaceURL: workspace,
                                                        registryURL: secondRoot.appendingPathComponent("SceneBackend"))
        try rejects("registry directory symlink is never followed for publication") {
            try secondRegistry.registerVerifiedSteamBundle(bundle)
        }
        try check(try manager.contentsOfDirectory(atPath: externalRegistry.path).isEmpty,
                  "rejected registry symlink leaves its target untouched")

        let unsafeRoot = root.appendingPathComponent("unsafe/Application Support/Glimmer", isDirectory: true)
        try mkdir(unsafeRoot)
        guard chmod(unsafeRoot.path, 0o775) == 0 else { throw RegistryTestFailure(message: "unsafe chmod") }
        let unsafeRegistry = SceneRuntimeAssetRegistry(contentWorkspaceURL: workspace,
                                                        registryURL: unsafeRoot.appendingPathComponent("SceneBackend"))
        do {
            try unsafeRegistry.registerVerifiedSteamBundle(bundle)
            throw RegistryTestFailure(message: "writable registry parent accepted")
        } catch SceneRuntimeAssetRegistryError.unsafeRegistry {
            checks.append("group-writable registry parent rejects with a stable safe error code")
            print("PASS group-writable registry parent rejects with a stable safe error code")
        } catch is RegistryTestFailure {
            throw RegistryTestFailure(message: "writable registry parent accepted")
        }

        let report: [String: Any] = ["success": true, "checkCount": checks.count, "checks": checks,
                                     "fixtureFileCount": 2935, "temporaryOwnedWorkspaceOnly": true,
                                     "actualSteamCacheRead": false, "credentialsRead": false]
        let reportData = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        if let destination = CommandLine.arguments.dropFirst().first {
            try reportData.write(to: URL(fileURLWithPath: destination), options: .atomic)
        }
        print(String(decoding: reportData, as: UTF8.self))
    }
}
