import XCTest
@testable import OpenWallpaperEngine

/// `MetalShaderCache`: macOS's Metal cache of the app is deleted at launch when the shaders
/// changed, when Metal's usage database is full, or when Clear Caches asked, and never while
/// another OWE process uses it. Every test works on a scratch folder.
final class MetalShaderCacheTests: XCTestCase {
    private var root: URL!
    private var cache: MetalShaderCache!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "MetalShaderCacheTests-\(UUID().uuidString)",
                                                               directoryHint: .isDirectory)
        cache = MetalShaderCache(directory: root.appending(path: "app.openwallpaperengine/com.apple.metal", directoryHint: .isDirectory))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root) // Scratch folder.
    }

    /// A cache with a function file and Metal's usage database, `usedPages` of its 64 pages used.
    private func fillCache(usedPages: Int = 15) throws {
        let functions = cache.directory.appending(path: "16777235_403", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: functions, withIntermediateDirectories: true)
        try Data(count: 4096).write(to: functions.appending(path: "functions.data"))
        let database = cache.directory.appending(path: "archiveUsage.db", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: database, withIntermediateDirectories: true)
        try Self.lmdbFile(mapSize: 1 << 20, pageSize: 16384, lastPage: UInt64(usedPages - 1)).write(to: database.appending(path: "data.mdb"))
    }

    /// The two meta pages of an LMDB data file; the second is the newer.
    static func lmdbFile(mapSize: UInt64, pageSize: UInt32, lastPage: UInt64) -> Data {
        var data = Data(count: Int(pageSize) * 2)
        func put<T: FixedWidthInteger>(_ value: T, at offset: Int) {
            withUnsafeBytes(of: value.littleEndian) { data.replaceSubrange(offset..<(offset + MemoryLayout<T>.size), with: $0) }
        }
        for (page, txnid) in [(0, UInt64(7)), (1, UInt64(8))] {
            let meta = page * Int(pageSize) + 16
            put(UInt32(0xBEEF_C0DE), at: meta)
            put(UInt32(1), at: meta + 4)
            put(mapSize, at: meta + 16)
            put(pageSize, at: meta + 24)
            put(page == 1 ? lastPage : lastPage / 2, at: meta + 120)
            put(txnid, at: meta + 128)
        }
        return data
    }

    private var cacheExists: Bool { FileManager.default.fileExists(atPath: cache.directory.path(percentEncoded: false)) }

    private func launch(stamp: String = "r2", siblings: Bool = false, mayReset: Bool = true) -> MetalShaderCache.LaunchOutcome {
        cache.prepareForLaunch(lock: MetalShaderCacheLock(), stamp: stamp, mayReset: mayReset) { siblings }
    }

    // MARK: - Revisions

    func testARevisionChangeClearsTheCacheOnce() throws {
        try fillCache()
        XCTAssertEqual(launch(stamp: "r1"), .reset(.revisionChanged(from: nil)), "no stamp yet: built by an unknown revision")
        XCTAssertFalse(cacheExists)

        try fillCache()
        XCTAssertEqual(launch(stamp: "r1"), .kept, "the same revisions keep what Metal cached")
        XCTAssertTrue(cacheExists)

        XCTAssertEqual(launch(stamp: "r2"), .reset(.revisionChanged(from: "r1")))
        XCTAssertFalse(cacheExists)
        XCTAssertEqual(try String(contentsOf: cache.stampFile, encoding: .utf8), "r2")
    }

    func testTheStampNamesBothRevisions() {
        XCTAssertTrue(MetalShaderCacheLaunch.stamp.contains("\(ShaderVariantTranslator.revision)"))
        XCTAssertTrue(MetalShaderCacheLaunch.stamp.contains("pipeline-archive \(EffectPipelineArchive.revision)"))
    }

    // MARK: - MDB_MAP_FULL

    func testAFullUsageDatabaseClearsTheCache() throws {
        try fillCache(usedPages: 30)
        XCTAssertEqual(launch(stamp: "r2"), .reset(.revisionChanged(from: nil)))
        try fillCache(usedPages: 30)
        XCTAssertEqual(launch(stamp: "r2"), .kept, "half full is fine")
        try fillCache(usedPages: 63)
        XCTAssertEqual(cache.fullUsageDatabase(), "archiveUsage.db")
        XCTAssertEqual(launch(stamp: "r2"), .reset(.usageDatabaseFull("archiveUsage.db")))
        XCTAssertFalse(cacheExists)
    }

    func testTheUsageIsReadFromTheNewerMetaPage() throws {
        let usage = try XCTUnwrap(LMDBEnvironmentUsage.parse(Self.lmdbFile(mapSize: 1 << 20, pageSize: 16384, lastPage: 62)))
        XCTAssertEqual(usage, LMDBEnvironmentUsage(mapSize: 1 << 20, pageSize: 16384, usedBytes: 63 * 16384))
        XCTAssertTrue(usage.isNearlyFull)
        XCTAssertFalse(try XCTUnwrap(LMDBEnvironmentUsage.parse(Self.lmdbFile(mapSize: 1 << 20, pageSize: 16384, lastPage: 14))).isNearlyFull)
        XCTAssertNil(LMDBEnvironmentUsage.parse(Data(count: 40000)), "not LMDB")
        XCTAssertNil(LMDBEnvironmentUsage.parse(Data(count: 10)))
    }

    // MARK: - Clear Caches

    func testClearCachesClearsItAtTheNextLaunch() throws {
        try fillCache()
        XCTAssertEqual(launch(), .reset(.revisionChanged(from: nil)))
        try fillCache()
        try cache.requestReset()
        XCTAssertEqual(launch(), .reset(.requested))
        XCTAssertFalse(cacheExists)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.requestFile.path(percentEncoded: false)), "asked once")
        try fillCache()
        XCTAssertEqual(launch(), .kept)
    }

    // MARK: - Other processes

    func testAResetWaitsWhileAnotherProcessHoldsTheCache() throws {
        try fillCache()
        // Another process's shared lock: flock locks belong to the open file, so a second
        // descriptor in this process conflicts the same way.
        let other = MetalShaderCacheLock()
        try FileManager.default.createDirectory(at: cache.container, withIntermediateDirectories: true)
        XCTAssertTrue(other.open(cache.lockFile))
        other.share()
        XCTAssertEqual(launch(), .deferred(.revisionChanged(from: nil)))
        XCTAssertTrue(cacheExists)

        XCTAssertEqual(launch(siblings: true), .deferred(.revisionChanged(from: nil)), "an older build may share it")
        withExtendedLifetime(other) {}
    }

    func testAnOlderBuildRunningDefersTheReset() throws {
        try fillCache()
        XCTAssertEqual(launch(siblings: true), .deferred(.revisionChanged(from: nil)))
        XCTAssertTrue(cacheExists)
        XCTAssertEqual(launch(), .reset(.revisionChanged(from: nil)), "the next launch catches up")
    }

    func testAHelperRunOnlyTakesTheLock() throws {
        try fillCache()
        XCTAssertEqual(launch(mayReset: false), .kept)
        XCTAssertTrue(cacheExists)
    }

    func testTheHolderKeepsOthersFromResetting() throws {
        try fillCache()
        let holder = MetalShaderCacheLock()
        XCTAssertEqual(cache.prepareForLaunch(lock: holder, stamp: "r1") { false }, .reset(.revisionChanged(from: nil)))
        try fillCache()
        XCTAssertEqual(launch(stamp: "r2"), .deferred(.revisionChanged(from: "r1")), "the first process still runs")
        withExtendedLifetime(holder) {}
    }
}
