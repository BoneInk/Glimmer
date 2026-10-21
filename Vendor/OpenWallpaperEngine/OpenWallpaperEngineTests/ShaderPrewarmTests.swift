import XCTest
@testable import OpenWallpaperEngine

/// The prewarm helper reads the shown and recent wallpapers from the defaults, compiles their
/// variants and pipelines into the given caches, and writes nothing to the defaults.
@MainActor
final class ShaderPrewarmTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var caches: URL!

    override func setUpWithError() throws {
        suiteName = "app.openwallpaperengine.isolated.tests.prewarm-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        caches = FileManager.default.temporaryDirectory.appending(path: "owe-prewarm-caches-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        if FileManager.default.fileExists(atPath: caches.path) { try FileManager.default.removeItem(at: caches) }
    }

    private func wallpaper(_ path: String, type: String = "scene") throws -> WEWallpaper {
        let directory = Fixtures.url(path)
        var project = try JSONDecoder().decode(WEProject.self, from: Fixtures.data("\(path)/project.json"))
        project.type = type
        return WEWallpaper(using: project, where: directory)
    }

    private func store(screens: [String: WEWallpaper], recents: [WEWallpaper], enabled: [String]? = nil) throws {
        defaults.set(try JSONEncoder().encode(screens), forKey: ShaderPrewarmTargets.screenWallpapersKey)
        defaults.set(try JSONEncoder().encode(recents), forKey: ShaderPrewarmTargets.recentWallpapersKey)
        if let enabled { defaults.set(enabled, forKey: ShaderPrewarmTargets.enabledScreensKey) }
    }

    func testTargetsAreTheEnabledDisplaysScenesThenRecentOnes() throws {
        let small = ShaderPrewarmTargets.Display(drawableSize: SIMD2(800, 600), pointSize: SIMD2(800, 600))
        let retina = ShaderPrewarmTargets.Display(drawableSize: SIMD2(3024, 1964), pointSize: SIMD2(1512, 982))
        let bloom = try wallpaper("Scenes/bloom"), hdr = try wallpaper("Scenes/hdr"), layers = try wallpaper("Scenes/layers")
        let msaa = try wallpaper("Scenes/msaa"), video = try wallpaper("Scenes/lights", type: "video")
        try store(screens: ["1": bloom, "2": hdr, "3": layers], recents: [bloom, video, msaa, layers], enabled: ["1", "3"])
        let targets = ShaderPrewarmTargets.read(from: defaults, displays: ["1": retina, "3": small], mainDisplay: "1", recentLimit: 1)
        XCTAssertEqual(targets.map(\.wallpaper.wallpaperDirectory.lastPathComponent), ["bloom", "layers", "msaa"],
                       "display 2 is off; bloom and layers aren't repeated; the video is skipped; one recent")
        XCTAssertEqual(targets.map(\.display), [retina, small, retina])
    }

    func testCompilesAFixtureSceneIntoTheGivenCachesAndWritesNoDefaults() throws {
        _ = try Fixtures.assets()
        let bloom = try wallpaper("Scenes/bloom")
        defer { Fixtures.removeStoredSettings(for: bloom.wallpaperDirectory) }
        try store(screens: ["1": bloom], recents: [bloom])
        let before = defaults.persistentDomain(forName: suiteName) as NSDictionary?
        let variants = caches.appending(path: "shader-variants", directoryHint: .isDirectory)
        let archives = caches.appending(path: "pipeline-archives", directoryHint: .isDirectory)
        let prewarm = ShaderPrewarm(defaults: defaults, variantCacheDirectory: variants, pipelineArchiveDirectory: archives)
        let display = ShaderPrewarmTargets.Display(drawableSize: SIMD2(480, 272), pointSize: SIMD2(480, 272))
        let targets = ShaderPrewarmTargets.read(from: defaults, displays: ["1": display], mainDisplay: "1", recentLimit: 5)
        XCTAssertEqual(targets.count, 1)

        let report = prewarm.run(targets)

        XCTAssertEqual(report.wallpapers, 1)
        XCTAssertEqual(report.failed, 0)
        XCTAssertEqual(report.variantsBefore, 0)
        XCTAssertGreaterThan(report.variantsAfter, 0, "WE's bloom variants were translated")
        let generation = variants.appending(path: ShaderCacheKey.current.variantGeneration)
        XCTAssertEqual(ShaderPrewarm.fileCount(in: generation), report.variantsAfter, "under this build's cache generation")
        let archiveFiles = try FileManager.default.contentsOfDirectory(atPath: archives.path)
        XCTAssertTrue(archiveFiles.contains { $0.hasSuffix("--\(EffectPipelineArchive.environmentKey).binarchive") },
                      "the pipelines were archived under this build's key: \(archiveFiles)")
        XCTAssertEqual(defaults.persistentDomain(forName: suiteName) as NSDictionary?, before, "nothing written to the defaults")

        // A second run finds everything cached.
        let again = prewarm.run(targets)
        XCTAssertEqual(again.variantsAfter, report.variantsAfter)
    }
}
