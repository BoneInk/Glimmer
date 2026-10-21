import XCTest
import Metal
import simd
@testable import OpenWallpaperEngine

/// Steps particle systems frame by frame on the GPU simulation the renderer runs
/// (`ParticleGPUSimulator`) and reads their particles back, for tests that drive a system
/// directly rather than through a scene. Every step is committed and waited for.
final class ParticleGPUStepper {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let simulator: ParticleGPUSimulator
    /// The scene and target sizes the steps run at.
    var sceneSize = SIMD2<Float>(1920, 1080)

    init() throws {
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        queue = try XCTUnwrap(device.makeCommandQueue())
        simulator = try ParticleGPUSimulator(device: device)
    }

    /// A 1 × 1 texture for `ParticleSystemRuntime(texture:…)`.
    func texture() throws -> MTLTexture {
        try XCTUnwrap(device.makeTexture(descriptor: .texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)))
    }

    /// The draw the step writes records for: the system's material kind for its renderer (records
    /// only matter to tests that read them).
    static func kind(_ system: ParticleSystemRuntime) -> ParticleGPUDrawKind {
        system.configuration.rendererName == "ropetrail" ? .ropeTrail
            : system.configuration.rendererName == "rope" ? .rope : .sprite
    }

    /// One step of each system from its inputs, in order (a family's parent before its children),
    /// in one command buffer.
    func step(_ steps: [(system: ParticleSystemRuntime, inputs: ParticleFrameInputs)]) {
        guard let commandBuffer = queue.makeCommandBuffer() else {
            XCTFail("no command buffer")
            return
        }
        let requests = steps.map {
            ParticleGPUSimulator.Request(system: $0.system, inputs: $0.inputs, kind: Self.kind($0.system), materialVertexCount: 6)
        }
        simulator.encode(requests, sceneSize: sceneSize, targetSize: sceneSize, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertNil(commandBuffer.error)
    }

    /// One step of `system` from `inputs`.
    func step(_ system: ParticleSystemRuntime, inputs: ParticleFrameInputs) {
        step([(system, inputs)])
    }

    /// Advances every system by `deltaTime` with the cursor at `cursor` and steps them, in order.
    func update(_ systems: [ParticleSystemRuntime], deltaTime: Float, cursor: SIMD2<Float>) {
        step(systems.map { ($0, ParticleFrameInputs.advance($0, deltaTime: deltaTime, cursor: cursor)) })
    }

    /// `system`'s live particles after the last step.
    func particles(_ system: ParticleSystemRuntime) -> [ParticleGPUState] {
        simulator.snapshot(system, queue: queue)
    }

    /// An instanced system's instances after the last step.
    func instances(_ system: ParticleSystemRuntime) -> [ParticleGPUInstance] {
        simulator.instances(system, queue: queue)
    }
}

/// The fields of a particle read back from the GPU (`ParticleGPUState`'s packing), by name.
extension ParticleGPUState {
    var position: SIMD2<Float> { SIMD2(positionVelocity.x, positionVelocity.y) }
    var velocity: SIMD2<Float> { SIMD2(positionVelocity.z, positionVelocity.w) }
    var age: Float { life.x }
    var lifetime: Float { life.y }
    var size: Float { life.z }
    var baseSize: Float { life.w }
    var alpha: Float { alphaRotation.x }
    var baseAlpha: Float { alphaRotation.y }
    var rotation: Float { alphaRotation.z }
    var angularVelocity: Float { alphaRotation.w }
    var instance: Int { Int(trail.z) }
    var serial: UInt32 { identity.x }
    var spriteFrame: Int { Int(identity.y) }
    var z: Float { depth.x }
    var zVelocity: Float { depth.y }
    var rotationXY: SIMD2<Float> { SIMD2(spin.x, spin.y) }
    var angularVelocityXY: SIMD2<Float> { SIMD2(spin.z, spin.w) }
}
