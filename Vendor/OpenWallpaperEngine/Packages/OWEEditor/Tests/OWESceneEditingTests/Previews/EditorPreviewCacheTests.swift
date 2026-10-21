import XCTest
@testable import OWESceneEditing

/// The previews' cache: one file per subject, in a folder per WE assets build and revision;
/// another build's previews are removed, so an assets update renders them again.
final class EditorPreviewCacheTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = try Fixtures.temporaryDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch) // Optional: a scratch folder.
    }

    // MARK: Keys

    func testEachSubjectHasItsOwnStableName() {
        let tint = EditorPreviewSubject.effect(file: "effects/tint/effect.json", wallpaper: nil)
        XCTAssertEqual(tint.cacheName, EditorPreviewSubject.effect(file: "effects/tint/effect.json", wallpaper: nil).cacheName)
        XCTAssertTrue(tint.cacheName.hasPrefix("effect-tint-"), tint.cacheName)
        let subjects: [EditorPreviewSubject] = [
            tint,
            .effect(file: "effects/tint/effect.json", wallpaper: "/wallpapers/1"),
            .effect(file: "effects/tint/effect.json", wallpaper: "/wallpapers/2"),
            .effect(file: "effects/workshop/1/tint/effect.json", wallpaper: "/wallpapers/1"),
            .particleSystem(path: "particles/example.json", is3D: false),
            .particleSystem(path: "particles/example3d.json", is3D: true),
            .particlePreset(directory: "/assets/presets/rain", variant: 0, is3D: false),
            .particlePreset(directory: "/assets/presets/rain", variant: 1, is3D: false),
        ]
        XCTAssertEqual(Set(subjects.map(\.cacheName)).count, subjects.count,
                       "a Workshop effect is keyed by the wallpaper shipping it, a variant by its index")
        for subject in subjects {
            XCTAssertNil(subject.cacheName.rangeOfCharacter(from: CharacterSet(charactersIn: "/: ")), subject.cacheName)
        }
        XCTAssertEqual(EditorPreviewSubject.particlePreset(directory: "/a/presets/rain", variant: 0, is3D: false).cacheName,
                       EditorPreviewSubject.particlePreset(directory: "/b/presets/rain", variant: 0, is3D: false).cacheName,
                       "a preset is WE's: its name keys it wherever the assets are")
        XCTAssertFalse(tint.isParticle)
        XCTAssertTrue(EditorPreviewSubject.particleSystem(path: "particles/example.json", is3D: false).isParticle)
    }

    func testPreviewsAreKeyedByTheAssetsBuildAndRevision() {
        let cache = EditorPreviewCache(cachesDirectory: scratch, build: "steam-23967692")
        XCTAssertEqual(cache.root, scratch.appending(path: "EditorPreviews", directoryHint: .isDirectory))
        XCTAssertEqual(cache.directory.lastPathComponent, "steam-23967692-r\(EditorPreviewCache.revision)")
        let subject = EditorPreviewSubject.effect(file: "effects/tint/effect.json", wallpaper: nil)
        XCTAssertEqual(cache.outputBase(for: subject).deletingLastPathComponent().standardizedFileURL,
                       cache.directory.standardizedFileURL)
        let other = EditorPreviewCache(cachesDirectory: scratch, build: "steam-1")
        XCTAssertNotEqual(cache.outputBase(for: subject), other.outputBase(for: subject))
    }

    func testACachedPreviewIsFoundAsAStillOrALoop() throws {
        let cache = EditorPreviewCache(cachesDirectory: scratch, build: "steam-7")
        let still = EditorPreviewSubject.effect(file: "effects/tint/effect.json", wallpaper: nil)
        let loop = EditorPreviewSubject.particleSystem(path: "particles/example.json", is3D: false)
        XCTAssertNil(cache.cachedPreview(for: still))
        try FileManager.default.createDirectory(at: cache.directory, withIntermediateDirectories: true)
        try Data("heic".utf8).write(to: cache.outputBase(for: still).appendingPathExtension("heic"))
        try Data("mov".utf8).write(to: cache.outputBase(for: loop).appendingPathExtension("mov"))
        XCTAssertEqual(cache.cachedPreview(for: still)?.pathExtension, "heic")
        XCTAssertEqual(cache.cachedPreview(for: loop)?.pathExtension, "mov")
        XCTAssertNil(EditorPreviewCache(cachesDirectory: scratch, build: "steam-8").cachedPreview(for: still),
                     "another build's previews aren't this build's")
    }

    func testAnAssetsUpdateRemovesTheOldBuildsPreviews() throws {
        let old = EditorPreviewCache(cachesDirectory: scratch, build: "steam-7")
        let subject = EditorPreviewSubject.effect(file: "effects/tint/effect.json", wallpaper: nil)
        try FileManager.default.createDirectory(at: old.directory, withIntermediateDirectories: true)
        try Data("heic".utf8).write(to: old.outputBase(for: subject).appendingPathExtension("heic"))
        try old.prune()
        XCTAssertNotNil(old.cachedPreview(for: subject), "pruning keeps the build's own previews")

        let new = EditorPreviewCache(cachesDirectory: scratch, build: "steam-8")
        try new.prune()
        XCTAssertNil(old.cachedPreview(for: subject))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.directory.path(percentEncoded: false)))
        XCTAssertNil(new.cachedPreview(for: subject), "rendered again for the new build")
        try EditorPreviewCache(cachesDirectory: scratch.appending(path: "nothing"), build: "x").prune()
    }

    // MARK: The assets build

    func testTheBuildIsReadFromTheAppsCopy() throws {
        let assets = scratch.appending(path: ".owe-assets", directoryHint: .isDirectory)
        try write(#"{"origin": "steam", "installedAt": "2026-09-29T18:17:11Z", "steamBuildID": "23967692"}"#,
                  to: ".owe-assets-info.json", in: assets)
        XCTAssertEqual(EditorPreviewCache.assetsBuild(of: assets), "steam-23967692")
    }

    func testTheBuildIsReadFromTheCICopy() throws {
        let destination = scratch.appending(path: "owe-we-assets", directoryHint: .isDirectory)
        try write("20112233\n", to: ".build", in: destination)
        try write("{}", to: "assets/effects/tint/effect.json", in: destination)
        XCTAssertEqual(EditorPreviewCache.assetsBuild(of: destination.appending(path: "assets")), "steam-20112233")
    }

    func testTheBuildIsReadFromASteamInstall() throws {
        let steamapps = scratch.appending(path: "steamapps", directoryHint: .isDirectory)
        try write("\"AppState\"\n{\n\t\"appid\"\t\t\"431960\"\n\t\"buildid\"\t\t\"555\"\n}\n", to: "appmanifest_431960.acf", in: steamapps)
        try write(#"{"version": "2.8.42"}"#, to: "common/wallpaper_engine/version.json", in: steamapps)
        let assets = steamapps.appending(path: "common/wallpaper_engine/assets")
        XCTAssertEqual(EditorPreviewCache.assetsBuild(of: assets), "steam-555")
        try FileManager.default.removeItem(at: steamapps.appending(path: "appmanifest_431960.acf"))
        XCTAssertEqual(EditorPreviewCache.assetsBuild(of: assets), "we-2.8.42", "an install outside Steam: WE's version")
    }

    func testAFolderWithoutABuildIsKeyedByItsFolders() throws {
        let assets = scratch.appending(path: "assets", directoryHint: .isDirectory)
        try write("{}", to: "effects/tint/effect.json", in: assets)
        let first = EditorPreviewCache.assetsBuild(of: assets)
        XCTAssertTrue(first.hasPrefix("files-"), first)
        XCTAssertEqual(EditorPreviewCache.assetsBuild(of: assets), first, "stable")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)],
                                              ofItemAtPath: assets.appending(path: "effects").path(percentEncoded: false))
        XCTAssertNotEqual(EditorPreviewCache.assetsBuild(of: assets), first, "a changed folder is another build")
    }

    private func write(_ text: String, to path: String, in root: URL) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
}
