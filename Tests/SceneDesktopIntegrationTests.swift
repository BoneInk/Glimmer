import AppKit
import CoreGraphics
import Foundation

/// Real renderer/actors/desktop controller, temporary persistence and two virtual
/// displays. previewOnly prevents all native desktop windows/system writes.
@main @MainActor enum SceneDesktopIntegrationTests {
    static let fm = FileManager.default
    static let services = AuthorPropertyServices.shared
    static var checks = 0
    static func check(_ value: Bool, _ name: String) throws {
        guard value else { throw SceneWallpaperFailure(message: name) }
        checks += 1; print("PASS \(name)"); fflush(stdout)
    }
    static func wait(_ name: String, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw SceneWallpaperFailure(message: "Timeout: " + name)
    }
    static func pixel(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        let info = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        try bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info) else { throw SceneWallpaperFailure(message: "Cannot sample pixels") }
            context.draw(image, in: CGRect(x: -image.width / 2, y: -image.height / 2, width: image.width, height: image.height))
        }
        return bytes
    }
    static func white(_ image: CGImage?) throws -> Bool {
        guard let image else { return false }; let p = try pixel(image)
        return p[0] > 240 && p[1] > 240 && p[2] > 240
    }
    static func red(_ image: CGImage?, half: Bool = false) throws -> Bool {
        guard let image else { return false }; let p = try pixel(image)
        return (half ? (110...145).contains(Int(p[0])) : p[0] > 240) && p[1] < 10 && p[2] < 10
    }
    static func black(_ image: CGImage?) throws -> Bool {
        guard let image else { return false }; return try pixel(image).prefix(3).allSatisfy { $0 < 10 }
    }
    static func u32(_ value: UInt32) -> Data { var v = value.littleEndian; return withUnsafeBytes(of: &v) { Data($0) } }
    static func json(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
    static func source(_ root: URL) throws -> URL {
        try fm.createDirectory(at: root.appendingPathComponent("models"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("materials"), withIntermediateDirectories: true)
        let properties: [String: Any] = ["visible": ["type":"bool","value":true], "tint": ["type":"color","value":"1 1 1"],
            "opacity": ["type":"slider","value":1,"min":0,"max":1,"step":0.01,"precision":2,"fraction":true], "picture": ["type":"file","fileType":"image","value":""]]
        try json(["type":"scene","file":"scene.json","title":"Desktop Scene fixture","general":["properties":properties]]).write(to: root.appendingPathComponent("project.json"))
        try json(["general":["orthogonalprojection":["width":64,"height":48],"clearcolor":"0 0 0"],
            "objects":[["id":1,"image":"models/image.json","origin":"32 24 0","size":"64 48", "visible":["user":"visible","value":true],
                "color":["user":"tint","value":"1 1 1"],"alpha":["user":"opacity","value":1]]]]).write(to: root.appendingPathComponent("scene.json"))
        try json(["material":"materials/image.json"]).write(to: root.appendingPathComponent("models/image.json"))
        try json(["passes":[["shader":"genericimage2","textures":["image"],"blending":"translucent"]]]).write(to: root.appendingPathComponent("materials/image.json"))
        var tex = Data("TEXV0005\0TEXI0001\0".utf8)
        for n: UInt32 in [0,0,2,2,2,2,0] { tex += u32(n) }
        tex += Data("TEXB0001\0".utf8)
        for n: UInt32 in [1,1,2,2,16] { tex += u32(n) }
        tex += Data(repeating: 255, count: 16)
        try tex.write(to: root.appendingPathComponent("materials/image.tex"))
        return root.appendingPathComponent("project.json")
    }
    static func run(_ root: URL) async throws {
        let storage = AppStorage(root: root.appendingPathComponent("App"))
        let store = VideoLibraryStore(storage: storage)
        let original = try source(root.appendingPathComponent("OriginalScene"))
        let originalJSON = try Data(contentsOf: original), originalTEX = try Data(contentsOf: original.deletingLastPathComponent().appendingPathComponent("materials/image.tex"))
        let importer = ImportService(store: store, storage: storage, thumbnailCache: ThumbnailCache(storage: storage))
        let metadata = ImportWorkshopMetadata(publishedFileID: "445566", title: "Scene fixture", pageURLString: nil,
            previewImageURLString: nil, authorSteamID: nil, fileByteSize: nil)
        guard case .imported(let sceneID) = await importer.importWorkshopScene(original, metadata: metadata),
              let scene = store.item(withID: sceneID) else { throw SceneWallpaperFailure(message: "Real Scene import failed") }
        try check(scene.isSceneWallpaper && scene.pixelWidth == 64 && scene.pixelHeight == 48, "real import stores Scene and inspected canvas")
        let cache = ThumbnailCache(storage: storage)
        guard let thumbnail = await cache.thumbnail(for: scene, targetSize: CGSize(width: 64, height: 48)),
              let thumbnailCG = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw SceneWallpaperFailure(message: "Scene thumbnail missing") }
        try check(try white(thumbnailCG), "actual Scene thumbnail has expected default white image pixels")
        try check(fm.fileExists(atPath: storage.thumbnailURL(for: sceneID).path), "Scene thumbnail persists a real default-composition image")
        let videoURL = storage.mediaDirectory.appendingPathComponent("existing.mp4")
        try await SyntheticVideoWriter.write(to: videoURL, options: .init(width: 64,height: 64,frameRate: 10,frameCount: 5))
        let video = WallpaperItem(title: "Old video", filePath: videoURL.path)
        store.add(video); store.flush()
        let frame = CGRect(x: 0,y: 0,width: 320,height: 240)
        let displays = DisplayRegistry(snapshot: ["A","B"].enumerated().map { index,id in
            .init(id: id,displayID: UInt32(index+1),localizedName: id,frame: frame,visibleFrame: frame,backingScaleFactor: 1,isPrimary: index == 0,pixelSize: frame.size)
        })
        let playback = DesktopPlaybackController(store: store, displayRegistry: displays, storage: storage, previewOnly: true, writesToLibrary: true)
        playback.setWallpaperFPS(24)
        defer { playback.tearDownAll() }
        try check(playback.apply(item: video, to: nil) == nil, "real AV video initially occupies both virtual displays")
        let oldB = playback.session(for: "B")!
        try check(await playback.applyAndWait(item: scene, to: ["A"]) == nil, "explicit Scene apply waits for actual render completion")
        guard let first = playback.session(for: "A"), let firstRuntime = first.sceneRuntime else { throw SceneWallpaperFailure(message: "Missing Scene host") }
        try check(firstRuntime.frameRateLimit == 24, "new desktop Scene inherits the global FPS cap")
        try check(firstRuntime.state == .ready && (try white(firstRuntime.posterImage)), "applied Scene host already has real default pixels")
        try check(first.player == nil && first.window == nil && firstRuntime.hostView !== oldB.hostView, "Scene uses native image host without AVPlayer or desktop window")
        try check(playback.session(for: "B") === oldB && store.assignments["B"] == video.id && store.assignments["A"] == sceneID,
            "target A apply preserves B player and persisted assignment")
        try check(await playback.applyAndWait(item: scene, to: nil) == nil, "all-target Scene apply completes two actual hosts")
        let all = [playback.session(for: "A")!.sceneRuntime!, playback.session(for: "B")!.sceneRuntime!]
        playback.setWallpaperFPS(90)
        try check(all.allSatisfy { $0.frameRateLimit == 90 }, "live FPS change reaches every desktop Scene session")
        try check(try all.allSatisfy { host in
            guard host.state == .ready || host.state == .paused else { return false }; return try white(host.posterImage)
        },
            "both published sessions are ready with real pixels")
        if ProcessInfo.processInfo.environment["GW_SCENE_DESKTOP_FPS_ONLY"] == "1" {
            print("RESULT \(checks) passed, 0 failed; isolated previewOnly Scene FPS propagation")
            return
        }
        try check(store.assignments["A"] == sceneID && store.assignments["B"] == sceneID && oldB.player == nil,
            "all-target commit changes both assignments and tears down old video")
        let project = try AuthorPropertyServices.project(for: scene)!
        let overrides = services.store(storage: storage)
        try check(services.editableKeys(project: project, itemID: sceneID).isSuperset(of: ["visible","tint","opacity"]), "actual direct Scene bindings enable bool/color/slider editors")
        try check(!services.editableKeys(project: project, itemID: sceneID).contains("picture"), "unbound Scene file property is not advertised as editable")
        try await overrides.set(.bool(false), for: "visible", itemID: sceneID, project: project)
        try await services.applySavedSettings(project: project, itemID: sceneID, storage: storage)
        try check(try all.allSatisfy { try black($0.posterImage) }, "bool save ACK hides actual layer on both hosts")
        try await overrides.set(.bool(true), for: "visible", itemID: sceneID, project: project)
        try await overrides.set(.string("1 0 0"), for: "tint", itemID: sceneID, project: project)
        try await services.applySavedSettings(project: project, itemID: sceneID, storage: storage)
        try check(try all.allSatisfy { try red($0.posterImage) }, "color save ACK turns both rendered layers red")
        try await overrides.set(.number(0.5), for: "opacity", itemID: sceneID, project: project)
        try await services.applySavedSettings(project: project, itemID: sceneID, storage: storage)
        try check(try all.allSatisfy { try red($0.posterImage, half: true) }, "slider save ACK changes both actual pixel intensities")
        playback.applyPolicyState(isBlocked: true, displayShouldPlay: { _ in true })
        try await services.applySavedSettings(project: project, itemID: sceneID, storage: storage)
        try check(all.allSatisfy { $0.state == .paused } && !playback.session(for: "A")!.isPlaying, "author updates preserve active policy suspension")
        playback.applyPolicyState(isBlocked: false, displayShouldPlay: { _ in true })
        store.updateAppSettings { $0.autoApplyOnLaunch = true }; store.flush()
        let savedAssignments = store.assignments
        playback.tearDownAll()
        try check(all.allSatisfy { $0.state == .disposed } && store.assignments == savedAssignments, "teardown disposes Scene hosts while retaining restart assignments")
        let restartedStore = VideoLibraryStore(storage: storage)
        let restored = DesktopPlaybackController(store: restartedStore, displayRegistry: displays, storage: storage, previewOnly: true, writesToLibrary: true)
        defer { restored.tearDownAll() }
        restored.restoreAssignmentsIfNeeded()
        try await wait("asynchronous Scene assignment restoration") {
            restored.session(for: "A")?.sceneRuntime?.posterImage != nil && restored.session(for: "B")?.sceneRuntime?.posterImage != nil
        }
        try check(try red(restored.session(for: "A")!.sceneRuntime!.posterImage, half: true) && red(restored.session(for: "B")!.sceneRuntime!.posterImage, half: true),
            "restart restore consumes persisted author overrides into actual two-host pixels")
        try check(restartedStore.assignments == savedAssignments, "asynchronous restoration preserves correct saved assignment mapping")
        restored.clear(displayIDs: ["A"])
        try check(restored.session(for: "A") == nil && restartedStore.assignments["A"] == nil && restored.session(for: "B")?.item.id == sceneID,
            "clear A removes only its Scene host and saved assignment")
        restored.clear(); try check(restored.sessions.isEmpty && restartedStore.assignments.isEmpty, "clear all disposes restored Scene hosts and persistence")

        try check(playback.apply(item: video, to: nil) == nil, "old controller can start independent video sessions after restore check")
        // A once-imported project can become unsupported on disk. Preparation
        // must reject its actual content while preserving the current videos.
        let brokenSource = try source(root.appendingPathComponent("BrokenSource"))
        var brokenProject = try JSONSerialization.jsonObject(with: Data(contentsOf: brokenSource)) as! [String: Any]
        brokenProject["title"] = "Independent broken fixture"
        try json(brokenProject).write(to: brokenSource)
        guard case .imported(let brokenID) = await importer.importLocalSceneProject(brokenSource), let broken = store.item(withID: brokenID) else { throw SceneWallpaperFailure(message: "Broken-source fixture setup failed") }
        let brokenScene = broken.fileURL.deletingLastPathComponent().appendingPathComponent("scene.json")
        var invalid = try JSONSerialization.jsonObject(with: Data(contentsOf: brokenScene)) as! [String: Any]
        var general = invalid["general"] as! [String: Any]; general["bloom"] = true; invalid["general"] = general
        try json(invalid).write(to: brokenScene)
        let previousA = playback.session(for: "A"), previousB = playback.session(for: "B"), previousAssignments = store.assignments
        try check(await playback.applyAndWait(item: broken, to: nil) != nil, "unsupported live Scene content rejects actual multi-host preparation")
        try check(playback.session(for: "A") === previousA && playback.session(for: "B") === previousB && store.assignments == previousAssignments,
            "failed Scene preparation preserves both prior video objects and assignments")
        let cancelled = Task { @MainActor in await playback.applyAndWait(item: scene, to: ["A"]) }; cancelled.cancel()
        try check(await cancelled.value != nil && playback.session(for: "A") === previousA && store.assignments == previousAssignments,
            "pre-cancelled async Scene apply leaves existing video and assignment intact")
        var concurrentStarted = false
        let concurrent = Task { @MainActor in
            concurrentStarted = true
            return await playback.applyAndWait(item: scene, to: ["A"])
        }
        while !concurrentStarted { await Task.yield() }
        _ = playback.apply(item: video, to: ["A"])
        _ = await concurrent.value
        try check(playback.session(for: "A")?.item.id == video.id && store.assignments["A"] == video.id,
            "new video command supersedes pending Scene without late reassignment")
        _ = playback.apply(item: scene, to: ["A"]); playback.clear(displayIDs: ["A"])
        try await Task.sleep(for: .milliseconds(100))
        try check(playback.session(for: "A") == nil && store.assignments["A"] == nil, "clear cancels legacy scheduled Scene intent")
        _ = playback.apply(item: scene, to: ["A"]); _ = playback.apply(item: video, to: ["A"])
        try await Task.sleep(for: .milliseconds(100))
        try check(playback.session(for: "A")?.item.id == video.id && store.assignments["A"] == video.id,
            "video command cancels legacy scheduled Scene intent")
        _ = playback.apply(item: scene, to: ["A"]); playback.tearDownAll()
        try await Task.sleep(for: .milliseconds(100))
        try check(playback.sessions.isEmpty, "teardown cancels legacy scheduled Scene without resurrecting host")
        try check(await playback.applyAndWait(item: scene, to: ["A"]) == nil, "Scene can be explicitly reapplied before managed deletion")
        let deletedRuntime = playback.session(for: "A")!.sceneRuntime!
        _ = playback.apply(item: video, to: ["B"])
        let retainedVideoB = playback.session(for: "B")
        let chosenResource = root.appendingPathComponent("UserSelected.svg")
        let resourceBytes = Data("<svg xmlns='http://www.w3.org/2000/svg' width='2' height='2'/>".utf8)
        try resourceBytes.write(to: chosenResource)
        // An existing explicit native grant may be present even though this
        // Scene subset does not expose file editing. Deletion must remove it.
        _ = try await services.assets(storage: storage).selectFile(chosenResource, itemID: sceneID, propertyKey: "picture", project: project)
        let assets = storage.root.appendingPathComponent("AuthorPropertyAssets/\(sceneID.uuidString)")
        let overrideFile = storage.root.appendingPathComponent("AuthorPropertyOverrides/\(sceneID.uuidString).json")
        let lockCopy = storage.root.appendingPathComponent("NativeLockScreen/independent.mp4")
        try fm.createDirectory(at: lockCopy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("lockscreen independent".utf8).write(to: lockCopy)
        let layout = SteamCMDLayout(root: storage.workshopDirectory.appendingPathComponent("SteamCMD"))
        let download = layout.downloadDirectory(for: WorkshopItemID("445566")!)
        try fm.createDirectory(at: download.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: original.deletingLastPathComponent(), to: download)
        var moves: [URL: URL] = [:]
        let deletion = ManagedWallpaperDeletionService(store: store, playback: playback, storage: storage, workshopLayout: layout,
            trashOperation: { source in
                let trash = root.appendingPathComponent("SimulatedTrash")
                try fm.createDirectory(at: trash, withIntermediateDirectories: true)
                let target = trash.appendingPathComponent(UUID().uuidString)
                try fm.moveItem(at: source, to: target); moves[source] = target; return target
            })
        _ = playback.apply(item: scene, to: ["A"])
        try check(await deletion.delete(workshopID: "445566") == nil, "managed Scene deletion includes author data in real rollback-capable transaction")
        try await Task.sleep(for: .milliseconds(150))
        let sceneRoot = scene.fileURL.deletingLastPathComponent()
        guard let trashedScene = moves[sceneRoot] else { throw SceneWallpaperFailure(message: "Whole Scene root was not trashed") }
        try check(fm.fileExists(atPath: trashedScene.appendingPathComponent("scene.json").path)
            && fm.fileExists(atPath: trashedScene.appendingPathComponent("materials/image.tex").path), "Trash contains whole managed Scene dependency tree")
        try check(moves[assets] != nil && moves[overrideFile] != nil && moves[download] != nil,
            "same transaction trashes author bookmark/vault, overrides and downloaded project")
        try check(deletedRuntime.state == .disposed && playback.session(for: "A") == nil && store.assignments["A"] == nil && store.item(withID: sceneID) == nil,
            "deletion disposes Scene and cancels scheduled Scene intent without resurrection")
        try check(playback.session(for: "B") === retainedVideoB && store.assignments["B"] == video.id && broken.fileExists,
            "Scene deletion preserves unrelated video session and other Scene item")
        try check(try Data(contentsOf: original) == originalJSON && Data(contentsOf: original.deletingLastPathComponent().appendingPathComponent("materials/image.tex")) == originalTEX
            && Data(contentsOf: chosenResource) == resourceBytes && Data(contentsOf: lockCopy) == Data("lockscreen independent".utf8),
            "deletion leaves original project, selected resource and independent lockscreen copy unchanged")
        try check(!fm.fileExists(atPath: sceneRoot.path) && !fm.fileExists(atPath: assets.path) && !fm.fileExists(atPath: overrideFile.path),
            "no removed Scene or author directory is rebuilt by late tasks")
        print("RESULT \(checks) passed, 0 failed; real Scene pixels/two-display controller/author ACK/isolated persistence and simulated Trash")
    }
    static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        Task {
            let root = fm.temporaryDirectory.appendingPathComponent("GW-Scene-Desktop-\(UUID())")
            do { try await run(root) }
            catch { print("FAIL \(error)"); try? fm.removeItem(at: root); exit(1) }
            try? fm.removeItem(at: root); exit(0)
        }
        app.run()
    }
}
