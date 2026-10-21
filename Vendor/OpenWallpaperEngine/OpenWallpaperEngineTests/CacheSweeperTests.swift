import XCTest
@testable import OpenWallpaperEngine

/// OWE's own caches: entries unused for 60 days expire, Clear Caches deletes the rest, and neither
/// touches what is in use (`CacheLeases`) or protected. Every test works on scratch folders.
final class CacheSweeperTests: XCTestCase {
    private var root: URL!
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "CacheSweeperTests-\(UUID().uuidString)",
                                                               directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root) // Scratch folder.
    }

    private func folder(_ id: CacheFolder.ID, expires: Bool = true) -> CacheFolder {
        CacheFolder(id: id, root: root.appending(path: id.rawValue, directoryHint: .isDirectory), expires: expires)
    }

    /// Writes a file under `folder` last used `daysAgo` days before `now`.
    @discardableResult
    private func entry(_ path: String, in folder: CacheFolder, daysAgo: Double, bytes: Int = 100) throws -> URL {
        let url = folder.root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-daysAgo * 86400)],
                                              ofItemAtPath: url.path(percentEncoded: false))
        return url
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

    private func sweep(_ sweeper: CacheSweeper, clear: Bool = false) -> CacheSweeper.Result {
        var result = CacheSweeper.Result()
        _ = expectThreadGuardViolations { result = clear ? sweeper.clear() : sweeper.expire(now: now) }
        return result
    }

    // MARK: - The 60-day rule

    func testEntriesUnusedFor60DaysExpire() throws {
        let textures = folder(.textures), snapshots = folder(.loadingSnapshots), shaders = folder(.shaderVariants, expires: false)
        let old = try entry("aa-l0.owetex", in: textures, daysAgo: 61)
        let recent = try entry("bb-l0.owetex", in: textures, daysAgo: 59)
        let oldSnapshot = try entry("r1/wallpaper-1/key-1920x1080.heic", in: snapshots, daysAgo: 90)
        let keptSnapshot = try entry("r1/wallpaper-2/key-1920x1080.heic", in: snapshots, daysAgo: 1)
        let oldShader = try entry("v1/variant.metal", in: shaders, daysAgo: 400)

        let result = sweep(CacheSweeper(folders: [textures, snapshots, shaders], leases: CacheLeases()))
        XCTAssertEqual(result.removedFiles, 2)
        XCTAssertFalse(exists(old))
        XCTAssertTrue(exists(recent))
        XCTAssertFalse(exists(oldSnapshot))
        XCTAssertFalse(exists(oldSnapshot.deletingLastPathComponent()), "an emptied wallpaper folder goes")
        XCTAssertTrue(exists(keptSnapshot))
        XCTAssertTrue(exists(oldShader), "translated shaders only go with Clear Caches")
        XCTAssertTrue(exists(textures.root), "a cache's root stays")
    }

    func testServingAnEntryMarksItUsed() throws {
        let textures = folder(.textures)
        let url = try entry("aa-l0.owetex", in: textures, daysAgo: 90)
        CacheEntryUse.markUsed(url, now: now)
        XCTAssertEqual(sweep(CacheSweeper(folders: [textures], leases: CacheLeases())).removedFiles, 0)
        XCTAssertTrue(exists(url))

        // A recent mark isn't written again: one stat per use.
        let marked = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.modificationDate] as? Date)
        CacheEntryUse.markUsed(url, now: now.addingTimeInterval(3600))
        let after = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.modificationDate] as? Date)
        XCTAssertEqual(after, marked)
    }

    // MARK: - In use

    func testEntriesInUseAreKept() throws {
        let textures = folder(.textures), snapshots = folder(.loadingSnapshots), videos = folder(.repairedVideos)
        let blob = try entry("aa-l0.owetex", in: textures, daysAgo: 300)
        let snapshot = try entry("r1/wallpaper-1/key-3840x2160.heic", in: snapshots, daysAgo: 300)
        let copy = try entry("r1/0123/42-1.mp4", in: videos, daysAgo: 300)
        let record = try entry("r1/0123/.source", in: videos, daysAgo: 300)
        let leases = CacheLeases()
        let blobLease = leases.lease(blob)
        let set = CacheLeaseSet(registry: leases)
        set.hold(snapshot.deletingLastPathComponent(), scope: root) // a scene on screen holds its snapshot folder
        let copyLease = leases.lease(copy)

        for clear in [false, true] {
            let result = sweep(CacheSweeper(folders: [textures, snapshots, videos], leases: leases), clear: clear)
            XCTAssertEqual(result.removedFiles, 0)
            XCTAssertTrue(exists(blob) && exists(snapshot) && exists(copy) && exists(record))
        }

        blobLease.release()
        set.hold(root.appending(path: "elsewhere"), scope: root.appending(path: "another wallpaper"))
        withExtendedLifetime(copyLease) {
            let result = sweep(CacheSweeper(folders: [textures, snapshots, videos], leases: leases))
            XCTAssertEqual(result.removedFiles, 2, "released leases no longer protect")
            XCTAssertFalse(exists(blob) || exists(snapshot))
            XCTAssertTrue(exists(copy))
        }
    }

    func testAReleasedOrDroppedLeaseFreesItsPath() throws {
        let leases = CacheLeases()
        let url = root.appending(path: "a/b.owetex")
        var lease: CacheLease? = leases.lease(url)
        let second = leases.lease(url)
        XCTAssertTrue(leases.isLeased(url))
        XCTAssertTrue(leases.isLeased(root.appending(path: "a")), "its folder holds it")
        XCTAssertFalse(leases.isLeased(root.appending(path: "ab")))
        lease = nil
        XCTAssertTrue(leases.isLeased(url), "the second use still holds it")
        second.release()
        second.release()
        XCTAssertFalse(leases.isLeased(url))
        XCTAssertNil(lease)
    }

    func testProtectedFoldersAndForeignFilesAreKept() throws {
        let previews = folder(.editorPreviews)
        let current = try entry("steam-1-r2.2/effects_blur.heic", in: previews, daysAgo: 120)
        let currentInputs = try entry("steam-1-r2.2/.inputs.json", in: previews, daysAgo: 120)
        let other = try entry("steam-0-r2.2/effects_blur.heic", in: previews, daysAgo: 120)
        try entry("steam-0-r2.2/.inputs.json", in: previews, daysAgo: 120)
        let legacy = CacheFolder(id: .legacyVideoTextures, root: root.appending(path: "VideoTextures"), expires: true)
        let ours = try entry(String(repeating: "ab", count: 32) + ".mp4", in: legacy, daysAgo: 70)
        let foreign = try entry("someone-elses.mp4", in: legacy, daysAgo: 700)

        let sweeper = CacheSweeper(folders: [previews, legacy], leases: CacheLeases(),
                                   protected: [current.deletingLastPathComponent()])
        XCTAssertEqual(sweep(sweeper).removedFiles, 2)
        XCTAssertTrue(exists(current) && exists(currentInputs), "the previews of the assets in use stay")
        XCTAssertFalse(exists(other.deletingLastPathComponent()), "another build's folder goes with its bookkeeping")
        XCTAssertFalse(exists(ours))
        XCTAssertTrue(exists(foreign), "only OWE's own names in the shared Caches folder")
    }

    func testIsolatedCopiesLeaveTheLegacyFolderAlone() {
        let caches = root.appending(path: "Caches")
        let isolated = CacheFolder.ownCaches(location: AppStorageLocation(isolationTag: "sweeper"), textureRoot: root,
                                             userCaches: caches)
        XCTAssertFalse(isolated.contains { $0.id == .legacyVideoTextures })
        XCTAssertTrue(isolated.allSatisfy { $0.root.path(percentEncoded: false).contains("isolated sweeper") || $0.id == .textures })
        let user = CacheFolder.ownCaches(location: AppStorageLocation(isolationTag: nil), textureRoot: root, userCaches: caches)
        XCTAssertEqual(user.first { $0.id == .legacyVideoTextures }?.root, caches.appending(path: "VideoTextures", directoryHint: .isDirectory))
    }

    // MARK: - Clear Caches

    func testClearCachesDeletesEverythingButWhatIsInUse() throws {
        let textures = folder(.textures), shaders = folder(.shaderVariants, expires: false)
        let archives = folder(.pipelineArchives, expires: false)
        try entry("aa-l0.owetex", in: textures, daysAgo: 0, bytes: 5000)
        try entry("v1/variant.metal", in: shaders, daysAgo: 0)
        let archive = try entry("gpu--key.binarchive", in: archives, daysAgo: 0)
        let leases = CacheLeases()
        let lease = leases.lease(archive)
        let metal = MetalShaderCache(directory: root.appending(path: "darwin/app.openwallpaperengine/com.apple.metal"))

        var result: CacheMaintenance.ClearResult?
        _ = expectThreadGuardViolations {
            result = CacheMaintenance.clear(folders: [textures, shaders, archives], metal: metal, protected: [], leases: leases)
        }
        XCTAssertEqual(result?.removed.removedFiles, 2)
        XCTAssertGreaterThan(result?.removed.removedBytes ?? 0, 0)
        XCTAssertEqual(result?.metalCacheResetRequested, true)
        XCTAssertTrue(exists(metal.requestFile), "the Metal cache goes at the next launch")
        XCTAssertTrue(exists(archive), "the pipeline archive in use stays")
        XCTAssertFalse(exists(shaders.root.appending(path: "v1")))
        withExtendedLifetime(lease) {}
    }

    @MainActor
    func testTheSectionMeasuresAndClears() async {
        let cleared = expectation(description: "cleared")
        let state = Counter()
        let model = CachesSectionModel(measure: { await state.next() }, clearAll: {
            cleared.fulfill()
            return CacheMaintenance.ClearResult(removed: CacheSweeper.Result(), metalCacheResetRequested: true)
        })
        XCTAssertNil(model.totalBytes)
        await model.refreshNow()
        XCTAssertEqual(model.totalBytes, 1)
        await model.clearNow()
        await fulfillment(of: [cleared], timeout: 5)
        XCTAssertFalse(model.isClearing)
        XCTAssertEqual(model.totalBytes, 2, "measured again afterwards")
    }

    func testTheSettingsSearchFindsTheCaches() {
        let entries = SettingsSearch.entries.filter { $0.anchor == SettingsAnchor.caches }
        XCTAssertEqual(Set(entries.map(\.title.key)), ["Caches", "Cache Size", "Clear Caches"])
        XCTAssertTrue(entries.allSatisfy { $0.tab == .performance })
    }
}

private actor Counter {
    private var value: Int64 = 0
    func next() -> Int64 {
        value += 1
        return value
    }
}
