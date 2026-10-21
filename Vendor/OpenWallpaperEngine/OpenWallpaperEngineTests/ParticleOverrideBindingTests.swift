import XCTest
import Metal
import simd
@testable import OpenWallpaperEngine

private struct Properties: SceneValueContext {
    var values: [String: String] = [:]
    func userProperty(_ name: String) -> String? { values[name] }
    func evaluateScript(_ source: String, properties: SceneScriptProperties, current: ShaderValue) -> ShaderValue? { nil }
}

/// Each `instanceoverride` field bound to a user property changes the simulated particles: live
/// (a binding revision later, without a rebuild), on a fresh load, and for every copy of a
/// definition whose built parts are shared (`ParticleDefinitionCache`).
///
/// The overrides WE applies to the base values (alpha, size, lifetime, speed, colour) reach the
/// particles spawned after the change, as WE's do (§11.3 of we-values-audit notes): each test
/// runs the systems past the authored lifetime (1…2 s) before reading the GPU state back.
final class ParticleOverrideBindingTests: XCTestCase {
    private var device: MTLDevice!
    private var queue: MTLCommandQueue!
    private var texture: MTLTexture!

    override func setUpWithError() throws {
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        queue = try XCTUnwrap(device.makeCommandQueue())
        texture = try XCTUnwrap(device.makeTexture(descriptor: .texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)))
    }

    /// One field of an override bound to the user property `p` with authored value `authored`.
    private func override(_ field: String, authored: String) throws -> WEInstanceOverride {
        try JSONDecoder().decode(WEInstanceOverride.self, from: Data(#"{"\#(field)": {"user": "p", "value": "\#(authored)"}}"#.utf8))
    }

    private func base() -> SceneMetalParticleSystem {
        var system = ParticleTestSystem()
        system.emissionRate = 600
        system.maximum = 4000
        return system.configuration
    }

    /// The GPU state of `systems` after `seconds` at 60 fps, each stepped with its own properties.
    private func run(_ systems: [(ParticleSystemRuntime, Properties)], seconds: Float,
                     simulator: ParticleGPUSimulator) throws -> [[ParticleGPUState]] {
        var last: MTLCommandBuffer?
        for _ in 0..<Int(seconds * 60) {
            let requests = systems.map { runtime, properties in
                ParticleGPUSimulator.Request(system: runtime,
                                             inputs: ParticleFrameInputs.advance(runtime, deltaTime: 1 / 60, cursor: .zero,
                                                                                 values: properties),
                                             kind: .sprite, materialVertexCount: 6)
            }
            let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
            simulator.encode(requests, sceneSize: SIMD2(1280, 720), targetSize: SIMD2(1280, 720), commandBuffer: commandBuffer)
            commandBuffer.commit()
            last = commandBuffer
        }
        last?.waitUntilCompleted()
        return systems.map { simulator.snapshot($0.0, queue: queue) }
    }

    /// What a field's check reads from the particles.
    private struct Field {
        let name: String
        let authored: String
        let changed: String
        /// Holds for particles spawned with the authored value and fails for the changed one.
        let authoredHolds: ([ParticleGPUState]) -> Bool
        /// Holds for particles spawned with the changed value and fails for the authored one.
        let changedHolds: ([ParticleGPUState]) -> Bool
    }

    private static let eps: Float = 1e-3

    /// Authored: lifetime 1…2, base size 5…10 (`sizerandom` 10…20 on WE's 0.5), alpha 0.5…1,
    /// colour (0.2, 0.3, 0.4)…(0.9, 0.8, 1), speed ≤ |(40, 60)|.
    private static let fields: [Field] = [
        Field(name: "alpha", authored: "1", changed: "0.25",
              authoredHolds: { $0.allSatisfy { $0.alphaRotation.y >= 0.5 - eps } },
              changedHolds: { $0.allSatisfy { $0.alphaRotation.y <= 0.25 + eps } }),
        Field(name: "size", authored: "1", changed: "3",
              authoredHolds: { $0.allSatisfy { $0.life.w <= 10 + eps } },
              changedHolds: { $0.allSatisfy { $0.life.w >= 15 - eps } }),
        Field(name: "lifetime", authored: "1", changed: "3",
              authoredHolds: { $0.allSatisfy { $0.life.y <= 2 + eps } },
              changedHolds: { $0.allSatisfy { $0.life.y >= 3 - eps } }),
        Field(name: "colorn", authored: "1 1 1", changed: "1 0 0",
              authoredHolds: { $0.allSatisfy { $0.baseColor.y >= 0.3 - eps } },
              changedHolds: { $0.allSatisfy { $0.baseColor.y <= eps && $0.baseColor.z <= eps && $0.baseColor.x >= 0.2 - eps } }),
        Field(name: "color", authored: "255 255 255", changed: "0 0 255",
              authoredHolds: { $0.allSatisfy { $0.baseColor.x >= 0.2 - eps } },
              changedHolds: { $0.allSatisfy { $0.baseColor.x <= eps && $0.baseColor.y <= eps && $0.baseColor.z >= 0.4 - eps } }),
        Field(name: "brightness", authored: "1", changed: "3",
              authoredHolds: { $0.allSatisfy { $0.baseColor.z <= 1 + eps } },
              changedHolds: { $0.allSatisfy { $0.baseColor.z >= 1.2 - eps } }),
        Field(name: "speed", authored: "1", changed: "4",
              authoredHolds: { $0.allSatisfy { simd_length(SIMD2($0.positionVelocity.z, $0.positionVelocity.w)) <= 72.2 } },
              changedHolds: { states in
                  (states.map { simd_length(SIMD2($0.positionVelocity.z, $0.positionVelocity.w)) }.max() ?? 0) > 150
              }),
    ]

    /// Two copies of one configuration (as copies sharing a definition hold the same built parts),
    /// one of them changed live: only that one's new particles take the change.
    func testEveryBoundFieldChangesTheRunningSystemLive() throws {
        for field in Self.fields {
            var configuration = base()
            configuration.liveOverrides = try override(field.name, authored: field.authored)
            let simulator = try ParticleGPUSimulator(device: device)
            let reference = ParticleSystemRuntime(texture: texture, configuration: configuration, seed: 3)
            let edited = ParticleSystemRuntime(texture: texture, configuration: configuration, seed: 3)
            let authored = Properties(values: ["p": field.authored])
            let before = try run([(reference, authored), (edited, authored)], seconds: 0.5, simulator: simulator)
            XCTAssertFalse(before[1].isEmpty, field.name)
            XCTAssertTrue(field.authoredHolds(before[1]), "\(field.name): the authored value before the change")

            // The renderer moves the edited copy's binding revision when its property changes.
            edited.bindingRevision += 1
            let after = try run([(reference, authored), (edited, Properties(values: ["p": field.changed]))],
                                seconds: 2.5, simulator: simulator)
            XCTAssertFalse(after[1].isEmpty, field.name)
            XCTAssertTrue(field.authoredHolds(after[0]), "\(field.name): the other copy keeps the authored value")
            XCTAssertFalse(field.changedHolds(after[0]), "\(field.name): the other copy doesn't take the change")
            XCTAssertTrue(field.changedHolds(after[1]), "\(field.name): the edited copy's particles take the change")
        }
    }

    /// A load with the property already changed resolves the field into the built system.
    func testEveryBoundFieldChangesAFreshlyLoadedSystem() throws {
        for field in Self.fields {
            let bound = try override(field.name, authored: field.authored)
            var authored = base()
            authored.overrides = SceneParticleOverrides(bound, in: Properties(values: ["p": field.authored]))
            var changed = base()
            changed.overrides = SceneParticleOverrides(bound, in: Properties(values: ["p": field.changed]))
            let simulator = try ParticleGPUSimulator(device: device)
            let states = try run([(ParticleSystemRuntime(texture: texture, configuration: authored, seed: 3), Properties()),
                                  (ParticleSystemRuntime(texture: texture, configuration: changed, seed: 3), Properties())],
                                 seconds: 1, simulator: simulator)
            XCTAssertTrue(field.authoredHolds(states[0]), field.name)
            XCTAssertTrue(field.changedHolds(states[1]), field.name)
        }
    }

    /// `count` sizes the particle budget, so a change rebuilds the object; the built system holds
    /// the changed count, and its emitters' rate scales with it.
    func testTheBoundCountChangesAFreshlyLoadedSystem() throws {
        let bound = try override("count", authored: "1")
        var configuration = base()
        configuration.overrides = SceneParticleOverrides(bound, in: Properties(values: ["p": "0.25"]))
        let simulator = try ParticleGPUSimulator(device: device)
        let runtime = ParticleSystemRuntime(texture: texture, configuration: configuration, seed: 3)
        let inputs = ParticleFrameInputs.advance(runtime, deltaTime: 1 / 60, cursor: .zero, values: Properties())
        XCTAssertEqual(inputs.maximum, 1000)
        XCTAssertEqual(inputs.emissionRate, 150, accuracy: 1e-3)
        var full = base()
        full.overrides = SceneParticleOverrides(bound, in: Properties(values: ["p": "1"]))
        let states = try run([(runtime, Properties()),
                              (ParticleSystemRuntime(texture: texture, configuration: full, seed: 3), Properties())],
                             seconds: 1, simulator: simulator)
        XCTAssertLessThan(Float(states[0].count), Float(states[1].count) * 0.4, "a quarter of the rate")
    }

    // MARK: - Scene

    private func model() throws -> SceneContentLoader {
        let directory = Fixtures.url("Scenes/particle-override-bindings")
        let project = try JSONDecoder().decode(WEProject.self, from: Fixtures.data("Scenes/particle-override-bindings/project.json"))
        addTeardownBlock { Fixtures.removeStoredSettings(for: directory) }
        return SceneContentLoader(wallpaper: WEWallpaper(using: project, where: directory))
    }

    private func built(sharing: Bool, edits: [String: String] = [:]) throws -> [SceneMetalParticleSystem] {
        let model = try model()
        model.sharesParticleDefinitions = sharing
        if !edits.isEmpty {
            let store = model.propertyStoreKey
            WallpaperServices.shared.setUserProperties(edits, wallpaper: store, replacing: false)
            addTeardownBlock { WallpaperServices.shared.setUserProperties([:], wallpaper: store, replacing: true) }
        }
        return try XCTUnwrap(model.metalContent()).particleSystems
    }

    /// Two copies of one definition bound to the same properties: a load with them changed bakes
    /// the change into each copy's own overrides, and each copy keeps its binding for live changes.
    func testCopiesSharingADefinitionEachTakeTheirBoundOverrides() throws {
        _ = try Fixtures.assets()
        let edits = ["tint": "0 1 0", "opacity": "0.25", "grain": "3"]
        for sharing in [true, false] {
            let defaults = try built(sharing: sharing).filter { $0.objectID != nil }
            let changed = try built(sharing: sharing, edits: edits).filter { $0.objectID != nil }
            XCTAssertEqual(changed.map(\.objectID), ["1", "2", "3"])
            for system in defaults.prefix(2) {
                XCTAssertEqual(system.overrides.tint, SIMD3(1, 1, 1))
                XCTAssertEqual(system.overrides.alpha, 1)
                XCTAssertEqual(system.overrides.size, 1)
                XCTAssertNotNil(system.liveOverrides, "bound: resolved again every frame")
            }
            for system in changed.prefix(2) {
                XCTAssertEqual(system.overrides.tint, SIMD3(0, 1, 0))
                XCTAssertEqual(system.overrides.alpha, 0.25)
                XCTAssertEqual(system.overrides.size, 3)
            }
            // The unbound copy keeps its literal overrides, shared parts or not.
            XCTAssertEqual(changed[2].overrides.tint, SIMD3(0.5, 0.5, 0.5))
            XCTAssertNil(changed[2].liveOverrides)
        }
    }

    /// The copies of a shared definition, stepped as the renderer steps them: a property change
    /// reaches both copies' new particles, and only theirs.
    func testCopiesSharingADefinitionTakeALiveChange() throws {
        _ = try Fixtures.assets()
        let systems = try built(sharing: true).filter { $0.objectID != nil }
        XCTAssertEqual(systems.count, 3)
        let runtimes = systems.map { ParticleSystemRuntime(texture: texture, configuration: $0, seed: 1) }
        let defaults = Properties(values: ["tint": "1 1 1", "opacity": "1", "grain": "1"])
        for runtime in runtimes {
            let inputs = ParticleFrameInputs.advance(runtime, deltaTime: 1 / 60, cursor: .zero, values: defaults)
            XCTAssertEqual(inputs.colorScale, runtime === runtimes[2] ? SIMD3(repeating: 0.5) : SIMD3(repeating: 1))
        }
        let changed = Properties(values: ["tint": "0 1 0", "opacity": "0.25", "grain": "3"])
        for runtime in runtimes {
            runtime.bindingRevision += 1
            let inputs = ParticleFrameInputs.advance(runtime, deltaTime: 1 / 60, cursor: .zero, values: changed)
            if runtime === runtimes[2] {
                XCTAssertEqual(inputs.colorScale, SIMD3(repeating: 0.5), "unbound")
                XCTAssertEqual(inputs.spawnScale.x, 1)
            } else {
                XCTAssertEqual(inputs.colorScale, SIMD3(0, 1, 0))
                XCTAssertEqual(inputs.spawnScale.x, 3)
                XCTAssertEqual(inputs.spawnScale.y, 0.25)
            }
        }
    }
}
