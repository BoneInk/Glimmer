import XCTest
import AppKit
@testable import OpenWallpaperEngine

/// Copies of one particle definition share its built parts within a build
/// (`ParticleDefinitionCache`): the content must equal building every copy in full, and a copy
/// whose overrides change the build gets parts of its own.
final class ParticleDefinitionCacheTests: XCTestCase {
    // MARK: - Cache

    private func parts(_ blending: String) throws -> ParticleSharedParts {
        let material = try JSONDecoder().decode(WEMaterial.self, from: Data(#"{"passes":[{"blending":"\#(blending)"}]}"#.utf8))
        return ParticleSharedParts(material: material, source: .image(NSImage()), spriteSheet: nil, materialPlan: nil,
                                   fallbackSource: nil, rendererMaterials: [])
    }

    func testEachKeyIsBuiltOnceAndItsReadsAreLinkedToEveryCopy() throws {
        let cache = ParticleDefinitionCache()
        let plain = ParticleDefinitionCache.Key(particlePath: "particles/a.json", materialPath: "materials/a.json", blending: nil)
        let additive = ParticleDefinitionCache.Key(particlePath: "particles/a.json", materialPath: "materials/a.json",
                                                   blending: "additive")
        var builds = 0
        var noted: [Set<String>] = []
        for key in [plain, plain, additive, plain, additive] {
            let built = cache.parts(for: key, noteReads: { noted.append($0) }) {
                builds += 1
                return (try? self.parts(key.blending ?? "translucent"), ["materials/a.json"])
            }
            XCTAssertEqual(built?.material.passes?.first?.blending, key.blending ?? "translucent")
        }
        XCTAssertEqual(builds, 2, "one build per definition, material and blending")
        XCTAssertEqual(cache.count, 2)
        XCTAssertEqual(noted, Array(repeating: ["materials/a.json"], count: 3), "every reuse owns what the build read")
        XCTAssertEqual(cache.timing.built, 2)
        XCTAssertEqual(cache.timing.reused, 3)
    }

    func testADefinitionThatCantDrawIsSkippedForEveryCopy() {
        let cache = ParticleDefinitionCache()
        let key = ParticleDefinitionCache.Key(particlePath: "particles/a.json", materialPath: "materials/a.json", blending: nil)
        var builds = 0
        for _ in 0..<3 {
            XCTAssertNil(cache.parts(for: key, noteReads: { _ in }) { builds += 1; return (nil, []) })
        }
        XCTAssertEqual(builds, 1)
    }

    func testWithoutSharingEveryCopyIsBuilt() {
        let cache = ParticleDefinitionCache(sharesParts: false)
        let key = ParticleDefinitionCache.Key(particlePath: "particles/a.json", materialPath: "materials/a.json", blending: nil)
        var builds = 0
        for _ in 0..<3 { _ = cache.parts(for: key, noteReads: { _ in XCTFail("nothing is reused") }) { builds += 1; return (nil, []) } }
        XCTAssertEqual(builds, 3)
        XCTAssertEqual(cache.count, 0)
    }

    func testCapturedReadsNest() {
        let table = UserPropertyBindingTable()
        let document = Data(#"{"value":{"user":"speed","value":1}}"#.utf8)
        let (inner, outer) = table.capturingReads { () -> Set<String> in
            _ = table.resolvedData(document, path: "a.json", properties: { _ in nil })
            let (_, inner) = table.capturingReads {
                _ = table.resolvedData(document, path: "b.json", properties: { _ in nil })
            }
            return inner
        }
        XCTAssertEqual(inner, ["b.json"])
        XCTAssertEqual(outer, ["a.json", "b.json"])
    }

    // MARK: - Scene

    /// What a built system draws and simulates with, as far as the build decides it.
    private struct Built: Equatable {
        let objectID: String?
        let order: Int
        let parent: Int?
        let origin: SIMD2<Float>
        let emissionRate: Float
        let maximumParticleCount: Int
        let emitter: ParticleEmitterShape
        let controlPoints: [ParticleControlPoint]
        let overrides: SceneParticleOverrides
        let blending: String
        let operators: Int
        let initializers: Int
        let hasSpriteSheet: Bool
        let hasFallback: Bool
        let material: [String]
        let renderers: [[String]]

        init(_ system: SceneMetalParticleSystem) {
            objectID = system.objectID
            order = system.order
            parent = system.link?.parentIndex
            origin = system.origin
            emissionRate = system.emissionRate
            maximumParticleCount = system.maximumParticleCount
            emitter = system.emitter
            controlPoints = system.controlPoints
            overrides = system.overrides
            blending = system.blending
            operators = system.program.operators.count
            initializers = system.program.initializers.count
            hasSpriteSheet = system.spriteSheet != nil
            hasFallback = system.fallbackSource != nil
            material = Self.describe(system.material)
            renderers = system.additionalRenderers.map { Self.describe($0.material) }
        }

        static func describe(_ plan: ParticleMaterialPlan?) -> [String] {
            guard let plan else { return ["built-in"] }
            return [plan.materialPath, plan.shader, plan.blending] + plan.stages.flatMap { stage in
                [stage.variantKey] + stage.textures.keys.sorted().map { slot -> String in
                    if case .asset(let key, _) = stage.textures[slot] { return "\(slot): \(key)" }
                    return "\(slot): \(String(describing: stage.textures[slot]))"
                }
            }
        }
    }

    private func model() throws -> SceneContentLoader {
        let directory = Fixtures.url("Scenes/particle-copies")
        let project = try JSONDecoder().decode(WEProject.self, from: Fixtures.data("Scenes/particle-copies/project.json"))
        addTeardownBlock { Fixtures.removeStoredSettings(for: directory) }
        return SceneContentLoader(wallpaper: WEWallpaper(using: project, where: directory))
    }

    private func built(sharing: Bool, edits: [String: String] = [:]) throws -> [Built] {
        let model = try model()
        model.sharesParticleDefinitions = sharing
        if !edits.isEmpty {
            let store = model.propertyStoreKey
            WallpaperServices.shared.setUserProperties(edits, wallpaper: store, replacing: false)
            addTeardownBlock { WallpaperServices.shared.setUserProperties([:], wallpaper: store, replacing: true) }
        }
        return try XCTUnwrap(model.metalContent()).particleSystems.map(Built.init)
    }

    func testCopiesSharingTheirDefinitionBuildWhatEachCopyBuildsAlone() throws {
        _ = try Fixtures.assets()
        let shared = try built(sharing: true)
        let alone = try built(sharing: false)
        XCTAssertEqual(shared.count, 9, "four sparks with their glow, and a glow of its own")
        XCTAssertEqual(shared, alone)
        // Each copy keeps its own transform and overrides.
        XCTAssertEqual(Set(shared.filter { $0.objectID != nil }.map(\.origin.x)).count, 5)
        XCTAssertNotEqual(shared[0].overrides, shared[2].overrides)
        XCTAssertEqual(shared[0].material, shared[2].material, "the copies draw through one material")
        XCTAssertEqual(shared[0].renderers.count, 1, "the spark's trail renderer")
    }

    func testACopyWhoseBlendingIsEditedGetsItsOwnParts() throws {
        _ = try Fixtures.assets()
        let edits = [sceneObjectBlendingKey(objectID: 4): "translucent"]
        let shared = try built(sharing: true, edits: edits)
        let alone = try built(sharing: false, edits: edits)
        XCTAssertEqual(shared, alone)
        let sparks = shared.filter { $0.objectID != nil && $0.objectID != "5" }
        XCTAssertEqual(sparks.map(\.blending), ["additive", "additive", "additive", "translucent"])
        if sparks[3].material != ["built-in"] {
            XCTAssertNotEqual(sparks[3].material, sparks[0].material)
        }
        // Its child keeps its material's blending, as every other glow does.
        let glows = shared.filter { $0.objectID == nil }
        XCTAssertEqual(Set(glows.map(\.blending)), ["additive"])
    }
}
