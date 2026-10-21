import XCTest
@testable import OWESceneEditing

/// The effect and particle browsers list everything an asset tree has: every built-in effect, and
/// every default particle system and particle preset variant, grouped as WE's editor groups them.
final class EditorCatalogCompletenessTests: XCTestCase {
    private var assets: URL!

    override func setUpWithError() throws {
        assets = try EditorPreviewFixtures.assetsTree()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: assets.deletingLastPathComponent()) // Optional: a scratch folder.
    }

    private let labels = [
        "ui_rain": "Rain", "ui_rain_description": "Adds rain.", "ui_rain_1": "Perspective", "ui_rain_2": "Downpour",
        "ui_water": "Water", "ui_editor_particle_example_basic": "Basic",
        "ui_editor_particle_example_cursor_follow": "Follow cursor", "ui_editor_particle_example_turbulence": "Turbulence",
    ]

    func testEveryBuiltInEffectIsListed() {
        let files = EffectCatalog.builtInEffectFiles(in: assets)
        XCTAssertEqual(files, EditorPreviewFixtures.effects.map { "effects/\($0)/effect.json" },
                       "every effect folder with an effect.json, but WE's internal `_empty`")
    }

    func testEveryParticleSystemAndPresetVariantIsListed() throws {
        let catalog = ParticleCatalog.load(assetsDirectory: assets, translate: { self.labels[$0] })
        XCTAssertTrue(catalog.hasPresets)
        let systems = catalog.items.compactMap { item -> String? in
            if case .system(let path) = item.source { return path }
            return nil
        }
        XCTAssertEqual(Set(systems), ["particles/example.json", "particles/examplecursorfollow.json",
                                      "particles/examplecursoravoid.json", "particles/exampleturbolence.json",
                                      "particles/example3d.json", "particles/exampleturbolence3d.json",
                                      "particles/sparkle.json"], "every file of particles/")
        let variants = catalog.items.compactMap { item -> String? in
            if case .preset(let preset, let variant) = item.source { return "\(preset.id)/\(variant.id)" }
            return nil
        }
        XCTAssertEqual(Set(variants), ["rain/0", "rain/1", "water/0"],
                       "every particle variant; the water preset's trailing commas are read as WE reads them; text presets aren't particle systems")
        XCTAssertEqual(catalog.items.count, 10)

        let basic = try XCTUnwrap(catalog.items.first { $0.id == "system:particles/example.json" })
        XCTAssertEqual(basic.title, "Basic")
        XCTAssertFalse(basic.is3D)
        XCTAssertEqual(catalog.items.first { $0.id == "system:particles/example3d.json" }?.is3D, true)
        XCTAssertEqual(catalog.items.first { $0.id == "system:particles/examplecursoravoid.json" }?.title, "Examplecursoravoid",
                       "an untranslated label falls back to the file's name")
        XCTAssertEqual(catalog.items.first { $0.id == "system:particles/sparkle.json" }?.group.kind, .systems(is3D: false))
        let downpour = try XCTUnwrap(catalog.items.first { $0.id == "preset:rain/1" })
        XCTAssertEqual(downpour.title, "Downpour")
        XCTAssertEqual(downpour.group.title, "Rain")
        XCTAssertEqual(downpour.summary, "Adds rain.")
    }

    func testGroupsFollowWEsEditor() {
        let catalog = ParticleCatalog.load(assetsDirectory: assets, translate: { self.labels[$0] })
        let groups = ParticleCatalog.grouped(catalog.items, sceneIs3D: false)
        XCTAssertEqual(groups.map(\.group.kind), [.systems(is3D: false), .preset("rain"), .preset("water"), .systems(is3D: true)],
                       "the scene's own default systems, the presets by title, then the other kind's systems")
        XCTAssertEqual(groups.first?.items.first?.id, "system:particles/example.json", "WE's order")
        XCTAssertEqual(ParticleCatalog.grouped(catalog.items, sceneIs3D: true).first?.group.kind, .systems(is3D: true))
    }

    func testSearchMatchesTitlesSummariesAndGroups() {
        let catalog = ParticleCatalog.load(assetsDirectory: assets, translate: { self.labels[$0] })
        XCTAssertEqual(ParticleCatalog.filter(catalog.items, query: "rain").map(\.id), ["preset:rain/0", "preset:rain/1"])
        XCTAssertEqual(ParticleCatalog.filter(catalog.items, query: "RAIN down").map(\.id), ["preset:rain/1"])
        XCTAssertEqual(ParticleCatalog.filter(catalog.items, query: "").count, catalog.items.count)
        XCTAssertTrue(ParticleCatalog.filter(catalog.items, query: "nothing").isEmpty)
    }

    func testACopyWithoutPresetsSaysSo() throws {
        try FileManager.default.removeItem(at: assets.appending(path: "presets"))
        let catalog = ParticleCatalog.load(assetsDirectory: assets, translate: { _ in nil })
        XCTAssertFalse(catalog.hasPresets)
        XCTAssertEqual(catalog.items.count, 7, "the default systems are still listed")
    }

    func testNoAssetsListNothing() throws {
        let empty = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: empty) } // Optional: a scratch folder.
        XCTAssertTrue(EffectCatalog.builtInEffectFiles(in: empty).isEmpty)
        let catalog = ParticleCatalog.load(assetsDirectory: empty, translate: { _ in nil })
        XCTAssertTrue(catalog.items.isEmpty)
        XCTAssertFalse(catalog.hasPresets)
    }
}
