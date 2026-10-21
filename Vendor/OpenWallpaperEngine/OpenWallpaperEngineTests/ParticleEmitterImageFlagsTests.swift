import XCTest
import Metal
import simd
@testable import OpenWallpaperEngine

/// A `layerimage` emitter's flags 0x20000 ("update emission bitmap periodically") and 0x40000
/// ("inherit layer motion"), from `wallpaper64.exe` 2.8.42: the per-emitter timer 0x140238d4f, the
/// points' bones 0x1401d6d30, the spawn's bone 0x1401d4360 and inherited motion 0x1402397d3. No
/// library wallpaper uses them; these fixtures are written for them: a layer whose texture is
/// swapped (as a script or a video swaps it) and a two-bone rig.
final class ParticleEmitterImageFlagsTests: XCTestCase {
    func testTheFlagsAndTheSpeedDefaults() throws {
        func shape(_ json: String) throws -> ParticleEmitterShape {
            let emitter = try JSONDecoder().decode(WEParticleEmitter.self, from: Data(json.utf8))
            return ParticleSystemBuilder.emitterShape(emitter, defaults: ParticleDefaults(pixelUnits: true))
        }
        let plain = try shape(#"{"name": "layerimage"}"#)
        XCTAssertFalse(plain.resamplesImage)
        XCTAssertFalse(plain.inheritsLayerMotion)
        XCTAssertEqual(plain.speed, SIMD2(0.1, 0.2), "0x1401b9930")
        let both = try shape(#"{"name": "layerimage", "flags": 458752, "speedmin": 0.5, "speedmax": 2}"#)
        XCTAssertTrue(both.resamplesImage)
        XCTAssertTrue(both.inheritsLayerMotion)
        XCTAssertTrue(both.takesImageColor)
        XCTAssertEqual(both.speed, SIMD2(0.5, 2))
    }

    // MARK: - Bones (0x1401d6d30)

    /// Two 20 × 20 hit boxes, the second's bone 15 px to the right: they overlap on x 5…10.
    private static let rig = ParticleEmitterImageBones.Rig(
        boxes: [MDLSkeleton.BoneVector(vector: SIMD3(10, 10, 0), matrix: matrix_identity_float4x4),
                MDLSkeleton.BoneVector(vector: SIMD3(10, 10, 0), matrix: matrix_identity_float4x4)],
        restWorld: [matrix_identity_float4x4,
                    simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(15, 0, 0, 1)))])

    func testAPointTakesTheBoneWhoseBoxHoldsIt() {
        var points: [SIMD4<Int32>] = [SIMD4(0, 0, 0, 0), SIMD4(22, 3, 0, 0), SIMD4(50, 0, 0, 0), SIMD4(-30, 0, 0, 0),
                                      SIMD4(8, 0, 0, 0)]
        ParticleEmitterImageBones.assign(&points, rig: Self.rig)
        // Inside the first; inside the second; outside both, least far past the second's edge
        // (500 against 800) and past the first's; in both: the nearest point in one, (0, 0).
        XCTAssertEqual(points.map(\.w), [0, 1, 1, 0, 0])
    }

    func testAPointInBothBoxesTakesTheNearestUnmarkedPointsBone() {
        // (9, 0) is in both; (20, 0) is 11 away, in the second only; (-3, 0) 12 away, in the first.
        var points: [SIMD4<Int32>] = [SIMD4(-3, 0, 0, 0), SIMD4(9, 0, 0, 0), SIMD4(20, 0, 0, 0)]
        ParticleEmitterImageBones.assign(&points, rig: Self.rig)
        XCTAssertEqual(points.map(\.w), [0, 1, 1])
        // Equally near: the first in point order.
        var tied: [SIMD4<Int32>] = [SIMD4(20, 0, 0, 0), SIMD4(8, 0, 0, 0), SIMD4(-4, 0, 0, 0)]
        ParticleEmitterImageBones.assign(&tied, rig: Self.rig)
        XCTAssertEqual(tied.map(\.w), [1, 1, 0])
        // Every point in both: none to take.
        var all: [SIMD4<Int32>] = [SIMD4(6, 0, 0, 0), SIMD4(9, 2, 0, 0)]
        ParticleEmitterImageBones.assign(&all, rig: Self.rig)
        XCTAssertEqual(all.map(\.w), [-1, -1])
    }

