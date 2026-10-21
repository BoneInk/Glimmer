import AppKit
import CryptoKit
import Darwin

@MainActor private final class SceneExportPreferencesState {
    var value = LockScreenExportConfiguration(settings: .init(syncWallpaperSettings: false,
        resolution: .uhd2160, framesPerSecond: 120, projectPlayback: .recorded), wallpaperWidth: 1920, wallpaperHeight: 1080, wallpaperFPS: 60)
}

@main @MainActor
enum SceneConfiguredLockScreenExportTests {
    struct Failure: Error { let message: String }
    static func check(_ value: Bool, _ name: String) throws {
        guard value else { throw Failure(message: name) }
        print("PASS \(name)"); fflush(stdout)
    }
    static func run() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true).resolvingSymlinksInPath()
            .appendingPathComponent("GW-Configured-Scene-Export-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        #if GW_UI_REVIEW
        guard let profile = ProcessInfo.processInfo.environment["GW_SCENE_EXPORT_ASSET_PROFILE"] else {
            throw Failure(message: "provide an existing verified Scene asset profile for this isolated test")
        }
        let sourceRoot = URL(fileURLWithPath: profile)
        let receipt = try Data(contentsOf: sourceRoot.appendingPathComponent("SceneBackend/active-receipt.json"))
        let json = try JSONSerialization.jsonObject(with: receipt) as? [String: Any]
        guard let identity = json?["manifestIdentity"] as? [String: Any],
              let hash = identity["sha256"] as? String, hash.count == 64, hash.allSatisfy(\.isHexDigit) else {
            throw Failure(message: "invalid runtime asset receipt")
        }
        let receiptRoot = root.appendingPathComponent("SceneBackend")
        let contentParent = root.appendingPathComponent("Workshop/SteamContent/scene-runtime-assets/\(hash)")
        try FileManager.default.createDirectory(at: receiptRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: contentParent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try receipt.write(to: receiptRoot.appendingPathComponent("active-receipt.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receiptRoot.appendingPathComponent("active-receipt.json").path)
        try FileManager.default.copyItem(at: sourceRoot.appendingPathComponent("Workshop/SteamContent/scene-runtime-assets/\(hash)/content"),
                                         to: contentParent.appendingPathComponent("content"))
        setenv("GW_UI_REVIEW_ROOT", root.path, 1)
        print("Scene isolated registry: \(SceneRuntimeAssetRegistry.production.registryURL.path)")
        try check(try SceneRuntimeAssetRegistry.production.loadRegisteredBundle() != nil,
                  "Scene test uses an independently verified asset copy without changing the original profile")
        #endif
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        let project = root.appendingPathComponent("Scene")
        try FileManager.default.copyItem(at: fixture, to: project)
        let item = WallpaperItem(title: "Configured Scene export", filePath: project.appendingPathComponent("project.json").path,
                                 contentKind: .scene)
        let storage = AppStorage(root: root.appendingPathComponent("App"))
        let state = SceneExportPreferencesState()
        let coordinator = ExperimentalLockScreenCoordinator(storage: storage, environment: .review(storage: storage),
            exportConfiguration: { _ in state.value })
        await coordinator.prepare(item: item)
        guard let first = coordinator.preparedAsset else { throw Failure(message: coordinator.lastError ?? "no Scene video") }
        let initialProbe = try await VideoProbe.probe(url: first.videoURL)
        try check(initialProbe.pixelWidth == 960 && initialProbe.pixelHeight == 600
            && abs((initialProbe.frameRate ?? 0) - 60) < 0.01,
            "real Scene output clamps 4K/120 request to its 960x600 canvas and 60 FPS runtime cap")
        state.value.settings.syncWallpaperSettings = true
        state.value.wallpaperWidth = 480; state.value.wallpaperHeight = 300; state.value.wallpaperFPS = 12
        await coordinator.prepare(item: item)
        guard let second = coordinator.preparedAsset else { throw Failure(message: coordinator.lastError ?? "no synchronized Scene video") }
        let probe = try await VideoProbe.probe(url: second.videoURL)
        try check(first.videoURL == second.videoURL && first.id != second.id
            && probe.pixelWidth == 480 && probe.pixelHeight == 300 && abs((probe.frameRate ?? 0) - 12) < 0.01,
            "real Scene synchronization replaces the previous video with 480x300 at 12 FPS")
        let cacheRoot = storage.root.appendingPathComponent("ExperimentalLockScreen/SceneVideoCache")
            .appendingPathComponent(item.id.uuidString)
        let entries = try FileManager.default.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.count == 64 }
        try check(entries.count == 1, "Scene replacement removes its older export cache")
        try check(!FileManager.default.fileExists(atPath: ExperimentalLockScreenEnvironment.review(storage: storage).storeDirectory.path),
                  "real Scene export does not submit system lock-screen settings")
        print("RESULT real Scene configuration checks passed; temporary copied fixture, verified assets and review storage only")
    }
    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await run(); fflush(stdout); Darwin.exit(0) }
            catch { fputs("FAIL \(error)\n", stderr); fflush(stderr); Darwin.exit(1) }
        }
        NSApplication.shared.run()
    }
}
