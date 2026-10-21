import XCTest
import AppKit
import Metal
import simd
@testable import OpenWallpaperEngine

/// The particle program in 3D (test-risks PG1; `wallpaper64.exe`'s VM keeps position and velocity
/// as x, y, z, system+0x2b0…0x2d8): control point orientation from `controlpointangle<n>`, and
/// the 3D operators and initializers on the GPU.
final class ParticleProgram3DTests: XCTestCase {
    // MARK: - Control points

    /// R(x, y, z) of 0x14022bf53…0x14022c069: x first, then y, then z; an axis a becomes a·R.
    func testTheControlPointRotationIsWEs() {
        let angles = SIMD3<Float>(0.3, -1.1, 2.0)
        let axes = ParticleProgramEncoding.controlPointRotation(angles)
        let rx = simd_float3x3(simd_quatf(angle: angles.x, axis: SIMD3(1, 0, 0)))
        let ry = simd_float3x3(simd_quatf(angle: angles.y, axis: SIMD3(0, 1, 0)))
        let rz = simd_float3x3(simd_quatf(angle: angles.z, axis: SIMD3(0, 0, 1)))
        let expected = rz * ry * rx
        for column in 0..<3 {
            XCTAssertLessThan(simd_distance(axes[column], expected[column]), 1e-5)
        }
        // "0 0 1" becomes row 2 of WE's matrix: (cx·sy·cz + sx·sz, cx·sy·sz − sx·cz, cx·cy).
        let cx = cos(angles.x), sx = sin(angles.x), cy = cos(angles.y), sy = sin(angles.y)
        let cz = cos(angles.z), sz = sin(angles.z)
        XCTAssertLessThan(simd_distance(axes * SIMD3(0, 0, 1),
                                        SIMD3(cx * sy * cz + sx * sz, cx * sy * sz - sx * cz, cx * cy)), 1e-5)
    }

    /// `controlpointangle<n>` turns its point (not one on the cursor); in a `worldspace` system the
    /// emitter's rotation composes with it; offsets keep their z (0x14022cdc0, 0x14022a070).
    func testTheAngleOverrideTurnsItsPointAndOffsetsKeepTheirDepth() throws {
        var system = ParticleTestSystem()
        system.controlPoints[1] = ParticleTestSystem.point(SIMD2(10, 20), z: 30)
        system.controlPoints[2] = ParticleTestSystem.point(.zero, cursor: true)
        var configuration = system.configuration
        configuration.overrides.controlPointAngles = [1: SIMD3(0, 0, .pi / 2), 2: SIMD3(1, 1, 1)]
        let runtime = ParticleSystemRuntime(texture: try texture(), configuration: configuration, seed: 1)
        let inputs = ParticleFrameInputs.advance(runtime, deltaTime: 1 / 60, cursor: .zero)
        XCTAssertEqual(inputs.controlPoints[1], SIMD3(10, 20, 30))
        XCTAssertLessThan(simd_distance(inputs.controlPointAxes[1] * SIMD3(1, 0, 0), SIMD3(0, 1, 0)), 1e-6,
                          "a quarter turn about z")
        XCTAssertEqual(inputs.controlPointAxes[2], matrix_identity_float3x3, "the override skips a cursor point")

        var world = ParticleTestSystem()
        world.worldSpace = true
        world.emitterLinear = simd_float2x2(simd_quatf(angle: .pi / 2, axis: SIMD3(0, 0, 1)).act(SIMD3(1, 0, 0)).xy2,
                                            simd_quatf(angle: .pi / 2, axis: SIMD3(0, 0, 1)).act(SIMD3(0, 1, 0)).xy2)
        var worldConfiguration = world.configuration
        worldConfiguration.overrides.controlPointAngles = [0: SIMD3(.pi / 2, 0, 0)]
        let worldRuntime = ParticleSystemRuntime(texture: try texture(), configuration: worldConfiguration, seed: 1)
        let worldInputs = ParticleFrameInputs.advance(worldRuntime, deltaTime: 1 / 60, cursor: .zero)
        // Row vectors: a·(R·model): y turns to z by R, z stays z under the emitter's turn about z.
        let turned = worldInputs.controlPointAxes[0] * SIMD3(0, 1, 0)
        XCTAssertLessThan(simd_distance(turned, SIMD3(0, 0, 1)), 1e-5)
        let x = worldInputs.controlPointAxes[0] * SIMD3(1, 0, 0)
        XCTAssertLessThan(simd_distance(x, SIMD3(0, 1, 0)), 1e-5, "x turns with the emitter")
    }

    // MARK: - Simulation in depth

