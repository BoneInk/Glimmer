import AppKit
import Foundation

@main struct ManagedWallpaperDeletionTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        var checks = 0
        func check(_ condition: Bool, _ name: String) {
            checks += 1
            precondition(condition, name)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GW-Delete-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = root.appendingPathComponent("original.mp4")
        try await SyntheticVideoWriter.write(to: original, options: .init(width: 64, height: 64, frameRate: 10, frameCount: 10))
        let originalBytes = try Data(contentsOf: original)
        @MainActor func fixture(_ name: String) throws -> (AppStorage, VideoLibraryStore, DesktopPlaybackController, SteamCMDLayout, WallpaperItem, URL) {
            let storage = AppStorage(root: root.appendingPathComponent(name))
            let store = VideoLibraryStore(storage: storage)
            let layout = SteamCMDLayout(root: storage.workshopDirectory.appendingPathComponent("SteamCMD"))
            let download = layout.downloadDirectory(for: WorkshopItemID("777")!)
            try FileManager.default.createDirectory(at: download, withIntermediateDirectories: true)
            try Data("download".utf8).write(to: download.appendingPathComponent("project.json"))
            let media = storage.mediaDirectory.appendingPathComponent("imported.mp4")
            try FileManager.default.copyItem(at: original, to: media)
            let item = WallpaperItem(title: "delete fixture", filePath: media.path, originalPath: original.path,
                                     source: .steamWorkshop, workshopID: "777")
            store.add(item)
            try Data("thumbnail".utf8).write(to: storage.thumbnailURL(for: item.id))
            store.flush()
            let frame = CGRect(x: 0, y: 0, width: 320, height: 180)
            let registry = DisplayRegistry(snapshot: [.init(id: "fixture-display", displayID: 1,
                localizedName: "fixture", frame: frame, visibleFrame: frame, backingScaleFactor: 1,
                isPrimary: true, pixelSize: frame.size)])
            let playback = DesktopPlaybackController(store: store, displayRegistry: registry, storage: storage, previewOnly: true)
            return (storage, store, playback, layout, item, download)
        }
        @MainActor func simulatedTrash(_ url: URL) throws -> URL {
            let trash = root.appendingPathComponent("SimulatedTrash")
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            let destination = trash.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        }
        func writeTrustedManifest(_ directory: URL, itemID: String = "777") throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let payload: [String: Any] = [
                "schemaVersion": 2,
                "appID": WorkshopInputValidator.wallpaperEngineAppID,
                "publishedFileID": itemID,
                "title": "native deletion fixture",
                "projectType": "web",
                "projectJSONRelativePath": "project.json",
                "validatedAt": "2026-10-18T00:00:00Z",
                "declaredTags": [],
                "appVersion": "test",
                "downloadBackend": "steamkit2"
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            try data.write(to: directory.appendingPathComponent("glimmer-download.json"))
        }
        func nativeItem(_ storage: AppStorage, itemID: String = "777") throws -> URL {
            let workspace = storage.workshopDirectory.appendingPathComponent("SteamContent", isDirectory: true)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: workspace.path)
            let item = workspace.appendingPathComponent("items/\(itemID)", isDirectory: true)
            try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)
            return item
        }
        do {
            let (storage, store, playback, layout, item, download) = try fixture("success")
            defer { playback.tearDownAll() }
            let lockCopy = storage.root.appendingPathComponent("NativeLockScreen/independent-copy.mp4")
            try FileManager.default.createDirectory(at: lockCopy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("independent lockscreen copy".utf8).write(to: lockCopy)
            let native = try nativeItem(storage)
            for manifest in ["111", "222"] {
                let version = native.appendingPathComponent(manifest, isDirectory: true)
                try FileManager.default.createDirectory(at: version.appendingPathComponent("content"), withIntermediateDirectories: true)
                try Data("native \(manifest)".utf8).write(to: version.appendingPathComponent("content/project.json"))
                try Data("checkpoint \(manifest)".utf8).write(to: version.appendingPathComponent("checkpoint.json"))
            }
            let otherNative = try nativeItem(storage, itemID: "778")
            try Data("other native item".utf8).write(to: otherNative.appendingPathComponent("keep.bin"))
            let previousRoot = layout.root.appendingPathComponent(".steam-content-previous", isDirectory: true)
            let previous = previousRoot.appendingPathComponent("777-11111111-1111-1111-1111-111111111111", isDirectory: true)
            try writeTrustedManifest(previous)
            let mismatched = previousRoot.appendingPathComponent("777-22222222-2222-2222-2222-222222222222", isDirectory: true)
            try writeTrustedManifest(mismatched, itemID: "778")
            let stage = download.deletingLastPathComponent()
                .appendingPathComponent(".steam-content-stage-777-33333333-3333-3333-3333-333333333333", isDirectory: true)
            try writeTrustedManifest(stage)
            let steamHome = layout.homeURL.appendingPathComponent("config", isDirectory: true)
            try FileManager.default.createDirectory(at: steamHome, withIntermediateDirectories: true)
            let accountSentinel = steamHome.appendingPathComponent("account-sentinel")
            try Data("account state".utf8).write(to: accountSentinel)
            let deliveryLock = download.deletingLastPathComponent().appendingPathComponent(".steam-content-delivery.lock")
            try Data("lock".utf8).write(to: deliveryLock)
            check(playback.apply(item: item, to: ["fixture-display"]) == nil, "start a real isolated player")
            let service = ManagedWallpaperDeletionService(store: store, playback: playback, storage: storage,
                workshopLayout: layout, trashOperation: simulatedTrash)
            let error = await service.delete(workshopID: "777", itemID: item.id)
            check(error == nil, "explicit deletion succeeds")
            check(!FileManager.default.fileExists(atPath: download.path) && !item.fileExists, "download and imported copy moved")
            check(!FileManager.default.fileExists(atPath: storage.thumbnailURL(for: item.id).path), "thumbnail moved")
            check(!FileManager.default.fileExists(atPath: native.path)
                    && !FileManager.default.fileExists(atPath: previous.path)
                    && !FileManager.default.fileExists(atPath: stage.path),
                  "all manifests, checkpoints and trusted delivery history moved")
            check(FileManager.default.fileExists(atPath: otherNative.path)
                    && FileManager.default.fileExists(atPath: mismatched.path),
                  "other item cache and identity-mismatched history preserved")
            check(service.lastCleanupDiagnostic?.contains("1 个") == true,
                  "skipped untrusted history has a readable diagnostic")
            check(try Data(contentsOf: accountSentinel) == Data("account state".utf8)
                    && FileManager.default.fileExists(atPath: deliveryLock.path),
                  "Steam account state and delivery lock remain untouched")
            check(store.items.isEmpty && playback.sessions.isEmpty && store.assignments.isEmpty, "associated library and real player removed")
            check((try Data(contentsOf: original)) == originalBytes, "original source never touched")
            check(try Data(contentsOf: lockCopy) == Data("independent lockscreen copy".utf8), "independent lockscreen copy never touched")
        }
        do {
            let (storage, store, playback, layout, imported, download) = try fixture("local-success")
            defer { playback.tearDownAll() }
            var item = imported
            item.source = .local
            item.workshopID = nil
            store.update(item)
            store.flush()
            check(playback.apply(item: item, to: ["fixture-display"]) == nil, "local deletion fixture starts a real isolated player")
            let service = ManagedWallpaperDeletionService(store: store, playback: playback, storage: storage,
                workshopLayout: layout, trashOperation: simulatedTrash)
            check(await service.deleteLocal(itemID: item.id) == nil, "local managed wallpaper deletion succeeds")
            check(!item.fileExists && !FileManager.default.fileExists(atPath: storage.thumbnailURL(for: item.id).path),
                  "local managed media and thumbnail move to simulated Trash")
            check(store.items.isEmpty && store.assignments.isEmpty && playback.sessions.isEmpty,
                  "local deletion removes record, assignment, and live playback")
            check(try Data(contentsOf: original) == originalBytes,
                  "local deletion preserves the user original byte for byte")
            check(FileManager.default.fileExists(atPath: download.path),
                  "local deletion never widens into an unrelated Workshop directory")
        }
        do {
            let (storage, store, playback, layout, imported, download) = try fixture("local-rollback")
            defer { playback.tearDownAll() }
            var item = imported
            item.source = .local
            item.workshopID = nil
            store.update(item)
            store.flush()
            _ = playback.apply(item: item, to: ["fixture-display"])
            let before = try Data(contentsOf: storage.libraryFile)
            var moves = 0
            let service = ManagedWallpaperDeletionService(store: store, playback: playback, storage: storage,
                workshopLayout: layout, trashOperation: { url in
                    moves += 1
                    if moves == 2 { throw NSError(domain: "local fixture failure", code: 2) }
                    return try simulatedTrash(url)
                })
            check(await service.deleteLocal(itemID: item.id) != nil, "local partial Trash failure is reported")
            check(item.fileExists && FileManager.default.fileExists(atPath: storage.thumbnailURL(for: item.id).path)
                    && FileManager.default.fileExists(atPath: download.path),
                  "local rollback restores managed files and leaves Workshop data alone")
            let after = try Data(contentsOf: storage.libraryFile)
            check(store.items.count == 1 && playback.sessions.count == 1 && after == before,
                  "local rollback preserves record, assignment, player, and persisted library")
            check(try Data(contentsOf: original) == originalBytes, "local rollback never touches the original")
        }
        do {
            let (storage, store, playback, layout, item, download) = try fixture("library-workshop-no-queue")
            defer { playback.tearDownAll() }
            let coordinator = WorkshopCoordinator(account: SteamAccountManager(layout: layout),
                browserStore: WorkshopBrowserStore(persistenceURL: nil), queuePersistence: .disabled)
            let service = ManagedWallpaperDeletionService(store: store, playback: playback, storage: storage,
                workshopLayout: layout, trashOperation: simulatedTrash)
            var callbackSawQueueRow = false
            coordinator.onDeleteWallpaper = { id in
                callbackSawQueueRow = !coordinator.downloadProgress.items.isEmpty
                return await service.delete(workshopID: id, itemID: item.id)
            }
            check(coordinator.downloadProgress.items.isEmpty, "external Steam-library import begins without a download queue row")
            check(await coordinator.deleteLibraryWallpaper(itemID: "777", title: item.displayTitle) == nil,
                  "library Workshop deletion reuses coordinator tombstone transaction without an existing row")
            check(coordinator.downloadProgress.items.isEmpty && store.items.isEmpty && !item.fileExists
                    && !FileManager.default.fileExists(atPath: download.path),
                  "managed download, copy, and record are removed without creating a queue row")
            check(!callbackSawQueueRow, "no-queue library deletion never exposes a synthetic row to scheduling")
            check(try Data(contentsOf: original) == originalBytes,
                  "coordinated Workshop library deletion preserves the external original")
        }
        do {
            let (storage, store, playback, layout, item, download) = try fixture("library-workshop-no-queue-failure")
            defer { playback.tearDownAll() }
            let coordinator = WorkshopCoordinator(account: SteamAccountManager(layout: layout),
                browserStore: WorkshopBrowserStore(persistenceURL: nil), queuePersistence: .disabled)
            let service = ManagedWallpaperDeletionService(store: store, playback: playback, storage: storage,
                workshopLayout: layout, trashOperation: { _ in throw NSError(domain: "controlled Trash failure", code: 4) })
            coordinator.onDeleteWallpaper = { id in await service.delete(workshopID: id, itemID: item.id) }
            check(await coordinator.deleteLibraryWallpaper(itemID: "777", title: item.displayTitle) != nil,
                  "no-queue Workshop library deletion reports filesystem failure")
            check(coordinator.downloadProgress.items.isEmpty && store.items.count == 1 && item.fileExists
                    && FileManager.default.fileExists(atPath: download.path),
                  "failed no-queue deletion leaves no synthetic row and preserves library and managed files")
            check(try Data(contentsOf: original) == originalBytes,
                  "failed no-queue deletion preserves the external original")
        }
        do {
            let (storage, store, playback, layout, item, download) = try fixture("rollback")
            defer { playback.tearDownAll() }
            _ = playback.apply(item: item, to: ["fixture-display"])
            store.flush()
            let before = try Data(contentsOf: storage.libraryFile)
            let native = try nativeItem(storage)
            try Data("partial native bytes".utf8).write(to: native.appendingPathComponent("partial.bin"))
            let previous = layout.root.appendingPathComponent(".steam-content-previous/777-44444444-4444-4444-4444-444444444444", isDirectory: true)
            try writeTrustedManifest(previous)
            let service = ManagedWallpaperDeletionService(store: store, playback: playback, storage: storage,
                workshopLayout: layout, trashOperation: { url in
                    if url.lastPathComponent == previous.lastPathComponent {
                        throw NSError(domain: "fixture failure", code: 2)
                    }
                    return try simulatedTrash(url)
                })
            check(await service.delete(workshopID: "777") != nil, "partial move reports failure")
            check(FileManager.default.fileExists(atPath: download.path) && item.fileExists, "already moved directory rolls back")
            check(FileManager.default.fileExists(atPath: native.appendingPathComponent("partial.bin").path)
                    && FileManager.default.fileExists(atPath: previous.path),
                  "native item cache rolls back when a later trusted-history move fails")
            check(store.items.count == 1 && playback.sessions.count == 1, "failure retains live player and record")
            check(try Data(contentsOf: storage.libraryFile) == before, "failure does not write library")
        }
        do {
            let (storage, store, playback, layout, item, _) = try fixture("shared")
            defer { playback.tearDownAll() }
            let other = WallpaperItem(title: "other reference", filePath: item.filePath)
            store.add(other)
            let service = ManagedWallpaperDeletionService(store: store, playback: playback, storage: storage,
                workshopLayout: layout, trashOperation: simulatedTrash)
            check(await service.delete(workshopID: "777") == nil, "shared imported media deletion completes safely")
            check(item.fileExists && store.items.map(\.id) == [other.id], "shared media and other record retained")
        }
        do {
            let (storage, store, playback, layout, item, download) = try fixture("traversal")
            defer { playback.tearDownAll() }
            try FileManager.default.removeItem(at: download)
            try FileManager.default.createSymbolicLink(at: download, withDestinationURL: root)
            let service = ManagedWallpaperDeletionService(store: store, playback: playback, storage: storage,
                workshopLayout: layout, trashOperation: { _ in preconditionFailure("unsafe move reached trash") })
            check(await service.delete(workshopID: "777") != nil, "download symlink refused")
            check(item.fileExists && store.items.count == 1 && FileManager.default.fileExists(atPath: original.path), "symlink refusal preserves files and record")
            check(await service.delete(workshopID: "../777") != nil, "invalid traversal ID refused")
            check(await service.delete(workshopID: "777", itemID: UUID()) != nil, "mismatched item UUID refused")
        }
        do {
            let (storage, store, playback, layout, item, download) = try fixture("hardlink")
            defer { playback.tearDownAll() }
            let outside = root.appendingPathComponent("hardlink-outside.mp4")
            try FileManager.default.copyItem(at: original, to: outside)
            try FileManager.default.removeItem(at: item.fileURL)
            try FileManager.default.linkItem(at: outside, to: item.fileURL)
            let outsideBytes = try Data(contentsOf: outside)
            let service = ManagedWallpaperDeletionService(store: store, playback: playback, storage: storage,
                workshopLayout: layout, trashOperation: { _ in preconditionFailure("hard-linked file reached trash") })
            check(await service.delete(workshopID: "777") != nil, "managed regular file with an outside hard link refused")
            check(try Data(contentsOf: outside) == outsideBytes && item.fileExists
                    && FileManager.default.fileExists(atPath: download.path) && store.items.count == 1,
                  "hardlink refusal preserves outside link, managed files, and library record")
        }
        do {
            let (storage, store, playback, layout, _, download) = try fixture("referenced-download")
            defer { playback.tearDownAll() }
            let shared = download.appendingPathComponent("referenced.mp4")
            try FileManager.default.copyItem(at: original, to: shared)
            store.add(WallpaperItem(title: "another item", filePath: shared.path))
            let service = ManagedWallpaperDeletionService(store: store, playback: playback, storage: storage,
                workshopLayout: layout, trashOperation: { _ in preconditionFailure("referenced download reached trash") })
            check(await service.delete(workshopID: "777") != nil && store.items.count == 2, "other live file references prevent removing download directory")
        }
        do {
            let (storage, store, playback, layout, item, _) = try fixture("cancelled")
            defer { playback.tearDownAll() }
            let service = ManagedWallpaperDeletionService(store: store, playback: playback, storage: storage,
                workshopLayout: layout, trashOperation: { _ in preconditionFailure("cancelled delete moved file") })
            let task = Task { await service.delete(workshopID: "777") }
            task.cancel()
            check(await task.value != nil && item.fileExists && store.items.count == 1, "cancel before start leaves all data")
            check(await service.delete(workshopID: "888") == nil && item.fileExists && store.items.count == 1,
                  "valid empty item-scoped deletion is idempotent and preserves unrelated data")
        }
        do {
            let (storage, store, playback, layout, item, download) = try fixture("native-partial-only")
            defer { playback.tearDownAll() }
            let native = try nativeItem(storage)
            let manifest = native.appendingPathComponent("987654321", isDirectory: true)
            try FileManager.default.createDirectory(at: manifest.appendingPathComponent("content"), withIntermediateDirectories: true)
            try Data("half downloaded bytes".utf8).write(to: manifest.appendingPathComponent("content/partial.bin"))
            try Data("partial checkpoint".utf8).write(to: manifest.appendingPathComponent("checkpoint.json"))
            try store.removePersistedItems(ids: [item.id])
            try FileManager.default.removeItem(at: download)
            try FileManager.default.removeItem(at: item.fileURL)
            try FileManager.default.removeItem(at: storage.thumbnailURL(for: item.id))
            let service = ManagedWallpaperDeletionService(store: store, playback: playback, storage: storage,
                workshopLayout: layout, trashOperation: simulatedTrash)
            check(await service.delete(workshopID: "777") == nil,
                  "partial-only native cache deletes without delivery or library metadata")
            check(!FileManager.default.fileExists(atPath: native.path),
                  "partial content and checkpoint for every manifest are moved together")
        }
        do {
            let (storage, store, playback, layout, item, download) = try fixture("queued-empty")
            defer { playback.tearDownAll() }
            try store.removePersistedItems(ids: [item.id])
            try FileManager.default.removeItem(at: download)
            try FileManager.default.removeItem(at: item.fileURL)
            try FileManager.default.removeItem(at: storage.thumbnailURL(for: item.id))
            let otherNative = try nativeItem(storage, itemID: "778")
            try Data("other item".utf8).write(to: otherNative.appendingPathComponent("keep.bin"))
            let accountDirectory = layout.homeURL.appendingPathComponent("config", isDirectory: true)
            try FileManager.default.createDirectory(at: accountDirectory, withIntermediateDirectories: true)
            let accountSentinel = accountDirectory.appendingPathComponent("login-sentinel")
            try Data("credentials stay".utf8).write(to: accountSentinel)
            var trashCalls = 0
            let service = ManagedWallpaperDeletionService(store: store, playback: playback, storage: storage,
                workshopLayout: layout, trashOperation: { url in
                    trashCalls += 1
                    return try simulatedTrash(url)
                })
            let coordinator = WorkshopCoordinator(
                account: SteamAccountManager(layout: layout),
                browserStore: WorkshopBrowserStore(persistenceURL: nil), queuePersistence: .disabled)
            var queued = WorkshopDownloadItem(publishedFileID: "777", title: "never started",
                                              kind: .video, declaredTags: ["Video"])
            queued.state = .queued
            coordinator.downloadProgress.items = [queued]
            coordinator.onDeleteWallpaper = { id in await service.delete(workshopID: id) }
            check(await coordinator.deleteDownloadedWallpaper(itemID: "777") == nil
                    && coordinator.downloadProgress.items.isEmpty,
                  "never-started queued record deletes successfully with no filesystem artifact")
            let preservedAccount = try Data(contentsOf: accountSentinel)
            check(trashCalls == 0 && FileManager.default.fileExists(atPath: otherNative.path)
                    && preservedAccount == Data("credentials stay".utf8),
                  "empty queued deletion performs no Trash move and preserves roots, other items and credentials")
        }
        do {
            let (storage, store, playback, layout, item, _) = try fixture("native-item-symlink")
            defer { playback.tearDownAll() }
            let outside = root.appendingPathComponent("native-symlink-outside")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try Data("outside".utf8).write(to: outside.appendingPathComponent("keep"))
            let workspace = storage.workshopDirectory.appendingPathComponent("SteamContent", isDirectory: true)
            try FileManager.default.createDirectory(at: workspace.appendingPathComponent("items"), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: workspace.path)
            try FileManager.default.createSymbolicLink(at: workspace.appendingPathComponent("items/777"), withDestinationURL: outside)
            let service = ManagedWallpaperDeletionService(store: store, playback: playback, storage: storage,
                workshopLayout: layout, trashOperation: { _ in preconditionFailure("native symlink reached Trash") })
            check(await service.delete(workshopID: "777") != nil && item.fileExists && store.items.count == 1,
                  "native item-root symlink rejects the whole deletion before any move")
            check(try Data(contentsOf: outside.appendingPathComponent("keep")) == Data("outside".utf8),
                  "native symlink target remains untouched")
        }
        do {
            let (storage, store, playback, layout, item, _) = try fixture("native-item-hardlink")
            defer { playback.tearDownAll() }
            let native = try nativeItem(storage)
            let outside = root.appendingPathComponent("native-hardlink-outside")
            try Data("shared inode".utf8).write(to: outside)
            try FileManager.default.linkItem(at: outside, to: native.appendingPathComponent("partial.bin"))
            let service = ManagedWallpaperDeletionService(store: store, playback: playback, storage: storage,
                workshopLayout: layout, trashOperation: { _ in preconditionFailure("native hardlink reached Trash") })
            check(await service.delete(workshopID: "777") != nil && item.fileExists && store.items.count == 1,
                  "hard link inside native cache rejects the whole deletion")
            check(try Data(contentsOf: outside) == Data("shared inode".utf8),
                  "outside hard-link peer remains untouched")
        }
        for rootName in ["Media", "Thumbnails", "Workshop"] {
            let (storage, store, playback, layout, item, _) = try fixture("root-link-" + rootName)
            defer { playback.tearDownAll() }
            let managed = storage.root.appendingPathComponent(rootName)
            let outside = root.appendingPathComponent("external-" + rootName)
            try FileManager.default.moveItem(at: managed, to: outside)
            try FileManager.default.createSymbolicLink(at: managed, withDestinationURL: outside)
            let service = ManagedWallpaperDeletionService(store: store, playback: playback, storage: storage,
                workshopLayout: layout, trashOperation: { _ in preconditionFailure("managed-root symlink reached trash") })
            check(await service.delete(workshopID: "777") != nil && store.items.count == 1,
                  "root symlink refused for " + rootName)
            check(item.fileExists && FileManager.default.fileExists(atPath: outside.path), "root symlink target remains intact")
        }
        do {
            let (storage, store, playback, layout, item, download) = try fixture("persist-failure")
            defer { playback.tearDownAll() }
            _ = playback.apply(item: item, to: ["fixture-display"])
            store.flush()
            let before = try Data(contentsOf: storage.libraryFile)
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: storage.root.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: storage.root.path) }
            let service = ManagedWallpaperDeletionService(store: store, playback: playback, storage: storage,
                workshopLayout: layout, trashOperation: simulatedTrash)
            check(await service.delete(workshopID: "777") != nil, "atomic library write failure is not success")
            check(item.fileExists && FileManager.default.fileExists(atPath: download.path), "persist failure restores all moved files")
            check(store.items.count == 1 && store.assignments.count == 1 && playback.sessions.count == 1,
                  "persist failure leaves in-memory records, assignments and real player intact")
            check(try Data(contentsOf: storage.libraryFile) == before, "persist failure preserves original on-disk library")
        }
        print("ManagedWallpaperDeletionTests: \(checks) passed; generated video, real AV player, simulated Trash in temporary root only")
    }
}