    func testWithoutHitBoxesNoPointHasABone() {
        var points: [SIMD4<Int32>] = [SIMD4(0, 0, 0, 0), SIMD4(5, 5, 0, 0)]
        ParticleEmitterImageBones.assign(&points, rig: .init(boxes: [], restWorld: [matrix_identity_float4x4]))
        XCTAssertEqual(points.map(\.w), [-1, -1])
    }

    /// The grid search for overlapping points finds what a search of every point finds.
    func testTheOverlapSearchMatchesABruteForceOne() {
        var points: [SIMD4<Int32>] = []
        for column in Int32(0)..<60 {
            for row in Int32(0)..<20 where (column * 7 + row * 3) % 5 != 0 {
                points.append(SIMD4(column * 4 - 100, row * 4 - 40, 0, 0))
            }
        }
        var assigned = points
        ParticleEmitterImageBones.assign(&assigned, rig: Self.rig)
        // Brute force over the same inside/outside pass: overlapping points are those in both boxes.
        func inBox(_ point: SIMD4<Int32>, _ x: Float) -> Bool { abs(Float(point.x) - x) <= 10 && abs(Float(point.y)) <= 10 }
        for (index, point) in points.enumerated() where inBox(point, 0) && inBox(point, 15) {
            var best: (Int32, Int)?
            for (other, candidate) in points.enumerated() where !(inBox(candidate, 0) && inBox(candidate, 15)) {
                let dx = Int(candidate.x - point.x), dy = Int(candidate.y - point.y)
                let d: Int = dx * dx + dy * dy
                if best == nil || d < best!.1 { best = (assigned[other].w, d) }
            }
            XCTAssertEqual(assigned[index].w, best?.0 ?? -1, "point \(point)")
        }
    }

    // MARK: - Spawns (0x1402397d3)

    func testASpawnFollowsItsPointsBoneAndInheritsItsMotion() throws {
        var shape = ParticleEmitterShape()
        shape.kind = .image
        shape.takesImageColor = false
        shape.inheritsLayerMotion = true
        shape.speed = SIMD2(0.5, 0.5)
        let gpu = try ParticleGPUStepper()
        let runtime = try spawning(shape, points: [SIMD4(2, 3, 0, 1)], gpu: gpu)
        let emitted = try XCTUnwrap(try spawn(runtime, gpu: gpu, layerWorld: .identity) { step in
            step.frameTime = 0.5
            step.bones = [ParticleImageBone(current: .identity, previous: .identity),
                          ParticleImageBone(current: SceneAffineTransform(linear: matrix_identity_float2x2, translation: SIMD2(10, 0)),
                                            previous: SceneAffineTransform(linear: matrix_identity_float2x2, translation: SIMD2(4, 0)))]
        })
        XCTAssertEqual(simd_distance(emitted.position, SIMD2<Float>(12, 3)), 0, accuracy: 1e-4, "\(emitted.position)")
        // (10 − 4) px in 0.5 s, half of it.
        XCTAssertEqual(simd_distance(emitted.velocity, SIMD2<Float>(6, 0)), 0, accuracy: 1e-4, "\(emitted.velocity)")
    }