    /// Vortices, turbulence, oscillation, control point fields and 3D spawns through a turned
    /// emitter point all give the particles depth.
    func testThe3DProgramGivesTheParticlesDepth() throws {
        let stepper = try ParticleGPUStepper()
        var cases: [(String, ParticleTestSystem, (inout SceneMetalParticleSystem) -> Void)] = []
        var vortices = ParticleTestSystem()
        vortices.operators = [ParticleOperator(.vortex, a: SIMD4(0, 0, 10, 0), b: SIMD4(0, 1, 0, 0), c: SIMD4(0, 300, 200, 50)),
                              ParticleOperator(.vortexV2, flags: 1, controlPoints: 1, a: SIMD4(0, 0, 1, 0), b: SIMD4(0, 300, 150, 0)),
                              ParticleOperator(.turbulence, a: SIMD4(1, 1, 1, 0), b: SIMD4(0.01, 100, 200, 0.5)),
                              ParticleOperator(.oscillatePosition, a: SIMD4(1, 1, 1, 0), b: SIMD4(1, 3, 0, 1), c: SIMD4(0, 5, 0, 0))]
        vortices.controlPoints[1] = ParticleTestSystem.point(SIMD2(40, 0), z: 20)
        cases.append(("vortices, turbulence and oscillation", vortices, { configuration in
            configuration.emitter.directions.z = 1
            configuration.overrides.controlPointAngles = [1: SIMD3(0.7, 0.2, -0.4)]
        }))
        var fields = ParticleTestSystem()
        fields.operators = [ParticleOperator(.controlPointAttract, controlPoints: 1, b: SIMD4(300, 400, 5, 0)),
                            ParticleOperator(.maintainDistanceToControlPoint, controlPoints: 2, a: SIMD4(60, 0.5, 0, 0)),
                            ParticleOperator(.reduceMovementNearControlPoint, controlPoints: 1, a: SIMD4(10, 200, 1, 0)),
                            ParticleOperator(.capVelocity, a: SIMD4(90, 0, 0, 0))]
        fields.controlPoints[1] = ParticleTestSystem.point(SIMD2(-30, 10), z: -40)
        fields.controlPoints[2] = ParticleTestSystem.point(SIMD2(20, 0), z: 30)
        cases.append(("control point fields", fields, { configuration in
            configuration.emitter.directions.z = 1
            configuration.overrides.controlPointAngles = [2: SIMD3(0, 0.5, 0)]
        }))
        var spawns = ParticleTestSystem()
        spawns.initializers = [ParticleInitializer(.mapSequenceAroundControlPoint, controlPoints: 1, a: SIMD4(0.05, 0, 1, 0),
                                                   b: SIMD4(10, 0, 5, 0), c: SIMD4(20, 0, 5, 0), d: SIMD4(0, 1, 0, 0)),
                               ParticleInitializer(.positionOffsetRandom, a: SIMD4(1, 1, 1, 0), c: SIMD4(0.01, 20, 1, 2)),
                               ParticleInitializer(.velocityRandom, a: SIMD4(-20, -20, -20, 1), b: SIMD4(20, 20, 20, 0))]
        spawns.controlPoints[1] = ParticleTestSystem.point(SIMD2(0, 30), z: 10)
        spawns.emitterControlPoint = 1
        cases.append(("3D spawns through a turned emitter point", spawns, { configuration in
            configuration.emitter.directions.z = 1
            configuration.overrides.controlPointAngles = [1: SIMD3(0.4, 1.2, 0.3)]
        }))
        let texture = try self.texture()
        for (label, system, configure) in cases {
            var configuration = system.configuration
            configure(&configuration)
            let runtime = ParticleSystemRuntime(texture: texture, configuration: configuration, seed: 11)
            for _ in 0..<90 {
                stepper.step(runtime, inputs: ParticleFrameInputs.advance(runtime, deltaTime: 1 / 60, cursor: .zero))
            }
            let states = stepper.particles(runtime)
            XCTAssertGreaterThan(states.count, 50, label)
            let spread: Float = states.map { abs($0.z) }.reduce(0, +) / Float(max(states.count, 1))
            XCTAssertGreaterThan(spread, 1, "\(label): the particles have depth")
            XCTAssertTrue(states.allSatisfy { $0.position.x.isFinite && $0.position.y.isFinite && $0.z.isFinite }, label)
        }
    }

    private func texture() throws -> MTLTexture {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        return try XCTUnwrap(device.makeTexture(descriptor: .texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1,
                                                                                mipmapped: false)))
    }
}

private extension SIMD3 where Scalar == Float {
    var xy2: SIMD2<Float> { SIMD2(x, y) }
}
