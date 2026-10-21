import XCTest
import Metal
import simd
@testable import OpenWallpaperEngine

/// A particle system WE 2.8.0.42's editor creates starts from its template, WE's own
/// `particles/example.json`: max count 500, a sphere random emitter (distance 32…512, directions
/// 1 1 0, rate 20, speed 0), lifetime random 3…5, colour random white, movement and alpha fade
/// 0.5 / 0.5, and the additive `halo` material, whose `g_Overbright` defaults to 1.
///
/// These are values the template writes, not the parser's defaults for absent fields, which stay
/// `wallpaper64.exe`'s (`ParticleProgramTests`: max count 0, rate 10, distance 0…256, lifetime
/// 0…1, colour 0…255, `translucent`).
final class ParticleEditorTemplateTests: XCTestCase {
    private let assets = ShaderVariantTests.weAssets

    private func decode<T: Decodable>(_ path: String) throws -> T {
        let url = assets.appending(path: path)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "bundled WE assets missing")
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }

    func testTheEditorsNewSystemRunsWithItsTemplateValues() throws {
        let particles: WEParticleSystem = try decode("particles/example.json")
        let material: WEMaterial = try decode("materials/particle/halo.json")
        let object = try JSONDecoder().decode(WESceneObject.self, from: Data(#"{"id": 1, "particle": "particles/example.json"}"#.utf8))
        let system = ParticleSystemBuilder.build(
            "particles/example.json", particleSystem: particles, object: object, world: .identity,
            overrides: SceneParticleOverrides(), sceneSize: SIMD2(1920, 1080), source: .image(NSImage()),
            spriteSheet: nil, material: material, materialPlan: nil)
        XCTAssertEqual(system.maximumParticleCount, 500)
        XCTAssertEqual(system.emissionRate, 20)
        XCTAssertEqual(system.emitter.kind, .sphere)
        XCTAssertEqual(system.emitter.distanceMinimum.x, 32)
        XCTAssertEqual(system.emitter.distanceMaximum.x, 512)
        XCTAssertEqual(system.emitter.directions, SIMD3(1, 1, 0))
        XCTAssertEqual(system.emitter.speed, SIMD2(0, 0))
        XCTAssertEqual(system.blending, "additive")

        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let texture = try XCTUnwrap(device.makeTexture(descriptor: .texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)))
        let runtime = ParticleSystemRuntime(texture: texture, configuration: system, seed: 7)
        let gpu = try ParticleGPUStepper()
        for _ in 0..<120 {
            gpu.step(runtime, inputs: ParticleFrameInputs.advance(runtime, deltaTime: 1 / 60, cursor: .zero))
        }
        let simulated = gpu.particles(runtime)
        XCTAssertEqual(simulated.count, 40, "rate 20 for 2 s")
        for particle in simulated {
            XCTAssertTrue((3...5).contains(particle.lifetime), "lifetime random 3…5: \(particle.lifetime)")
            XCTAssertEqual(particle.baseColor.x, 1, accuracy: 1e-5, "colour random 255…255 is white")
            XCTAssertEqual(particle.baseColor.y, 1, accuracy: 1e-5)
            XCTAssertEqual(particle.baseColor.z, 1, accuracy: 1e-5)
        }

        let shader = try String(contentsOf: assets.appending(path: "shaders/genericparticle.frag"), encoding: .utf8)
        XCTAssertTrue(shader.contains(#"uniform float g_Overbright; // {"material":"ui_editor_properties_overbright","default":1.0"#),
                      "the halo material leaves overbright at its annotation's 1")
    }

    /// `alphafade` without `fadeouttime` is WE's 0.5 / 0.5, what the editor shows for the template.
    func testTheTemplatesAlphaFadeIsHalfAndHalf() throws {
        let particles: WEParticleSystem = try decode("particles/example.json")
        let fade = try XCTUnwrap(particles.operator?.first { $0.name == "alphafade" })
        let record = try XCTUnwrap(ParticleOperatorBuilder.make(fade, defaults: ParticleDefaults(pixelUnits: true),
                                                                sceneSize: SIMD2(1920, 1080), path: "t")).record
        XCTAssertEqual(record.a.x, 0.5)
        XCTAssertEqual(record.a.y, 0.5)
        XCTAssertTrue(particles.operator?.contains { $0.name == "movement" } == true)
    }
}
