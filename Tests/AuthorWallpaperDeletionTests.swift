import AppKit
import Darwin
import Foundation
import WebKit

@main @MainActor enum AuthorWallpaperDeletionTests {
    static var checks = 0
    static let fm = FileManager.default
    static let services = AuthorPropertyServices.shared
    struct Fixture {
        let storage: AppStorage
        let store: VideoLibraryStore
        let playback: DesktopPlaybackController
        let layout: SteamCMDLayout
        let item: WallpaperItem
        let project: AuthorPropertyProject
        let source: URL
        let assetRoot: URL
        let overrideFile: URL
        let download: URL
    }
    static func check(_ value: Bool, _ name: String) throws {
        guard value else { throw WebProjectError.invalid(name) }
        checks += 1; print("PASS \(name)"); fflush(stdout)
    }
    static func rejected(_ name: String, _ action: () async throws -> Void) async throws {
        do { try await action() } catch { try check(true, name); return }
        throw WebProjectError.invalid(name + " unexpectedly succeeded")
    }
    static func wait(_ name: String, _ condition: @MainActor () async throws -> Bool) async throws {
        for _ in 0..<300 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        throw WebProjectError.invalid("Timeout: " + name)
    }
    static func js(_ runtime: WebWallpaperRuntime, _ script: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            runtime.webView.evaluateJavaScript(script) { result, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: String(describing: result ?? "nil")) }
            }
        }
    }
    static func svg(_ color: String) -> Data { Data("<svg xmlns='http://www.w3.org/2000/svg' width='2' height='2'><rect width='2' height='2' fill='\(color)'/></svg>".utf8) }
    static func fixture(_ base: URL, _ name: String, playing: Bool = true) async throws -> Fixture {
        let root = base.appendingPathComponent(name)
        let storage = AppStorage(root: root.appendingPathComponent("App"))
        let store = VideoLibraryStore(storage: storage)
        let sourceRoot = root.appendingPathComponent("UserProject")
        try fm.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try Data(#"{"type":"web","file":"index.html","general":{"properties":{"picture":{"type":"file","fileType":"image","value":""},"caption":{"type":"textinput","value":"DEFAULT"}}}}"#.utf8).write(to: sourceRoot.appendingPathComponent("project.json"))
        try Data(#"<html><body><script>window.caption='';window.hold=false;window.holding=false;window.wallpaperPropertyListener={applyUserProperties:async p=>{if(window.hold){window.holding=true;await new Promise(r=>window.release=r);window.holding=false;}if(p.caption)window.caption=p.caption.value;}};</script></body></html>"#.utf8).write(to: sourceRoot.appendingPathComponent("index.html"))
        let item = try await WebWallpaperProjectImporter.importProject(sourceRoot, store: store,
            origin: .init(workshopID: "887766", title: name))
        let project = try AuthorPropertyServices.project(for: item)!
        let source = root.appendingPathComponent("UserChosen.svg")
        try svg("red").write(to: source)
        let resources = services.assets(storage: storage), overrides = services.store(storage: storage)
        _ = try await resources.selectFile(source, itemID: item.id, propertyKey: "picture", project: project)
        try svg("blue").write(to: source)
        let second = try await resources.selectFile(source, itemID: item.id, propertyKey: "picture", project: project)
        try await overrides.set(second.value, for: "picture", itemID: item.id, project: project)
        try await overrides.set(.string("KEPT"), for: "caption", itemID: item.id, project: project)
        let overrideFile = storage.root.appendingPathComponent("AuthorPropertyOverrides/\(item.id.uuidString).json")
        var document = try JSONDecoder().decode(GWJSONValue.self, from: Data(contentsOf: overrideFile)).objectValue!
        var values = document["values"]!.objectValue!; values["future-unknown"] = .object(["keep": .bool(true)])
        document["values"] = .object(values)
        try JSONEncoder().encode(GWJSONValue.object(document)).write(to: overrideFile)
        let layout = SteamCMDLayout(root: storage.workshopDirectory.appendingPathComponent("SteamCMD"))
        let download = layout.downloadDirectory(for: WorkshopItemID("887766")!)
        try fm.copyItem(at: sourceRoot, to: { () throws -> URL in
            try fm.createDirectory(at: download.deletingLastPathComponent(), withIntermediateDirectories: true); return download
        }())
        let frame = CGRect(x: 0, y: 0, width: 320, height: 180)
        let displays = DisplayRegistry(snapshot: ["one", "two"].enumerated().map { index, id in
            .init(id: id, displayID: UInt32(index + 1), localizedName: id, frame: frame,
                visibleFrame: frame, backingScaleFactor: 1, isPrimary: index == 0, pixelSize: frame.size)
        })
        let playback = DesktopPlaybackController(store: store, displayRegistry: displays, storage: storage, previewOnly: true)
        if playing {
            if let error = playback.apply(item: item, to: ["one", "two"]) { throw WebProjectError.invalid(error) }
            try await wait("two real Web hosts ready") {
                let hosts = services.readyHosts(itemID: item.id)
                guard hosts.count == 2 else { return false }
                return try await js(hosts[0], "window.caption") == "KEPT"
            }
        }
        store.flush()
        return .init(storage: storage, store: store, playback: playback, layout: layout, item: item,
            project: project, source: source, assetRoot: storage.root.appendingPathComponent("AuthorPropertyAssets/\(item.id.uuidString)"),
            overrideFile: overrideFile, download: download)
    }
    static func trash(_ source: URL, into base: URL) throws -> URL {
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let destination = base.appendingPathComponent(UUID().uuidString)
        try fm.moveItem(at: source, to: destination); return destination
    }
    static func run(_ root: URL) async throws {
        do {
            let f = try await fixture(root, "success")
            defer { f.playback.tearDownAll() }
            let resources = services.assets(storage: f.storage), overrides = services.store(storage: f.storage)
            let sourceBytes = try Data(contentsOf: f.source), overrideBytes = try Data(contentsOf: f.overrideFile)
            let retainedVersions = try fm.contentsOfDirectory(atPath: f.assetRoot.path).filter { UUID(uuidString: $0) != nil }
            try check(retainedVersions.count == 2, "fixture contains old and current immutable resource versions")
            let otherID = UUID()
            let otherGrant = try await resources.selectFile(f.source, itemID: otherID, propertyKey: "picture", project: f.project)
            try await overrides.set(otherGrant.value, for: "picture", itemID: otherID, project: f.project)
            let otherAssets = f.assetRoot.deletingLastPathComponent().appendingPathComponent(otherID.uuidString)
            let otherOverride = f.overrideFile.deletingLastPathComponent().appendingPathComponent(otherID.uuidString + ".json")
            let otherBytes = try Data(contentsOf: otherOverride)
            let lockCopy = f.storage.root.appendingPathComponent("NativeLockScreen/independent-copy.mp4")
            try fm.createDirectory(at: lockCopy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("independent lockscreen copy".utf8).write(to: lockCopy)
            let hosts = services.readyHosts(itemID: f.item.id)
            let session = AuthorPropertySettingsSession(project: f.project, overrideStore: overrides, itemID: f.item.id,
                capabilities: .init(editableKeys: ["caption"], runtimeLabel: "test", unsupportedReason: ""),
                coalescingDelay: .seconds(1)) { _ in
                    try await services.applySavedSettings(project: f.project, itemID: f.item.id, storage: f.storage)
                }
            await session.load(); session.set(.string("LATE UI SAVE"), for: f.project.definition(for: "caption")!)
            var moved: [URL: URL] = [:]
            let deletion = ManagedWallpaperDeletionService(store: f.store, playback: f.playback, storage: f.storage,
                workshopLayout: f.layout, trashOperation: { source in
                    let target = try trash(source, into: root.appendingPathComponent("TrashSuccess")); moved[source] = target; return target
                })
            try check(await deletion.delete(workshopID: "887766") == nil, "author assets and overrides commit in managed deletion")
            await session.waitUntilIdle()
            guard let trashedAssets = moved[f.assetRoot], let trashedOverrides = moved[f.overrideFile] else {
                throw WebProjectError.invalid("Author data did not enter same Trash transaction")
            }
            try check(try Data(contentsOf: trashedOverrides) == overrideBytes, "Trash retains complete override document including unknown values")
            try check(retainedVersions.allSatisfy { fm.fileExists(atPath: trashedAssets.appendingPathComponent($0).path) }
                && fm.fileExists(atPath: trashedAssets.appendingPathComponent("grants.json").path), "Trash retains bookmarks and every asset version")
            try check(!fm.fileExists(atPath: f.assetRoot.path) && !fm.fileExists(atPath: f.overrideFile.path), "late coalesced scalar UI save cannot recreate deleted data")
            try check(session.errorText != nil && !session.savedButNotApplied, "late UI writer reports save rejection rather than false saved success")
            try check(hosts.count == 2 && hosts.allSatisfy { $0.state == .disposed } && services.readyHosts(itemID: f.item.id).isEmpty,
                "commit disposes every same-item Web host and unregisters service handles")
            try check(f.playback.sessions.isEmpty && f.store.assignments.isEmpty && f.store.items.isEmpty, "commit releases sessions and persisted assignment/library records")
            try check(try Data(contentsOf: f.source) == sourceBytes, "original user-selected resource is preserved")
            try check(fm.fileExists(atPath: otherAssets.path) && (try Data(contentsOf: otherOverride)) == otherBytes,
                "other item grants and overrides remain unchanged")
            try check(try Data(contentsOf: lockCopy) == Data("independent lockscreen copy".utf8), "independent native lockscreen copy is preserved")
            try await rejected("late scalar actor set is tombstoned") { try await overrides.set(.string("late"), for: "caption", itemID: f.item.id, project: f.project) }
            try await rejected("late scalar reset is tombstoned") { try await overrides.reset(itemID: f.item.id) }
            try await rejected("late resource selection is tombstoned") { _ = try await resources.selectFile(f.source, itemID: f.item.id, propertyKey: "picture", project: f.project) }
            try await rejected("late manifest read cannot rebuild item vault") { _ = try await resources.manifest(itemID: f.item.id) }
            try await rejected("late service resource request is tombstoned") {
                try await services.performResource(.init(itemID: f.item.id, project: f.project, definition: f.project.definition(for: "picture")!, operation: .select(f.source)), storage: f.storage)
            }
            let originalProject = f.source.deletingLastPathComponent().appendingPathComponent("UserProject")
            let late = try WebWallpaperRuntime(projectURL: originalProject.appendingPathComponent("project.json"), entryURL: originalProject.appendingPathComponent("index.html"), propertiesJSON: Data("{}".utf8))
            _ = services.register(late, itemID: f.item.id)
            try check(late.state == .disposed, "late host registration is disposed without rebuilding context")
            try svg("green").write(to: f.source)
            try await Task.sleep(for: .milliseconds(700))
            try check(!fm.fileExists(atPath: f.assetRoot.path) && !fm.fileExists(atPath: f.overrideFile.path), "source event after deletion cannot rebuild grants or overrides")
        }
        for saveFailure in [false, true] {
            let f = try await fixture(root, saveFailure ? "save-rollback" : "move-rollback")
            defer { f.playback.tearDownAll() }
            let beforeLibrary = try Data(contentsOf: f.storage.libraryFile), beforeOverride = try Data(contentsOf: f.overrideFile)
            let beforeGrants = try Data(contentsOf: f.assetRoot.appendingPathComponent("grants.json"))
            let runtime = services.readyHosts(itemID: f.item.id)[0]
            var moved = 0
            if saveFailure { try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: f.storage.root.path) }
            defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.storage.root.path) }
            let deletion = ManagedWallpaperDeletionService(store: f.store, playback: f.playback, storage: f.storage,
                workshopLayout: f.layout, trashOperation: { source in
                    moved += 1
                    if !saveFailure && source == f.overrideFile { throw WebProjectError.invalid("controlled override Trash failure") }
                    return try trash(source, into: root.appendingPathComponent("TrashRollback"))
                })
            let error = await deletion.delete(workshopID: "887766")
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.storage.root.path)
            try check(error != nil && moved >= 3, "\(saveFailure ? "library write" : "override move") failure enters rollback after managed file moves")
            try check(try Data(contentsOf: f.overrideFile) == beforeOverride && Data(contentsOf: f.assetRoot.appendingPathComponent("grants.json")) == beforeGrants,
                "rollback restores exact override and bookmark bytes")
            try check(try Data(contentsOf: f.storage.libraryFile) == beforeLibrary && f.store.items.count == 1 && f.store.assignments.count == 2,
                "rollback preserves disk library and in-memory assignments")
            try check(f.playback.sessions.count == 2 && runtime.state != .disposed, "rollback retains live Web players")
            let overrides = services.store(storage: f.storage)
            try await overrides.set(.string("AFTER FAILURE"), for: "caption", itemID: f.item.id, project: f.project)
            try await services.applySavedSettings(project: f.project, itemID: f.item.id, storage: f.storage)
            try check(try await js(runtime, "window.caption") == "AFTER FAILURE", "rollback releases scalar barrier and keeps host editable")
            let oldRevision = try await services.assets(storage: f.storage).grants(itemID: f.item.id)[0].revision
            try svg("purple").write(to: f.source)
            try await wait("rollback restores automatic resource monitor") {
                try await services.assets(storage: f.storage).grants(itemID: f.item.id)[0].revision != oldRevision
            }
            try check(true, "rollback restores real automatic source-change refresh")
        }
        for cancel in [false, true] {
            let f = try await fixture(root, cancel ? "cancel-waiter" : "serialize-waiter")
            defer { f.playback.tearDownAll() }
            let host = services.readyHosts(itemID: f.item.id)[0]
            _ = try await js(host, "window.hold=true; true")
            try await services.store(storage: f.storage).set(.string("HELD CHANGE"), for: "caption", itemID: f.item.id, project: f.project)
            let pendingApply = Task { @MainActor in
                try await services.applySavedSettings(project: f.project, itemID: f.item.id, storage: f.storage)
            }
            try await wait("actual authored callback holds the item lock") { try await js(host, "String(window.holding)") == "true" }
            let deletion = ManagedWallpaperDeletionService(store: f.store, playback: f.playback, storage: f.storage,
                workshopLayout: f.layout, trashOperation: { try trash($0, into: root.appendingPathComponent("TrashSerial")) })
            var completed = false
            let request = Task { @MainActor in
                let error = await deletion.delete(workshopID: "887766"); completed = true; return error
            }
            try await Task.sleep(for: .milliseconds(150))
            try check(!completed && fm.fileExists(atPath: f.assetRoot.path) && f.item.fileExists,
                "deletion waits for active real-host setting ACK before moving files")
            if cancel { request.cancel() }
            _ = try await js(host, "window.hold=false;if(window.release)window.release();true")
            try await pendingApply.value
            let error = await request.value
            if cancel {
                try check(error != nil && f.item.fileExists && f.playback.sessions.count == 2,
                    "cancelled lock waiter leaves library, resources and live sessions intact")
                try await services.store(storage: f.storage).set(.string("AFTER CANCEL"), for: "caption", itemID: f.item.id, project: f.project)
                try await services.applySavedSettings(project: f.project, itemID: f.item.id, storage: f.storage)
                try check(try await js(host, "window.caption") == "AFTER CANCEL", "cancelled deletion releases barriers and item lock")
            } else {
                try check(error == nil && !fm.fileExists(atPath: f.assetRoot.path) && host.state == .disposed,
                    "waiting deletion commits after pending ACK and disposes held host")
            }
        }
        for component in ["AuthorPropertyAssets", "AuthorPropertyOverrides", "asset-item", "override-item"] {
            let f = try await fixture(root, "symlink-" + component, playing: false)
            defer { f.playback.tearDownAll() }
            let protected = root.appendingPathComponent("protected-" + UUID().uuidString)
            try fm.createDirectory(at: protected, withIntermediateDirectories: true)
            let sentinel = protected.appendingPathComponent("keep.txt"); try Data("keep".utf8).write(to: sentinel)
            let path: URL
            switch component {
            case "asset-item": path = f.assetRoot
            case "override-item": path = f.overrideFile
            default: path = f.storage.root.appendingPathComponent(component)
            }
            try fm.removeItem(at: path)
            try fm.createSymbolicLink(at: path, withDestinationURL: protected)
            let deletion = ManagedWallpaperDeletionService(store: f.store, playback: f.playback, storage: f.storage,
                workshopLayout: f.layout, trashOperation: { _ in throw WebProjectError.invalid("unsafe path reached Trash") })
            try check(await deletion.delete(workshopID: "887766") != nil, "reject symlink at \(component)")
            try check(try Data(contentsOf: sentinel) == Data("keep".utf8) && f.item.fileExists && f.store.items.count == 1,
                "symlink rejection preserves external target and library at \(component)")
        }
    }
    static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        Task {
            let root = fm.temporaryDirectory.appendingPathComponent("GW-Author-Deletion-\(UUID())")
            do { try await run(root); print("RESULT \(checks) passed, 0 failed") }
            catch { print("FAIL \(error)"); try? fm.removeItem(at: root); exit(1) }
            try? fm.removeItem(at: root); exit(0)
        }
        app.run()
    }
}
