import XCTest
import Metal
import simd
@testable import OpenWallpaperEngine

/// `remapvalue` on control points, as `wallpaper64.exe` runs it (operator outputs
/// 0x140245c9e…0x140246e52).
final class ParticleRemapControlPointTests: XCTestCase {
    private var gpu: ParticleGPUStepper!

    override func setUpWithError() throws {
        gpu = try ParticleGPUStepper()
    }

    private func remapOperator(_ json: String) throws -> ParticleOperator {
        let element = try JSONDecoder().decode(WEParticleOperator.self, from: Data(json.utf8))
        return try XCTUnwrap(ParticleOperatorBuilder.make(element, defaults: ParticleDefaults(pixelUnits: true),
                                                          sceneSize: SIMD2(100, 100), path: "t"))
    }

    /// The control point `index` the last step of `runtime` wrote and keeps for the next step
    /// (`PointState.kept` in `ParticleProgram.h`).
    private func keptPoint(_ runtime: ParticleSystemRuntime, _ index: Int) throws -> SIMD3<Float> {
        let points = try XCTUnwrap(runtime.gpu?.pointStates, "the program writes control points")
        // `PointState`: points[8], group[8], then kept[8], all float4.
        let offset = (16 + index) * MemoryLayout<SIMD4<Float>>.stride
        let kept = points.contents().load(fromByteOffset: offset, as: SIMD4<Float>.self)
        return SIMD3<Float>(kept.x, kept.y, kept.z)
    }

    /// The operator writes a control point once per group of four particles, each group adding to
    /// what the last left; the next step starts from the written point.
    func testTheControlPointOutputWritesOncePerFourParticles() throws {
        let add = try remapOperator(#"{"name":"remapvalue","input":"maxlifetime","output":"controlpoint","outputcontrolpoint0":1,"operation":"add","outputrangemin":"0 0 0","outputrangemax":"1 2 0"}"#)
        for (count, groups) in [(8, 2), (9, 3), (3, 1)] {
            var system = ParticleTestSystem()
            system.emissionRate = 0
            system.instantaneous = count
            system.lifetime = 1...1
            system.controlPoints[1] = ParticleTestSystem.point(SIMD2(10, 10))
            system.operators = [add]
            let runtime = ParticleSystemRuntime(texture: try gpu.texture(), configuration: system.configuration, seed: 1)
            gpu.step(runtime, inputs: ParticleFrameInputs.advance(runtime, deltaTime: 1 / 60, cursor: .zero))
            XCTAssertEqual(gpu.particles(runtime).count, count)
            let written = try keptPoint(runtime, 1)
            let expected: SIMD3<Float> = SIMD3(10, 10, 0) + SIMD3(1, 2, 0) * Float(groups)
            XCTAssertLessThan(simd_distance(written, expected), 1e-4, "\(count) particles")
        }
    }
}
