import XCTest
import Metal
import AppKit
import simd
@testable import OpenWallpaperEngine

/// A particle system with several `renderers`: WE draws each one, in authored order, from the
/// system's one simulation (`SceneMetalParticleSystem.additionalRenderers`,
/// `ParticleSystemRuntime.simulation`).
final class ParticleRendererDrawTests: XCTestCase {
    private var device: MTLDevice!
    private var texture: MTLTexture!

    override func setUpWithError() throws {
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        texture = try XCTUnwrap(device.makeTexture(descriptor: .texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)))
    }

    // MARK: - Loading

    func testEveryRendererIsADrawOfTheOneSimulation() throws {
        let pairs: [(String, String)] = [("sprite", "spritetrail"), ("rope", "sprite"), ("sprite", "ropetrail")]
        for (first, second) in pairs {
            let (particles, system) = try build(#"[{"name": "\#(first)"}, {"name": "\#(second)"}]"#)
            XCTAssertEqual(particles.renderer?.count, 2)
            XCTAssertEqual(system.rendererName, first)
            XCTAssertEqual(system.additionalRenderers.map(\.name), [second])

            let simulation = ParticleSystemRuntime(texture: texture, configuration: system, seed: 1)
            let draws = ParticleSystemRuntime.addingRendererDraws([simulation])
            XCTAssertEqual(draws.count, 2, "\(first) + \(second): one draw per renderer")
            XCTAssertTrue(draws[0] === simulation)
            XCTAssertNil(simulation.simulation)
            XCTAssertTrue(draws[1].simulation === simulation, "the second renderer draws the first's particles")
            XCTAssertTrue(draws[1].configuration.additionalRenderers.isEmpty)
            for (draw, name) in zip(draws, [first, second]) {
                let material = try XCTUnwrap(draw.configuration.material, name)
                XCTAssertEqual(draw.configuration.rendererName, name)
                XCTAssertEqual(material.shader, name, "each renderer draws through the material made for it")
                XCTAssertEqual(material.format, Self.format(name))
                XCTAssertEqual(ParticleGPUDrawKind.material(material.format, rendererName: draw.configuration.rendererName),
                               Self.materialKind(name))
                XCTAssertEqual(ParticleGPUDrawKind.fallback(rendererName: draw.configuration.rendererName),
                               Self.fallbackKind(name))
            }
        }
    }

    /// WE's four renderer types are matched by name exactly; anything else draws sprites rather
    /// than whatever its name happens to contain.
    func testRendererTypesMatchWEsFourNamesExactly() {
        XCTAssertEqual(WEParticleRendererType.allCases.map(\.rawValue), ["sprite", "spritetrail", "rope", "ropetrail"])
        let expected: [String: (ParticleGPUDrawKind, ParticleVertexFormat)] = [
            "sprite": (.fallbackSprite, .sprite), "spritetrail": (.fallbackSpriteTrail, .sprite),
            "rope": (.fallbackRope, .rope), "ropetrail": (.fallbackRopeTrail, .rope),
            "mytrail": (.fallbackSprite, .sprite), "ropes": (.fallbackSprite, .sprite),
            "trailsprite": (.fallbackSprite, .sprite), "": (.fallbackSprite, .sprite),
        ]
        for (name, (kind, format)) in expected {
            XCTAssertEqual(ParticleGPUDrawKind.fallback(rendererName: name), kind, name)
            XCTAssertEqual(ParticleMaterialPlanBuilder.vertexFormat(rendererName: name), format, name)
        }
    }

    func testTheSecondRendererTakesItsOwnFields() throws {
        let (_, system) = try build(#"""
            [{"name": "sprite", "orientation": "upright", "axis": "0 1 0"},
             {"name": "spritetrail", "length": 0.2, "maxlength": 4, "minlength": 1}]
            """#)
        let draws = ParticleSystemRuntime.addingRendererDraws([
            ParticleSystemRuntime(texture: texture, configuration: system, seed: 1)])
        let trail = draws[1].configuration
        XCTAssertEqual(trail.trailLength, 0.2)
        XCTAssertEqual(trail.trailLengthLimits, SIMD2(4, 1))
        XCTAssertEqual(trail.orientation, ParticleOrientation(), "the trail's own (default) orientation")
        XCTAssertEqual(draws[0].configuration.orientation.mode, .upright)
        // The rest is the system's.
        XCTAssertEqual(trail.maximumParticleCount, system.maximumParticleCount)
        XCTAssertEqual(trail.emissionRate, system.emissionRate)
    }

    func testASystemWithOneRendererIsUnchanged() throws {
        let (_, system) = try build(#"[{"name": "ropetrail", "segments": 6, "length": 0.5}]"#)
        XCTAssertTrue(system.additionalRenderers.isEmpty)
        XCTAssertNil(system.sharedHistory)
        XCTAssertEqual(system.trailHistory, ParticleTrailHistory(kept: true, length: 0.5, segments: 6))
        let simulation = ParticleSystemRuntime(texture: texture, configuration: system, seed: 1)
        let draws = ParticleSystemRuntime.addingRendererDraws([simulation])
        XCTAssertEqual(draws.count, 1)
        XCTAssertTrue(draws[0] === simulation)

        let (_, sprite) = try build(#"[{"name": "sprite"}]"#)
        XCTAssertFalse(sprite.trailHistory.kept)
    }

    /// A `ropetrail` after a `sprite`: the simulation keeps that renderer's history, and the
    /// trail draws the sprites' particles.
    func testALaterRopeTrailSharesTheSimulationsHistory() throws {
        let (_, system) = try build(#"[{"name": "sprite"}, {"name": "ropetrail", "segments": 6, "length": 0.5}]"#)
        XCTAssertEqual(system.rendererName, "sprite")
        XCTAssertEqual(system.trailHistory, ParticleTrailHistory(kept: true, length: 0.5, segments: 6))
        let simulation = ParticleSystemRuntime(texture: texture, configuration: system, seed: 3)
        let draws = ParticleSystemRuntime.addingRendererDraws([simulation])
        let trail = draws[1]
        XCTAssertEqual(trail.configuration.trailHistory, system.trailHistory)
        let gpu = try ParticleGPUStepper()
        for _ in 0..<60 {
            let inputs = ParticleFrameInputs.advance(simulation, deltaTime: 1 / 60, cursor: .zero)
            trail.followSimulation()
            var drawn = inputs
            drawn.drawSizeScale = trail.drawSizeScale
            drawn.spriteLinear = trail.spriteLinear
            gpu.step([(simulation, inputs), (trail, drawn)])
        }
        let particles = gpu.particles(simulation)
        XCTAssertGreaterThan(particles.count, 0)
        let histories = particles.enumerated().map { index, particle in
            gpu.simulator.history(simulation, particle: particle, index: index, queue: gpu.queue)
        }
        XCTAssertTrue(histories.contains { !$0.isEmpty }, "the simulation samples the trail's history")
        XCTAssertTrue(histories.allSatisfy { $0.count <= 6 })
        // The trail draws the sprites' particles: each strand starts at a particle with history.
        let records = gpu.simulator.records(trail, as: ParticleRopeSegmentInstance.self, queue: gpu.queue).records
        let heads: [SIMD2<Float>] = records.filter { $0.previous.w == 0 }.map { SIMD2<Float>($0.start.x, $0.start.y) }
        let sampled = zip(particles, histories).filter { !$0.1.isEmpty }.map { $0.0 }
        XCTAssertEqual(heads.count, sampled.count)
        for particle in sampled {
            XCTAssertTrue(heads.contains { simd_distance($0, particle.position) < 1e-4 })
        }
        XCTAssertEqual(trail.elapsedTime, simulation.elapsedTime)
    }

    // MARK: - Rope trail motion

    /// A star moving at a steady speed, drawn as a `ropetrail` (3 s, 4 segments: a sample every
    /// 0.75 s) and stepped at an even 60 fps: where its texture ends must move on steadily with
    /// the star. Mapping the texture by segment index instead of by the samples'
    /// age (WE's segment time offset, `ParticleMaterialUniforms.ropeRenderVar`) leaves the end on the
    /// oldest sample until the next one is taken, then jumps it a quarter of the trail.
    func testARopeTrailsTextureEndMovesEvenly() throws {
        var test = ParticleTestSystem()
        test.rendererName = "ropetrail"
        test.trailLength = 3
        test.trailSegments = 4
        test.maximum = 1
        test.emissionRate = 1000
        test.lifetime = 20...20
        test.spawnExtent = .zero
        test.spins = false
        test.minimumVelocity = SIMD2(300, 0)
        test.maximumVelocity = SIMD2(300, 0)
        let system = ParticleSystemRuntime(texture: texture, configuration: test.configuration, seed: 1)
        let gpu = try ParticleGPUStepper()
        let step: Float = 1 / 60
        var heads: [Float] = [], ends: [Float] = []
        for frame in 0..<270 {
            gpu.step(system, inputs: ParticleFrameInputs.advance(system, deltaTime: step, cursor: .zero))
            // From 3.5 s on the trail is full.
            guard frame >= 210 else { continue }
            let particles = gpu.particles(system)
            XCTAssertEqual(particles.count, 1)
            heads.append(try XCTUnwrap(particles.first).position.x)
            ends.append(try XCTUnwrap(Self.textureEnd(system, gpu: gpu)).x)
        }
        let expected = 300 * step
        for (index, pair) in zip(heads, heads.dropFirst()).enumerated() {
            XCTAssertEqual(pair.1 - pair.0, expected, accuracy: 0.01, "head, frame \(index)")
        }
        let steps = zip(ends, ends.dropFirst()).map { $1 - $0 }
        print("ropetrail texture end steps per 1/60 s:", steps.map { String(format: "%.2f", $0) }.joined(separator: " "))
        // WE starts the countdown again from the interval (dropping what the step overshot), so
        // with 1/60 s steps a sample comes every 46 frames, not 45: the end holds for the one
        // frame a sample is taken in. It never jumps.
        for (index, advance) in steps.enumerated() {
            XCTAssertGreaterThanOrEqual(advance, 0, "texture end, frame \(index)")
            XCTAssertLessThan(advance, expected * 1.1, "texture end, frame \(index)")
        }
        XCTAssertLessThanOrEqual(steps.filter { $0 < expected * 0.9 }.count, 2, "one held frame per sample at most")
        XCTAssertEqual(steps.reduce(0, +) / Float(steps.count), expected, accuracy: expected * 0.05)
        // The texture spans three samples' worth of age behind the head.
        for (head, end) in zip(heads, ends) { XCTAssertEqual(head - end, 300 * 2.25, accuracy: 300 * 2.25 * 0.03) }
    }

    /// Where `system`'s first strand reaches texture coordinate 1, as `genericropeparticle.vert`'s
    /// `TRAILRENDERER` branch maps the last GPU step's records with `g_RenderVar0`.
    private static func textureEnd(_ system: ParticleSystemRuntime, gpu: ParticleGPUStepper) -> SIMD2<Float>? {
        let records = gpu.simulator.records(system, as: ParticleRopeSegmentInstance.self, queue: gpu.queue).records
        let renderVar = ParticleMaterialUniforms.ropeRenderVar(system)
        let offset = renderVar.z, maximum = renderVar.w
        var oldest: SIMD2<Float>?
        for record in records {
            let length = record.end.w, position = record.previous.w
            var usable = length - 1
            if length < maximum { usable += offset }
            guard usable > 0 else { continue }
            var minimum = (position - (1 - offset)) / usable
            var delta = 1 / usable
            if position < 0.5 {
                minimum = 0
                delta = offset / usable
            }
            let start = SIMD2(record.start.x, record.start.y), end = SIMD2(record.end.x, record.end.y)
            oldest = end
            if delta > 0, minimum <= 1, minimum + delta >= 1 { return start + (end - start) * ((1 - minimum) / delta) }
        }
        return oldest
    }

    // MARK: - GPU

    /// One GPU step, three draws: the sprites, a sprite trail and a rope trail, each with its own
    /// records and draw arguments over the same particles.
    func testTheGPUDrawsEveryRendererFromOneStep() throws {
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let simulator = try ParticleGPUSimulator(device: device)
        var system = ParticleTestSystem()
        system.maximum = 200
        system.emissionRate = 120
        var configuration = system.configuration
        let trail = ParticleRendererDraw(name: "spritetrail", trailLength: 0.05, trailLengthLimits: SIMD2(10, 0),
                                         trailSegments: 4, ropeSubdivision: 1, fadeTrailAlpha: false, fadeTrailSize: false,
                                         orientation: ParticleOrientation(), ropeUV: ParticleRopeUV())
        var rope = trail
        rope.name = "ropetrail"
        rope.trailLength = 0.5
        configuration.additionalRenderers = [trail, rope]
        configuration.sharedHistory = ParticleTrailHistory(kept: true, length: rope.trailLength, segments: rope.trailSegments)
        let runtimes = ParticleSystemRuntime.addingRendererDraws([
            ParticleSystemRuntime(texture: texture, configuration: configuration, seed: 5)])
        XCTAssertEqual(runtimes.count, 3)
        let kinds: [ParticleGPUDrawKind] = [.fallbackSprite, .fallbackSpriteTrail, .fallbackRopeTrail]
        var last: MTLCommandBuffer?
        for _ in 0..<60 {
            let inputs = ParticleFrameInputs.advance(runtimes[0], deltaTime: 1 / 60, cursor: .zero)
            var requests: [ParticleGPUSimulator.Request] = [.init(system: runtimes[0], inputs: inputs, kind: kinds[0])]
            for (draw, kind) in zip(runtimes.dropFirst(), kinds.dropFirst()) {
                draw.followSimulation()
                var drawn = inputs
                drawn.drawSizeScale = draw.drawSizeScale
                drawn.spriteLinear = draw.spriteLinear
                requests.append(.init(system: draw, inputs: drawn, kind: kind))
            }
            let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
            simulator.encode(requests, sceneSize: SIMD2(1280, 720), targetSize: SIMD2(1280, 720), commandBuffer: commandBuffer)
            commandBuffer.commit()
            last = commandBuffer
        }
        last?.waitUntilCompleted()
        XCTAssertNil(last?.error)

        let count = runtimes[0].gpu?.completedCount ?? 0
        XCTAssertGreaterThan(count, 50)
        let sprites = simulator.records(runtimes[0], as: LayerUniform.self, queue: queue)
        let trails = simulator.records(runtimes[1], as: LayerUniform.self, queue: queue)
        let ropes = simulator.records(runtimes[2], as: LayerUniform.self, queue: queue)
        XCTAssertEqual(sprites.fallback[1], UInt32(count))
        XCTAssertEqual(trails.fallback[1], UInt32(count), "the sprite trail draws every particle of the step")
        XCTAssertEqual(trails.records.count, count)
        XCTAssertGreaterThan(ropes.fallback[1], UInt32(count / 2), "the rope trail draws the step's history")
        XCTAssertLessThanOrEqual(ropes.fallback[1], UInt32(count * rope.trailSegments))
        XCTAssertTrue(runtimes[1].gpu !== runtimes[0].gpu)
        XCTAssertTrue(runtimes[1].gpu?.records !== runtimes[0].gpu?.records, "each renderer writes records of its own")
        // Same particles: the sprites and the trails sit at the same mean position.
        func mean(_ records: [LayerUniform]) -> SIMD2<Float> {
            records.reduce(SIMD2<Float>.zero) { $0 + $1.position } / Float(max(records.count, 1))
        }
        XCTAssertLessThan(simd_distance(mean(sprites.records), mean(trails.records)), 1)
    }

    // MARK: - Helpers

    private func build(_ renderers: String) throws -> (WEParticleSystem, SceneMetalParticleSystem) {
        let particles = try JSONDecoder().decode(WEParticleSystem.self, from: Data(#"""
            {"maxcount": 100, "material": "materials/p.json", "renderer": \#(renderers),
             "emitter": [{"name": "sphererandom", "rate": 30, "distancemax": 50}],
             "initializer": [{"name": "lifetimerandom", "min": 2, "max": 2}, {"name": "sizerandom", "min": 4, "max": 8}]}
            """#.utf8))
        let object = try JSONDecoder().decode(WESceneObject.self, from: Data(#"{"id": 1, "particle": "p.json"}"#.utf8))
        let firstName = particles.renderer?.first?.name ?? "sprite"
        var system = ParticleSystemBuilder.build(
            "p.json", particleSystem: particles, object: object, world: .identity, overrides: SceneParticleOverrides(),
            sceneSize: SIMD2(1000, 1000), source: .image(NSImage()), spriteSheet: nil, material: WEMaterial(),
            materialPlan: nil)
        system.material = Self.plan(firstName)
        ParticleSystemBuilder.addRenderers(to: &system, particleSystem: particles) { Self.plan($0.name ?? "sprite") }
        return (particles, system)
    }

    /// A stand-in material for `renderer`, named after it.
    private static func plan(_ renderer: String) -> ParticleMaterialPlan {
        ParticleMaterialPlan(materialPath: "materials/p.json", shader: renderer, format: format(renderer),
                             blending: "translucent", stages: [], trailLengths: .zero, spriteSheet: nil)
    }

    private static func format(_ renderer: String) -> ParticleVertexFormat {
        renderer.hasPrefix("rope") ? .rope : .sprite
    }

    private static func materialKind(_ renderer: String) -> ParticleGPUDrawKind {
        switch renderer {
        case "rope": return .rope
        case "ropetrail": return .ropeTrail
        default: return .sprite
        }
    }

    private static func fallbackKind(_ renderer: String) -> ParticleGPUDrawKind {
        switch renderer {
        case "rope": return .fallbackRope
        case "ropetrail": return .fallbackRopeTrail
        case "spritetrail": return .fallbackSpriteTrail
        default: return .fallbackSprite
        }
    }
}
