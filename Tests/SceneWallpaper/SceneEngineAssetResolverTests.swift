import Foundation
import Darwin
import CryptoKit
import CoreGraphics

private final class LoadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
@main struct SceneEngineAssetResolverTests {
    static func main() async throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp/gw-engine-receipt-\(UUID())", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        var checks: [String] = []
        func check(_ value: Bool, _ name: String) throws { guard value else { throw SceneWallpaperFailure(message: "FAILED: " + name) }; checks.append(name) }
        func rejects(_ name: String, _ body: () throws -> Void) throws {
            var failed = false; do { try body() } catch { failed = true }; try check(failed, name)
        }
        func mkdir(_ url: URL) throws {
            try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var current = url
            while current.path.hasPrefix(root.path) { try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: current.path); current.deleteLastPathComponent() }
        }
        func write(_ data: Data, _ url: URL) throws { try mkdir(url.deletingLastPathComponent()); try data.write(to: url); guard chmod(url.path, 0o600) == 0 else { throw SceneWallpaperFailure(message: "fixture chmod") } }
        func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
        func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        func u32(_ n: UInt32) -> Data { var x = n.littleEndian; return withUnsafeBytes(of: &x) { Data($0) } }
        var texture = Data("TEXV0005\0TEXI0001\0".utf8)
        for n: UInt32 in [0, 0, 1, 1, 1, 1, 0] { texture += u32(n) }
        texture += Data("TEXB0001\0".utf8)
        for n: UInt32 in [1, 1, 1, 1, 4] { texture += u32(n) }
        texture += Data([255, 100, 0, 255])
        let projectRoot = root.appendingPathComponent("own-project"), project = projectRoot.appendingPathComponent("project.json")
        try write(json(["type": "scene", "file": "scene.json"]), project)
        let general: [String: Any] = ["orthogonalprojection": ["width": 8, "height": 8], "bloom": false, "hdr": false, "cameraparallax": false, "camerashake": false]
        let scene: [String: Any] = ["general": general, "objects": [["id": 1, "image": "models/own.json", "size": "8 8", "origin": "4 4 0"]]]
        try write(json(scene), projectRoot.appendingPathComponent("scene.json"))
        try write(json(["material": "materials/own.json"]), projectRoot.appendingPathComponent("models/own.json"))
        let material: [String: Any] = ["passes": [["shader": "genericimage2", "blending": "translucent", "textures": ["particle/halo"]]]]
        try write(json(material), projectRoot.appendingPathComponent("materials/own.json"))
        let workshopTexture = projectRoot.appendingPathComponent("materials/particle/halo.tex")
        try write(texture, workshopTexture)
        let workspace = root.appendingPathComponent("workspace"), resolver = SceneEngineAssetResolver(workspaceURL: workspace)
        let complete = try SceneWallpaperInspector.inspect(projectURL: project)
        let baselinePixels = try SceneWallpaperRenderer.render(inspection: complete, pixelSize: .init(width: 8, height: 8)).dataProvider!.data! as Data
        let counter = LoadCounter()
        let fast = try resolver.resolve(projectURL: project, provider: { counter.add(); throw SceneWallpaperFailure(message: "must not consult cache") })
        try check(fast.inspection.isRenderableSubset && counter.value == 0, "complete Scene returns before invoking even a throwing cache provider")
        try check(try SceneWallpaperRenderer.render(inspection: fast.inspection, pixelSize: .init(width: 8, height: 8)).dataProvider!.data! as Data == baselinePixels, "complete Scene retains actual pixels without any engine dependency")
        try check(try resolver.loadBundle() == nil, "missing fixed workspace does not create a cache")
        try fm.removeItem(at: workshopTexture)
        let missing = try SceneWallpaperInspector.inspect(projectURL: project)
        try check(!missing.isRenderableSubset, "own missing engine-reference fixture blocks the pure inspector")
        let absent = try resolver.resolve(projectURL: project)
        try check(absent.inspection.diagnostics.map(\.message) == missing.diagnostics.map(\.message), "no receipt preserves original blocked diagnostics")
        let fingerprint = String(repeating: "a", count: 64)
        let content = workspace.appendingPathComponent("engine-assets/\(fingerprint)/content")
        let assets = content.appendingPathComponent("assets")
        var files: [SteamEngineAssetFile] = []
        for path in SceneEngineAssetResolver.requiredResources.sorted() {
            try write(texture, assets.appendingPathComponent(path))
            files.append(.init(logicalPath: path, relativePath: "assets/" + path, sha256: sha(texture), sizeBytes: UInt64(texture.count)))
        }
        let steam = SteamEngineAssetBundle(cacheRoot: content,
            manifestIdentity: .init(sha256: fingerprint, depotID: 431961, manifestID: 3687007859740550172), files: files)
        try resolver.registerVerifiedSteamBundle(steam)
        let receiptURL = workspace.appendingPathComponent("engine-assets/active-receipt.json")
        let originalReceipt = try Data(contentsOf: receiptURL)
        let bundle = try resolver.loadBundle()!
        try check(bundle.rootURL.path == assets.path && bundle.manifestIdentity == fingerprint && bundle.verifiedFiles.count == 7 && bundle.requiresPrivateRoot, "verified loose receipt derives content/assets root and retains all seven resource digests")
        let resolved = try resolver.resolve(projectURL: project)
        try check(resolved.inspection.isRenderableSubset && resolved.engineAssets?.manifestIdentity == fingerprint, "registered verified bundle unblocks actual missing texture dependency")
        try check(!SceneWallpaperInspector.inspect(projectURL: project).isRenderableSubset, "pure inspector never discovers the registered test cache")
        let wrapped = try SceneWallpaperInspector.inspectUsingAvailableEngineAssets(projectURL: project, resolver: resolver)
        try check(wrapped.isRenderableSubset, "production wrapper uses the same verified resource retry")
        try write(texture, workshopTexture)
        try write(Data("invalid receipt".utf8), receiptURL)
        let completeWithCorrupt = try resolver.resolve(projectURL: project)
        try check(completeWithCorrupt.inspection.isRenderableSubset, "corrupt registered receipt cannot break a complete workshop Scene")
        try fm.removeItem(at: workshopTexture)
        try check(try resolver.resolve(projectURL: project).inspection.diagnostics.map(\.message) == missing.diagnostics.map(\.message), "corrupt receipt preserves original missing-resource failure")
        try write(originalReceipt, receiptURL)
        var raw = try JSONSerialization.jsonObject(with: originalReceipt) as! [String: Any]
        func rejectReceipt(_ name: String, _ value: [String: Any]) throws {
            try write(json(value), receiptURL)
            try rejects(name) { _ = try resolver.loadBundle() }
            try check(!resolver.resolve(projectURL: project).inspection.isRenderableSubset, name + " remains blocked in production wrapper")
            try write(originalReceipt, receiptURL)
        }
        var bad = raw; bad["rootURL"] = "/etc"; try rejectReceipt("receipt cannot select an absolute external root", bad)
        bad = raw; bad["schemaVersion"] = 2; try rejectReceipt("unknown receipt version rejects", bad)
        bad = raw; bad["appID"] = 440; try rejectReceipt("receipt app authority is fixed to 431960", bad)
        var identity = raw["manifestIdentity"] as! [String: Any]
        identity["sha256"] = "../other"; bad = raw; bad["manifestIdentity"] = identity; try rejectReceipt("escaping manifest fingerprint rejects", bad)
        identity = raw["manifestIdentity"] as! [String: Any]; identity["manifestID"] = "03687007859740550172"; bad = raw; bad["manifestIdentity"] = identity; try rejectReceipt("noncanonical manifest decimal rejects", bad)
        var rawFiles = raw["files"] as! [[String: Any]]
        bad = raw; bad["files"] = rawFiles + [rawFiles[0]]; try rejectReceipt("duplicate logical resource rejects", bad)
        rawFiles[0]["logicalPath"] = "../outside.tex"; bad = raw; bad["files"] = rawFiles; try rejectReceipt("traversal logical resource rejects", bad)
        rawFiles = raw["files"] as! [[String: Any]]; rawFiles[0]["logicalPath"] = "materials/particle/HALO.tex"; bad = raw; bad["files"] = rawFiles; try rejectReceipt("case aliases outside the fixed allowlist reject", bad)
        rawFiles = raw["files"] as! [[String: Any]]; rawFiles[0]["sizeBytes"] = 64 * 1024 * 1024 + 1; bad = raw; bad["files"] = rawFiles; try rejectReceipt("oversized retained resource rejects before reading", bad)
        rawFiles = raw["files"] as! [[String: Any]]; rawFiles[0]["sha256"] = String(repeating: "F", count: 64); bad = raw; bad["files"] = rawFiles; try rejectReceipt("uppercase noncanonical digest rejects", bad)
        rawFiles = raw["files"] as! [[String: Any]]; rawFiles.removeLast(); bad = raw; bad["files"] = rawFiles; try rejectReceipt("incomplete seven-resource receipt rejects", bad)
        let halo = assets.appendingPathComponent("materials/particle/halo.tex")
        try write(Data(repeating: 0, count: texture.count), halo)
        try rejects("same-size modified resource fails SHA256") { _ = try resolver.loadBundle() }
        try check(!resolver.resolve(projectURL: project).inspection.isRenderableSubset, "modified resource cannot unblock production inspection")
        try write(texture, halo)
        try write(Data([1]), halo)
        try rejects("modified resource size rejects") { _ = try resolver.loadBundle() }
        try write(texture, halo)
        guard chmod(halo.path, 0o644) == 0 else { fatalError("chmod") }
        try rejects("nonprivate resource permissions reject") { _ = try resolver.loadBundle() }
        guard chmod(halo.path, 0o600) == 0 else { fatalError("chmod") }
        let hardlink = root.appendingPathComponent("second-link")
        try fm.linkItem(at: halo, to: hardlink)
        try rejects("hardlinked resource rejects") { _ = try resolver.loadBundle() }
        try fm.removeItem(at: hardlink)
        let outside = root.appendingPathComponent("outside.tex"); try write(texture, outside)
        try fm.removeItem(at: halo); try fm.createSymbolicLink(at: halo, withDestinationURL: outside)
        try rejects("resource leaf symlink rejects without following it") { _ = try resolver.loadBundle() }
        try fm.removeItem(at: halo); try write(texture, halo)
        try mkdir(workshopTexture.deletingLastPathComponent())
        try fm.createSymbolicLink(at:workshopTexture,withDestinationURL:outside)
        try check(!resolver.resolve(projectURL:project).inspection.isRenderableSubset,"unsafe workshop dependency cannot be bypassed by a valid engine fallback")
        try fm.removeItem(at:workshopTexture)
        let particles = assets.appendingPathComponent("materials/particle"), moved = root.appendingPathComponent("moved-particles")
        try fm.moveItem(at: particles, to: moved); try fm.createSymbolicLink(at: particles, withDestinationURL: moved)
        try rejects("resource ancestor symlink rejects") { _ = try resolver.loadBundle() }
        try fm.removeItem(at: particles); try fm.moveItem(at: moved, to: particles)
        try fm.removeItem(at: receiptURL); try fm.createSymbolicLink(at: receiptURL, withDestinationURL: outside)
        try rejects("active receipt symlink rejects") { _ = try resolver.loadBundle() }
        try fm.removeItem(at: receiptURL); try write(originalReceipt, receiptURL)
        let wrongRoot = SteamEngineAssetBundle(cacheRoot: root, manifestIdentity: steam.manifestIdentity, files: files)
        try rejects("broker adapter cannot register a content root outside its fixed manifest workspace") { try resolver.registerVerifiedSteamBundle(wrongRoot) }
        var wrongFiles = files; wrongFiles[0] = .init(logicalPath: files[0].logicalPath, relativePath: "elsewhere.tex", sha256: files[0].sha256, sizeBytes: files[0].sizeBytes)
        try rejects("broker adapter rejects mismatched logical/relative file mapping") { try resolver.registerVerifiedSteamBundle(.init(cacheRoot: content, manifestIdentity: steam.manifestIdentity, files: wrongFiles)) }
        try check(try Data(contentsOf: receiptURL) == originalReceipt, "rejected registrations preserve last valid active receipt")
        let hidden = workspace.appendingPathComponent("engine-assets/.active-receipt-staging")
        try fm.moveItem(at: receiptURL, to: hidden)
        try check(try resolver.loadBundle() == nil, "uncommitted staging files are never discovered")
        try fm.moveItem(at: hidden, to: receiptURL)
        var unknownMaterial = material; unknownMaterial["passes"] = [["shader": "custom-other", "textures": ["particle/halo"]]]
        try write(json(unknownMaterial), projectRoot.appendingPathComponent("materials/own.json"))
        try check(!resolver.resolve(projectURL: project).inspection.isRenderableSubset, "verified cache never clears unsupported shader validation")
        try write(json(material), projectRoot.appendingPathComponent("materials/own.json"))
        // Workshop resource must win, even if the engine cache has the same name.
        var green = texture; green.replaceSubrange((green.count - 4)..<green.count, with: [0, 255, 0, 255])
        try write(green, workshopTexture)
        let precedence = try resolver.resolve(projectURL: project)
        try check(precedence.inspection.textures["materials/particle/halo.tex"]?.data == Data([0, 255, 0, 255]) && precedence.engineAssets == nil, "complete workshop resource wins over registered engine resource")
        try fm.removeItem(at: workshopTexture)
        let cancellation = Task.detached { () throws -> Bool in
            while !Task.isCancelled { await Task.yield() }
            do { _ = try resolver.resolve(projectURL: project); return false } catch is CancellationError { return true }
        }
        cancellation.cancel()
        try check(try await cancellation.value, "resource retry propagates task cancellation")
        raw.removeAll()
        let report: [String: Any] = ["success": true, "checkCount": checks.count, "checks": checks, "temporaryOwnedWorkspaceOnly": true, "actualSteamAssets": false, "desktopApplied": false]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        if let destination = CommandLine.arguments.dropFirst().first { try data.write(to: URL(fileURLWithPath: destination)) }
        print(String(decoding: data, as: UTF8.self))
    }
}
