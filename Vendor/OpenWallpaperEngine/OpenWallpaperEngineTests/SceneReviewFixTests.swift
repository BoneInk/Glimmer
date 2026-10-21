import XCTest
import simd
@testable import OpenWallpaperEngine

/// Area 8 review fixes on the loading side: stable caches, visibility fallbacks, object ids,
/// particle emitter space, change impact and music-synced effect overrides.
final class SceneReviewFixTests: XCTestCase {
    // MARK: Scene audio cache

    func testSceneAudioCacheNameIsStableAndPerWallpaper() {
        let a = URL(fileURLWithPath: "/w/a"), b = URL(fileURLWithPath: "/w/b")
        let day = Date(timeIntervalSinceReferenceDate: 86_400)
        let name = SceneSoundContentBuilder.cacheName(entry: "sounds/music.mp3", wallpaperDirectory: a, size: 3, modified: day)
        XCTAssertEqual(name, SceneSoundContentBuilder.cacheName(entry: "sounds/music.mp3", wallpaperDirectory: a, size: 3, modified: day))
        XCTAssertNotEqual(name, SceneSoundContentBuilder.cacheName(entry: "sounds/music.mp3", wallpaperDirectory: b, size: 3, modified: day))
        XCTAssertNotEqual(name, SceneSoundContentBuilder.cacheName(entry: "sounds/music.mp3", wallpaperDirectory: a,
                                                                   size: 3, modified: day.addingTimeInterval(1)), "an updated package gets a new copy")
        XCTAssertTrue(name.hasSuffix(".mp3"))
        XCTAssertEqual(name.count, 64 + 4, "SHA256 hex plus extension")
        // Deterministic and seed-free: a fixed input gives a fixed name, so it can't come from `hashValue`.
        XCTAssertEqual(SceneSoundContentBuilder.cacheName(entry: "a.ogg", wallpaperDirectory: nil, size: 0, modified: nil),
                       SceneSoundContentBuilder.cacheName(entry: "a.ogg", wallpaperDirectory: nil, size: 0, modified: nil))
        XCTAssertTrue(SceneSoundContentBuilder.isCurrentCacheName(name))
        XCTAssertFalse(SceneSoundContentBuilder.isCurrentCacheName("-4611686018427387904.mp3"))
    }

