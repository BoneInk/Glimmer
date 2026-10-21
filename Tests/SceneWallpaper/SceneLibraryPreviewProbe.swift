import AppKit
import Foundation

@main
@MainActor
enum SceneLibraryPreviewProbe {
    static func main() async {
        var checks: [String] = []
        func check(_ condition: Bool, _ name: String) throws {
            guard condition else { throw SceneWallpaperFailure(message: "FAILED: " + name) }
            checks.append(name)
        }
        func pixel(_ image: CGImage) -> [Int] {
            let center = image.cropping(to: CGRect(x: image.width / 2, y: image.height / 2, width: 1, height: 1))!
            var bytes = [UInt8](repeating: 0, count: 4)
            let context = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(center, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return bytes.map(Int.init)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SceneLibraryPreview-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var failure: String?
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let storage = AppStorage(root: directory.appendingPathComponent("library"))
            let store = VideoLibraryStore(storage: storage)
            let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
            let item = try await SceneWallpaperProjectImporter.importProject(fixture, store: store)
            try check(item.isSceneWallpaper && item.isProjectWallpaper && !item.isVideoWallpaper, "Scene record cannot enter video-only paths")
            try check(item.pixelWidth == 960 && item.pixelHeight == 600 && item.durationSeconds == nil, "actual canvas dimensions without synthesized video duration")
            let model = SceneWallpaperPreviewModel()
            await model.update(item: item, paused: false, storage: storage)
            guard let runtime = model.runtime, let image = runtime.posterImage else {
                throw SceneWallpaperFailure(message: model.error ?? "No actual Scene preview image")
            }
            try check(runtime.state == .ready && model.error == nil, "real Scene preview model reaches ready")
            try check(model.controlsState.phase == .ready && model.controlsState.canTogglePause, "pause availability comes from this real ready preview")
            let initial = pixel(image)
            try check(initial[0] > 240 && initial[1] > 95 && initial[1] < 140, "preview contains original orange geometry pixels")
            guard let project = try AuthorPropertyServices.project(for: item) else { throw SceneWallpaperFailure(message: "Missing author schema") }
            let keys = AuthorPropertyServices.shared.editableKeys(project: project, itemID: item.id)
            try check(keys == ["showgeometry", "geometryopacity", "geometrycolor"], "author UI enables only actual bound bool/slider/color keys")
            try check(AuthorPropertyServices.shared.readySceneHosts(itemID: item.id).contains { $0 === runtime }, "preview is registered as a real ready ACK target")
            let overrides = AuthorPropertyServices.shared.store(storage: storage)
            var actualACKCount = 0
            let settings = AuthorPropertySettingsSession(project: project, overrideStore: overrides, itemID: item.id,
                capabilities: .init(editableKeys: keys, runtimeLabel: "Scene", unsupportedReason: ""),
                coalescingDelay: .zero) { _ in
                    try await AuthorPropertyServices.shared.applySavedSettings(project: project, itemID: item.id, storage: storage)
                    actualACKCount += 1
                }
            await settings.load()
            settings.set(.string("0 1 1"), for: project.definition(for: "geometrycolor")!)
            await settings.waitUntilIdle()
            let cyan = pixel(runtime.posterImage!)
            try check(actualACKCount == 1 && !settings.savedButNotApplied && cyan[0] < 10 && cyan[1] > 240 && cyan[2] > 240,
                      "native author settings color waits for actual rendered cyan ACK")
            try check(AuthorPropertySettingsSummary(session: settings).modifiedCount == 1,
                      "collapsed author summary reflects the actual acknowledged edit")
            settings.set(.number(0), for: project.definition(for: "geometryopacity")!)
            await settings.waitUntilIdle()
            let zero = pixel(runtime.posterImage!)
            try check(actualACKCount == 2 && zero[0] < 70 && zero[1] < 100 && zero[2] < 130,
                      "native author slider waits for actual layer compositing ACK")
            settings.set(.number(1), for: project.definition(for: "geometryopacity")!)
            await settings.waitUntilIdle()
            settings.set(.bool(false), for: project.definition(for: "showgeometry")!)
            await settings.waitUntilIdle()
            try check(actualACKCount == 4 && pixel(runtime.posterImage!) == zero,
                      "native author visibility waits for actual geometry removal ACK")
            model.setPaused(true)
            try check(runtime.state == .paused, "preview pause reaches Scene runtime without a player")
            try check(model.controlsState.phase == .paused && model.controlsState.canTogglePause, "actual paused preview can resume")
            model.dispose()
            try check(runtime.state == .disposed && model.runtime == nil, "close disposes real host and view model")
            try check(!model.controlsState.canTogglePause, "disposed preview cannot expose usable pause controls")
            try check(AuthorPropertyServices.shared.readySceneHosts(itemID: item.id).isEmpty, "close unregisters author ACK target")
            await model.retry(item: item, paused: false, storage: storage)
            try check(model.runtime == nil, "queued reload cannot resurrect closed preview")
            model.activate()
            let pending = Task { await model.update(item: item, paused: false, storage: storage) }
            await Task.yield()
            model.dispose()
            await pending.value
            try check(model.runtime == nil && AuthorPropertyServices.shared.readySceneHosts(itemID: item.id).isEmpty,
                      "close during async startup rejects stale host publication")
            model.activate()
            await model.update(item: item, paused: true, storage: storage)
            try check(model.runtime?.state == .paused, "reappearing preview reloads saved settings with desired pause")
            model.dispose()
            let alternate = directory.appendingPathComponent("second-source")
            try FileManager.default.copyItem(at: fixture, to: alternate)
            let alternateProject = alternate.appendingPathComponent("project.json")
            var json = try JSONSerialization.jsonObject(with: Data(contentsOf: alternateProject)) as! [String: Any]
            json["title"] = "Independent Scene B"
            try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: alternateProject)
            let second = try await SceneWallpaperProjectImporter.importProject(alternate, store: store)
            model.activate()
            let oldStartup = Task { await model.update(item: item, paused: false, storage: storage) }
            await Task.yield()
            await model.update(item: second, paused: false, storage: storage)
            await oldStartup.value
            let sameSource = try model.runtime.map { try WebProjectPaths.canonical($0.projectURL) == WebProjectPaths.canonical(second.fileURL) } ?? false
            try check(sameSource && model.runtime?.state == .ready,
                      "rapid A to B replacement keeps only B host (state=\(String(describing: model.runtime?.state)),error=\(model.error ?? "none"))")
            try check(pixel(model.runtime!.posterImage!)[0] > 240 && AuthorPropertyServices.shared.readySceneHosts(itemID: item.id).isEmpty,
                      "late A startup cannot overwrite B pixels or retain A registry entry")
            let sceneURL = second.fileURL.deletingLastPathComponent().appendingPathComponent("scene.json")
            let originalScene = try Data(contentsOf: sceneURL)
            try Data("{broken scene".utf8).write(to: sceneURL, options: .atomic)
            await model.retry(item: second, paused: false, storage: storage)
            try check(model.runtime?.state == .failed && model.error != nil && !model.controlsState.canTogglePause,
                      "real failed Scene disables pause while preserving actual retry error")
            try originalScene.write(to: sceneURL, options: .atomic)
            await model.retry(item: second, paused: false, storage: storage)
            try check(model.runtime?.state == .ready && model.error == nil && model.controlsState.canTogglePause,
                      "existing retry restores actual ready pixels and pause availability after source repair")
            model.dispose()
            try check(store.assignments.isEmpty, "preview and author ACK never create desktop assignments")
        } catch { failure = error.localizedDescription }
        let result: [String: Any] = ["passed": failure == nil, "checks": checks, "error": failure ?? NSNull(),
            "scope": "Actual Scene importer/runtime/services/preview model; offscreen CPU pixels, no GUI launch or desktop/lockscreen assignment"]
        let data = try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try! data.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        print(String(decoding: data, as: UTF8.self))
        exit(failure == nil ? 0 : 1)
    }
}