    /// Without a rig the motion is the layer's since the emitter's last step that spawned; before
    /// one WE measures it from the identity, so the first spawns launch from the scene's origin.
    func testWithoutARigTheLayersMotionSinceItsLastSpawningStep() throws {
        var shape = ParticleEmitterShape()
        shape.kind = .image
        shape.inheritsLayerMotion = true
        shape.speed = SIMD2(1, 1)
        let world = SceneAffineTransform(linear: matrix_identity_float2x2, translation: SIMD2(100, 50))
        let point: [SIMD4<Int32>] = [SIMD4(0, 0, 0xFFFFFF, 0)]
        let gpu = try ParticleGPUStepper()
        // A spawning step with the layer at (98, 50), then one with it at (100, 50).
        let movedSystem = try spawning(shape, points: point, gpu: gpu)
        _ = try spawn(movedSystem, gpu: gpu,
                      layerWorld: SceneAffineTransform(linear: matrix_identity_float2x2, translation: SIMD2(98, 50))) { $0.frameTime = 0.25 }
        let moved = try XCTUnwrap(try spawn(movedSystem, gpu: gpu, layerWorld: world) { $0.frameTime = 0.25 })
        XCTAssertEqual(simd_distance(moved.velocity, SIMD2<Float>(8, 0)), 0, accuracy: 1e-3, "\(moved.velocity)")
        let first = try XCTUnwrap(try spawn(try spawning(shape, points: point, gpu: gpu), gpu: gpu, layerWorld: world) {
            $0.frameTime = 0.25
        })
        XCTAssertEqual(simd_distance(first.velocity, SIMD2<Float>(400, 200)), 0, accuracy: 1e-2, "\(first.velocity)")
        let held = try XCTUnwrap(try spawn(try spawning(shape, points: point, gpu: gpu), gpu: gpu, layerWorld: world) {
            $0.frameTime = 0
        })
        XCTAssertEqual(held.velocity, .zero)
    }

    /// A system at the scene's origin of one `layerimage` emitter (`shape`) on layer "4"'s
    /// `points`, emitting only when `spawn` bursts it; its particles stay where they spawn, white.
    private func spawning(_ shape: ParticleEmitterShape, points: [SIMD4<Int32>], gpu: ParticleGPUStepper) throws -> ParticleSystemRuntime {
        var test = ParticleTestSystem()
        test.origin = .zero
        test.emissionRate = 0
        test.lifetime = 10...10
        test.minimumVelocity = .zero
        test.maximumVelocity = .zero
        var configuration = test.configuration
        configuration.program.operators = []
        configuration.emitter = shape
        configuration.emitterImages = [ParticleEmitterImage(layerID: "4", points: points)]
        return ParticleSystemRuntime(texture: try gpu.texture(), configuration: configuration)
    }

    /// One GPU step of `system` bursting one particle with layer "4" at `layerWorld`, its emitter's
    /// step changed by `change` first; the particle it spawned.
    private func spawn(_ system: ParticleSystemRuntime, gpu: ParticleGPUStepper, layerWorld: SceneAffineTransform,
                       change: (inout ParticleEmitterStep) -> Void) throws -> ParticleGPUState? {
        var inputs = ParticleFrameInputs.advance(system, deltaTime: 1 / 60, cursor: .zero,
                                                 layerWorld: { $0 == "4" ? layerWorld : nil })
        XCTAssertFalse(inputs.emitters.isEmpty)
        inputs.emitters[0].burst = 1
        change(&inputs.emitters[0])
        gpu.step(system, inputs: inputs)
        return gpu.particles(system).max { $0.serial < $1.serial }
    }

    // MARK: - Resampling (0x140238d4f, 0x1401d3ae0)