    func testSceneAudioCacheNameFollowsALooseSourceFile() throws {
        // A converted wallpaper has no scene.pkg: its key comes from the file the bytes are read from.
        let dir = FileManager.default.temporaryDirectory.appending(path: "owe-audio-src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appending(path: "music.mp3")
        try Data(count: 10).write(to: source)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceReferenceDate: 1000)],
                                              ofItemAtPath: source.path)
        let name = { SceneSoundContentBuilder.cacheName(entry: "sounds/music.mp3", wallpaperDirectory: dir,
                                                        source: source, fallbackSize: 0) }
        let first = name()
        XCTAssertEqual(first, name(), "an unchanged file keeps its copy")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceReferenceDate: 2000)],
                                              ofItemAtPath: source.path)
        XCTAssertNotEqual(first, name(), "a touched file gets a new copy")
        let touched = name()
        try Data(count: 11).write(to: source)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceReferenceDate: 2000)],
                                              ofItemAtPath: source.path)
        XCTAssertNotEqual(touched, name(), "a resized file gets a new copy")
    }

    func testSceneAudioCacheDropsOldNamesOnceAndKeepsUnderItsCap() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "owe-audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func write(_ name: String, bytes: Int, age: TimeInterval) throws -> URL {
            let url = dir.appending(path: name)
            try Data(count: bytes).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: url.path)
            return url
        }
        let legacy = try write("1234567890.mp3", bytes: 10, age: 0)
        let oldest = try write(String(repeating: "a", count: 64) + ".mp3", bytes: 100, age: 300)
        let middle = try write(String(repeating: "b", count: 64) + ".mp3", bytes: 100, age: 200)
        let newest = try write(String(repeating: "c", count: 64) + ".mp3", bytes: 100, age: 100)
        SceneSoundContentBuilder.prune(dir, byteLimit: 250, keeping: newest)
        let exists = { (url: URL) in FileManager.default.fileExists(atPath: url.path) }
        XCTAssertFalse(exists(legacy), "the old per-launch names are swept")
        XCTAssertFalse(exists(oldest), "least recently used goes first")
        XCTAssertTrue(exists(middle))
        XCTAssertTrue(exists(newest))
        // The sweep runs once: a later odd name is left alone.
        let later = try write("99.mp3", bytes: 1, age: 0)
        SceneSoundContentBuilder.prune(dir, byteLimit: 1 << 20)
        XCTAssertTrue(exists(later))
    }

    // MARK: Effect visibility

    private func effect(_ json: String) throws -> WEObjectEffect {
        try JSONDecoder().decode(WEObjectEffect.self, from: Data(json.utf8))
    }

    func testEffectBoundToMissingPropertyKeepsAuthoredVisibility() throws {
        let shown = try effect(#"{"file":"e.json","visible":{"user":"toggle","value":true}}"#)
        let hidden = try effect(#"{"file":"e.json","visible":{"user":"toggle","value":false}}"#)
        XCTAssertTrue(SceneContentLoader.isEffectVisible(shown, userProperty: { _ in nil }))
        XCTAssertFalse(SceneContentLoader.isEffectVisible(hidden, userProperty: { _ in nil }))
        XCTAssertFalse(SceneContentLoader.isEffectVisible(shown, userProperty: { _ in "false" }))
        XCTAssertTrue(SceneContentLoader.isEffectVisible(hidden, userProperty: { _ in "true" }))
    }

    // MARK: Object ids

    func testObjectsWithoutIDUseTheHierarchyFallback() throws {
        let objects = try JSONDecoder().decode([WESceneObject].self,
                                               from: Data(#"[{"id": 7}, {"name": "x"}, {"id": 3}]"#.utf8))
        let keyed = SceneObjectIdentity.assigningFallbackIDs(objects)
        XCTAssertEqual(keyed.map(\.id), [7, 1, 3])
        let hierarchy = SceneTransformHierarchy(objects: objects)
        for object in keyed {
            XCTAssertNotNil(hierarchy.nodes[String(object.id!)], "layer id matches a hierarchy node")
        }
    }

    // MARK: Particle emitter space

    func testEmitterSpaceIncludesParentScaleAndRotation() throws {
        let objects = try JSONDecoder().decode([WESceneObject].self, from: Data(#"""
        [{"id": 1, "origin": "100 100 0", "scale": "2 2 1", "angles": "0 0 1.5707963"},
         {"id": 2, "parent": 1, "origin": "10 0 0", "particle": "p.json"}]
        """#.utf8))
        let hierarchy = SceneTransformHierarchy(objects: objects)
        let space = SceneParticleEmitterSpace(world: hierarchy.world(of: "2"))
        XCTAssertEqual(simd_length(space.origin - SIMD2(100, 100)), 20, accuracy: 1e-3,
                       "child offset is scaled by the parent")
        XCTAssertEqual(space.extent(SIMD2(5, 5)), SIMD2(10, 10))
        let rotated = space.offset(SIMD2(1, 0))
        XCTAssertEqual(simd_length(rotated), 2, accuracy: 1e-4)
        XCTAssertEqual(abs(rotated.x), 0, accuracy: 1e-4, "a quarter turn moves x onto y")
    }

    // MARK: Change impact

    func testParallaxAndEffectMusicSyncImpact() {
        XCTAssertEqual(SceneChangeImpact.impact(of: "_owe_effect_enabled_parallax"), .none)
        XCTAssertEqual(SceneChangeImpact.impact(of: "_owe_effect_parallax_amount"), .none)
        XCTAssertEqual(SceneChangeImpact.impact(of: "_owe_authored_effect_1_0_strength_musicSync"), .rebuildContent)
        XCTAssertEqual(SceneChangeImpact.impact(of: "_owe_authored_effect_1_0_strength_musicAmount"), .none)
        XCTAssertEqual(SceneChangeImpact.impact(of: "speed_musicSync"), .none)
    }

    // MARK: Effect overrides and music sync

    func testStoredOverrideDetectsScalarAndComponentSync() {
        let store = ["p": "0.4", "p_musicSync": "true", "v": "1 2 3", "v_1_musicSync": "true", "q": "1"]
        XCTAssertEqual(SceneEffectOverride.stored(property: "p", lookup: { store[$0] }),
                       SceneEffectOverride(property: "p", value: "0.4", isMusicSynced: true))
        XCTAssertEqual(SceneEffectOverride.stored(property: "v", lookup: { store[$0] })?.isMusicSynced, true)
        XCTAssertEqual(SceneEffectOverride.stored(property: "q", lookup: { store[$0] })?.isMusicSynced, false)
        XCTAssertNil(SceneEffectOverride.stored(property: "missing", lookup: { store[$0] }))
    }

    func testSyncedOverrideBindsToItsProperty() {
        let uniform = ShaderUniformDeclaration(type: "float", name: "g_Amp", arrayCount: nil,
                                               annotation: ["material": "strength"])
        let synced = SceneEffectPlanBuilder.applyingOverrides(
            { _ in SceneEffectOverride(property: "p", value: "0.4", isMusicSynced: true) },
            to: ["strength": .literal(ShaderValue(0.2))], uniforms: [uniform])
        XCTAssertEqual(synced["strength"], .user(name: "p", condition: nil, fallback: .literal(ShaderValue(0.4))))
        let plain = SceneEffectPlanBuilder.applyingOverrides(
            { _ in SceneEffectOverride(property: "p", value: "0.4") },
            to: [:], uniforms: [uniform])
        XCTAssertEqual(plain["strength"], .literal(ShaderValue(0.4)))
    }

    /// Risk #22: with no audio (capture denied, stopped or asleep, which resets the level to 0)
    /// a music-synced override reads as the value the user set, not a frozen modulation.
    func testSyncedOverrideFallsBackToItsValueWithoutAudio() {
        let engine = WallpaperServices.shared
        let wallpaper = "/tests/\(UUID().uuidString)"
        engine.setUserProperties(["p": "0.4", "p_musicSync": "true", "p_musicAmount": "1"], wallpaper: wallpaper, replacing: true)
        engine.beginFrame(wallpaper: wallpaper)
        defer { engine.endFrame() }
        XCTAssertEqual(engine.audioLevel, 0)
        XCTAssertTrue(engine.isMusicSynced("p"))
        XCTAssertEqual(LiveSceneValueContext(engine: engine).userProperty("p").flatMap(Float.init), 0.4)
        XCTAssertEqual(engine.userPropertyValue("p", fallback: 0.4), 0.4)
    }

    func testMusicSyncModulatesScalarsAndComponents() {
        let modulate: (String, Float) -> Float = { _, base in base + 1 }
        XCTAssertEqual(LiveSceneValueContext.musicSynced("0.5", name: "p", isSynced: { $0 == "p" }, modulate: modulate), "1.5")
        XCTAssertEqual(LiveSceneValueContext.musicSynced("0.5", name: "p", isSynced: { _ in false }, modulate: modulate), "0.5")
        XCTAssertEqual(LiveSceneValueContext.musicSynced("1 2 3", name: "v", isSynced: { $0 == "v_1" }, modulate: modulate),
                       "1.0 3.0 3.0")
        XCTAssertEqual(LiveSceneValueContext.musicSynced("abc", name: "p", isSynced: { _ in true }, modulate: modulate), "abc")
    }
}
