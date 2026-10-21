import XCTest
@testable import OpenWallpaperEngine

/// Risk #19: the app ships no WE assets. They come from a chosen WE install, else the cache in the
/// Wallpaper Storage folder, else nowhere; tests only ever use `OWE_ASSETS`.
final class WallpaperEngineAssetsTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appending(path: "owe-assets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch) // scratch cleanup
    }

    private func write(_ text: String, to path: String, in directory: URL) throws {
        let url = directory.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// A minimal asset tree: what `isAssetTree` looks for.
    private func makeTree(_ directory: URL) throws {
        try write("x", to: "shaders/common.h", in: directory)
        try write("{}", to: "effects/tint/effect.json", in: directory)
    }

    func testTheAppBundlesNoAssets() {
        XCTAssertNil(Bundle.main.url(forResource: "we-assets", withExtension: nil))
    }

    /// A chosen install wins over the cache; an install root and its `assets` folder both work.
    func testAChosenInstallComesBeforeTheCache() throws {
        let install = scratch.appending(path: "wallpaper_engine"), storage = scratch.appending(path: "storage")
        try makeTree(install.appending(path: "assets"))
        try makeTree(WallpaperEngineAssets.cacheDirectory(in: storage))
        let chosen = WallpaperEngineAssets.resolve(chosenPath: install.path, storage: storage, testOverride: nil, isTesting: false)
        XCTAssertEqual(chosen?.source, .chosenFolder)
        XCTAssertEqual(chosen?.directory.path, install.appending(path: "assets").standardizedFileURL.path)
        let assetsFolder = WallpaperEngineAssets.resolve(chosenPath: install.appending(path: "assets").path, storage: nil,
                                                         testOverride: nil, isTesting: false)
        XCTAssertEqual(assetsFolder?.directory.path, chosen?.directory.path)
    }

    /// A chosen folder that isn't an install (or is gone) falls back to the cache, then to none.
    func testTheCacheIsNextAndThenNothing() throws {
        let storage = scratch.appending(path: "storage")
        let missing = scratch.appending(path: "gone").path
        XCTAssertNil(WallpaperEngineAssets.resolve(chosenPath: missing, storage: storage, testOverride: nil, isTesting: false))
        try makeTree(WallpaperEngineAssets.cacheDirectory(in: storage))
        let cache = WallpaperEngineAssets.resolve(chosenPath: missing, storage: storage, testOverride: nil, isTesting: false)
        XCTAssertEqual(cache?.source, .cache)
        XCTAssertEqual(cache?.directory.lastPathComponent, ".owe-assets")
        XCTAssertEqual(cache?.directory.deletingLastPathComponent().standardizedFileURL.path, storage.standardizedFileURL.path)
    }

    /// Under XCTest only `OWE_ASSETS` counts: a developer's own install or cache never leaks in.
    func testTestsUseOnlyTheEnvironment() throws {
        let storage = scratch.appending(path: "storage"), override = scratch.appending(path: "override")
        try makeTree(WallpaperEngineAssets.cacheDirectory(in: storage))
        XCTAssertNil(WallpaperEngineAssets.resolve(chosenPath: nil, storage: storage, testOverride: nil, isTesting: true))
        try makeTree(override)
        let resolved = WallpaperEngineAssets.resolve(chosenPath: nil, storage: storage, testOverride: override.path, isTesting: true)
        XCTAssertEqual(resolved?.source, .testEnvironment)
        XCTAssertEqual(resolved?.directory.path, override.standardizedFileURL.path)
    }

    /// Without assets nothing is searched, so scenes see them as missing.
    func testMissingAssetsSearchNothing() throws {
        try XCTSkipIf(WallpaperEngineAssets.directory != nil, "OWE_ASSETS is set for this run")
        XCTAssertTrue(WallpaperEngineAssets.searchDirectories.isEmpty)
        XCTAssertNil(WallpaperEngineAssets.locate(["shaders/common.h"], in: WallpaperEngineAssets.searchDirectories))
    }

    /// A file the first directory lacks still resolves from the next.
    func testLookupFallsBackToTheNextDirectory() throws {
        let first = scratch.appending(path: "first"), second = scratch.appending(path: "second")
        try write("first", to: "shaders/both.frag", in: first)
        try write("second", to: "shaders/both.frag", in: second)
        try write("second", to: "materials/only-second.json", in: second)
        let both = try XCTUnwrap(WallpaperEngineAssets.locate(["shaders/both.frag"], in: [first, second]))
        XCTAssertEqual(try String(contentsOf: both, encoding: .utf8), "first")
        let fallback = try XCTUnwrap(WallpaperEngineAssets.locate(["only-second.json", "materials/only-second.json"],
                                                                  in: [first, second]))
        // The lookup returns the file's canonical path (links resolved, `AssetPathResolver`).
        XCTAssertEqual(fallback.resolvingSymlinksInPath().path,
                       second.appending(path: "materials/only-second.json").resolvingSymlinksInPath().path)
        XCTAssertNil(WallpaperEngineAssets.locate(["missing"], in: [first, second]))
    }
}