    private func system(resamples: Bool, points: [SIMD4<Int32>]) throws -> ParticleSystemRuntime {
        var test = ParticleTestSystem()
        test.emissionRate = 30
        var configuration = test.configuration
        configuration.emitter.kind = .image
        configuration.emitter.resamplesImage = resamples
        configuration.emitterImages = [ParticleEmitterImage(layerID: "4", points: points)]
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let texture = try XCTUnwrap(device.makeTexture(descriptor: .texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1,
                                                                                         height: 1, mipmapped: false)))
        return ParticleSystemRuntime(texture: texture, configuration: configuration)
    }

    /// Once past a second of emitting, the image is due again, and the count carries on from the
    /// remainder (`fmod`).
    func testTheEmitterAsksForItsImageOnceASecondOfEmitting() throws {
        let runtime = try system(resamples: true, points: [SIMD4(0, 0, 0, 0)])
        let layer = { (id: String) -> SceneAffineTransform? in id == "4" ? .identity : nil }
        var dueAt: [Int] = []
        // Quarter seconds: exactly one second after four steps, which isn't past it.
        for frame in 1...12 {
            _ = ParticleFrameInputs.advance(runtime, deltaTime: 0.25, cursor: .zero, layerWorld: layer)
            if !runtime.imageResamplesDue.isEmpty { dueAt.append(frame) }
            runtime.imageResamplesDue.removeAll()
        }
        XCTAssertEqual(dueAt, [5, 9])
        let plain = try system(resamples: false, points: [SIMD4(0, 0, 0, 0)])
        for _ in 1...12 { _ = ParticleFrameInputs.advance(plain, deltaTime: 0.25, cursor: .zero, layerWorld: layer) }
        XCTAssertTrue(plain.imageResamplesDue.isEmpty, "without flag 0x20000")
    }

    /// A 16 × 8 layer whose left half is opaque, swapped for one whose right half is: the emitter
    /// takes the new points once the GPU sampled them, the system's GPU state uploads them, and a
    /// sampling that finds the same picture changes nothing.
    func testASwappedTextureGivesNewPoints() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        func texture(opaqueLeft: Bool) throws -> MTLTexture {
            let made = try XCTUnwrap(device.makeTexture(descriptor: .texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 16,
                                                                                         height: 8, mipmapped: false)))
            var texels = [UInt8](repeating: 0, count: 16 * 8 * 4)
            for y in 0..<8 {
                for x in 0..<16 where (x < 8) == opaqueLeft {
                    let first: Int = (y * 16 + x) * 4
                    let texel: [UInt8] = [255, 128, 0, 255]
                    texels.replaceSubrange(first..<first + 4, with: texel)
                }
            }
            texels.withUnsafeBytes { made.replace(region: MTLRegionMake2D(0, 0, 16, 8), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 64) }
            return made
        }
        let size = SIMD2(16, 8)
        let target = ParticleEmitterImagePoints.targetSize(imageSize: size)
        let left = try texture(opaqueLeft: true), right = try texture(opaqueLeft: false)
        let before = ParticleEmitterImagePoints.points(
            rgba: try XCTUnwrap(ParticleEmitterImagePoints.reduce(.init(texture: left), target: target, device: device, queue: queue)),
            target: target, imageSize: size)
        XCTAssertTrue(before.allSatisfy { $0.x < 0 })
        let runtime = try system(resamples: true, points: before)
        let simulator = try ParticleGPUSimulator(device: device)
        let gpu = try XCTUnwrap(simulator.state(for: runtime))
        let firstBuffer = gpu.imagePoints
        var delivered: XCTestExpectation?
        let resampler = ParticleEmitterImageResampler(device: device, queue: queue) { block in
            DispatchQueue.main.async {
                block()
                delivered?.fulfill()
            }
        }
        func sample(_ image: MTLTexture) {
            delivered = expectation(description: "sampled")
            // The pipeline is made in the background; ask until it is.
            let deadline = Date().addingTimeInterval(5)
            var asked = false
            while !asked, Date() < deadline {
                ThreadGuards.renderFrame {
                    resampler.request(runtime, slot: 0, source: .init(sampling: .init(texture: image), imageSize: size, rig: nil))
                }
                asked = resampler.hasPending
                if !asked { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
            }
            wait(for: [delivered!], timeout: 5)
        }
        sample(right)
        XCTAssertEqual(runtime.emitterImagesRevision, 1)
        XCTAssertTrue(runtime.emitterImages[0].points.allSatisfy { $0.x > 0 })
        XCTAssertEqual(runtime.emitterImages[0].points.count, before.count)
        _ = simulator.state(for: runtime)
        XCTAssertFalse(gpu.imagePoints === firstBuffer, "new points, new buffer")
        XCTAssertEqual(gpu.imagePointsRevision, 1)
        sample(right)
        XCTAssertEqual(runtime.emitterImagesRevision, 1, "the same picture changes nothing")
    }
}
