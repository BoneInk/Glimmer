import AppKit
import Darwin

@main @MainActor
enum LiveLockScreenPreparationTests {
    struct Failure: Error { let message: String }
    static func check(_ value: Bool, _ name: String) throws {
        guard value else { throw Failure(message: name) }
        print("PASS \(name)"); fflush(stdout)
    }
    static func run() async throws {
        let fm = FileManager.default
        let fixtures = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
        let prefix = "/Users/Shared/GlimmerNativeLockScreen/\(getuid())/isolated-live-"
        guard fixtures.path.hasPrefix(prefix), fixtures.deletingLastPathComponent().path == "/Users/Shared/GlimmerNativeLockScreen/\(getuid())" else {
            throw Failure(message: "Use the isolated live probe fixture directory only")
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[2]).resolvingSymlinksInPath().appendingPathComponent("GW-Live-Preparation-\(UUID())")
        try LockScreenOwnedFiles.makePrivateDirectory(root)
        defer { try? fm.removeItem(at: root) }
        guard let profile = ProcessInfo.processInfo.environment["GW_SCENE_EXPORT_ASSET_PROFILE"] else { throw Failure(message: "Missing verified asset profile") }
        let original = URL(fileURLWithPath: profile)
        let receipt = try Data(contentsOf: original.appendingPathComponent("SceneBackend/active-receipt.json"))
        let json = try JSONSerialization.jsonObject(with: receipt) as? [String: Any]
        guard let identity = json?["manifestIdentity"] as? [String: Any], let hash = identity["sha256"] as? String,
              LiveWallpaperRecipe.digest(hash) else { throw Failure(message: "Invalid asset receipt") }
        try LockScreenOwnedFiles.makePrivateDirectory(root.appendingPathComponent("SceneBackend"))
        try LockScreenOwnedFiles.privateWrite(receipt, to: root.appendingPathComponent("SceneBackend/active-receipt.json"))
        let content = "Workshop/SteamContent/scene-runtime-assets/\(hash)/content"
        try LockScreenOwnedFiles.makePrivateDirectory(root.appendingPathComponent(content).deletingLastPathComponent())
        try fm.copyItem(at: original.appendingPathComponent(content), to: root.appendingPathComponent(content))
        setenv("GW_UI_REVIEW_ROOT", root.path, 1)

        for kind in ["scene", "web"] {
            let sourceConfig = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtures.appendingPathComponent(kind + "/config.json"))) as! [String: Any]
            let liveName = sourceConfig["liveDirectoryName"] as! String
            let project = root.appendingPathComponent(kind + "-source")
            try fm.copyItem(at: fixtures.appendingPathComponent(kind + "/" + liveName + "/project"), to: project)
            let item = WallpaperItem(title: "Live integration \(kind)", filePath: project.appendingPathComponent("project.json").path,
                                     contentKind: kind == "scene" ? .scene : .web)
            let storage = AppStorage(root: root.appendingPathComponent(kind))
            let shared = fixtures.appendingPathComponent("prepared-" + kind)
            let review = ExperimentalLockScreenEnvironment.review(storage: storage)
            let environment = ExperimentalLockScreenEnvironment(storeDirectory: review.storeDirectory, sharedDirectory: shared,
                legacySharedDirectory: nil, extensionURL: nil, isReview: true)
            var configuration = LockScreenExportConfiguration(settings: .init(allowWebHTTPS: kind == "web"),
                wallpaperWidth: 640, wallpaperHeight: 400, wallpaperFPS: 12)
            // Capture mutable settings in a main-actor box used by the production entry point.
            let preferences = Preferences(configuration)
            let coordinator = ExperimentalLockScreenCoordinator(storage: storage, environment: environment, exportConfiguration: { _ in preferences.value })
            await coordinator.prepare(item: item)
            guard let first = coordinator.preparedAsset, let recipe = first.liveRecipe else { throw Failure(message: coordinator.lastError ?? "No live recipe") }
            try check(recipe.width <= 640 && recipe.height <= 400 && recipe.fps == 12, "\(kind) live settings respect desktop and source limits")
            try check(!fm.fileExists(atPath: shared.appendingPathComponent("config.json").path), "\(kind) preparation does not submit system settings")
            await coordinator.applyPrepared()
            try check(coordinator.state == .applied && coordinator.lastError == nil, "\(kind) production coordinator stages and submits a review transaction")
            let submitted = try JSONSerialization.jsonObject(with: Data(contentsOf: shared.appendingPathComponent("config.json"))) as! [String: Any]
            let staged = shared.appendingPathComponent(submitted["liveDirectoryName"] as! String)
            try check(submitted["schemaVersion"] as? Int == 2 && LiveWallpaperBundle.load(staged) == recipe,
                      "\(kind) extension receives an exact private checksummed project and author settings")
            configuration.wallpaperWidth = 320; configuration.wallpaperHeight = 200
            preferences.value = configuration
            await coordinator.prepare(item: item)
            guard let second = coordinator.preparedAsset, let replacement = second.liveRecipe else { throw Failure(message: coordinator.lastError ?? "No replacement") }
            try check(first.videoURL == second.videoURL && first.id != second.id && replacement.width <= 320 && replacement.height <= 200,
                      "\(kind) re-preparation replaces the same per-item asset with changed settings")
            try check(try LiveWallpaperBundle.load(staged) == recipe, "\(kind) active staged revision survives preparation of the next revision")
            // Leave the first submitted project in this explicitly isolated shared
            // subtree for the separately signed extension sandbox probe.
            await coordinator.restorePrevious()
            try check(coordinator.state == .restored, "\(kind) review transaction can restore the previous provider")
            try LockScreenOwnedFiles.privateWrite(try JSONSerialization.data(withJSONObject: submitted), to: shared.appendingPathComponent("config.json"))
        }
        print("RESULT live preparation, replacement, private staging and rollback checks passed; no actual system store changed")
    }
    @MainActor final class Preferences {
        var value: LockScreenExportConfiguration
        init(_ value: LockScreenExportConfiguration) { self.value = value }
    }
    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await run(); fflush(stdout); exit(0) }
            catch { fputs("FAIL \(error)\n", stderr); fflush(stderr); exit(1) }
        }
        NSApplication.shared.run()
    }
}
