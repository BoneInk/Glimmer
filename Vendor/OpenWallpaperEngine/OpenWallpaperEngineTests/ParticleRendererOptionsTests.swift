import XCTest
import simd
@testable import OpenWallpaperEngine

/// A renderer's `orientation` (`ParticleOrientation`) and a rope's texture layout
/// (`ParticleRopeUV`), as `wallpaper64.exe` computes them (0x1402298b0, 0x14023099e).
final class ParticleRendererOptionsTests: XCTestCase {
    private func renderer(_ json: String) throws -> WEParticleRenderer {
        try JSONDecoder().decode(WEParticleRenderer.self, from: Data(json.utf8))
    }

    private func assertEqual(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ message: String = "",
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThan(simd_distance(a, b), 1e-5, "\(message): \(a) vs \(b)", file: file, line: line)
    }

    func testTheRendererFieldsDecodeWithWEsDefaults() throws {
        let plain = ParticleOrientation(try renderer(#"{"name":"sprite"}"#))
        XCTAssertEqual(plain.mode, .screen)
        XCTAssertTrue(plain.objectSpace)
        assertEqual(plain.axis, SIMD3(0, 1, 0), "no axis: y")
        assertEqual(plain.across, SIMD3(0, 0, -1))
        let fixed = ParticleOrientation(try renderer(#"{"name":"sprite","orientation":"fixed","axis":"0 0 2","flags":1}"#))
        XCTAssertEqual(fixed.mode, .fixed)
        XCTAssertFalse(fixed.objectSpace, "flag 1: the axis is in the scene")
        assertEqual(fixed.axis, SIMD3(0, 0, 1), "normalised")
        assertEqual(fixed.across, simd_normalize(simd_cross(SIMD3(0, 0, 1), SIMD3(1, 0, 0))), "axis × (y × axis)")
        let uv = ParticleRopeUV(try renderer(#"{"name":"rope","uvscale":2,"uvscrolling":true}"#), rate: 6, lifetime: 1)
        XCTAssertEqual(uv.inverseScale, 0.5)
        XCTAssertTrue(uv.scrolling)
        XCTAssertFalse(uv.smoothing, "smoothing is only read without scrolling")
        XCTAssertTrue(ParticleRopeUV(try renderer(#"{"name":"rope"}"#), rate: 0, lifetime: 0).smoothing, "true by default")
    }

    /// Screen, in the object's space, is the object's own axes: what sprites drew with before.
    func testScreenFacingTakesTheObjectsAxes() {
        let linear = simd_float2x2(SIMD2(0.8, 0.6), SIMD2(-0.6, 0.8)) * simd_float2x2(diagonal: SIMD2(2.5, 0.5))
        let axes = ParticleOrientation().axes(linear: linear)
        assertEqual(axes.right, SIMD3(linear.columns.0, 0), "right")
        assertEqual(axes.up, SIMD3(linear.columns.1, 0), "up")
        assertEqual(axes.forward, SIMD3(0, 0, 1), "facing the camera")
        // Flag 1: the camera's up, whatever the object's turn.
        var camera = ParticleOrientation()
        camera.objectSpace = false
        let turned = simd_float2x2(SIMD2(0, 2), SIMD2(-2, 0))
        let upright = camera.axes(linear: turned)
        assertEqual(upright.up, SIMD3(0, 2, 0), "up stays up (scaled by the object)")
        assertEqual(upright.right, SIMD3(2, 0, 0))
    }

    /// Upright turns about the axis to face the camera; fixed lies in the axis's plane, edge-on in a
    /// 2D scene with WE's default axis.
    func testUprightAndFixed() {
        var upright = ParticleOrientation()
        upright.mode = .upright
        upright.axis = SIMD3(1, 0, 0)
        let axes = upright.axes(linear: matrix_identity_float2x2)
        assertEqual(axes.up, SIMD3(1, 0, 0), "up along the axis")
        assertEqual(axes.right, SIMD3(0, -1, 0), "camera forward × up")
        assertEqual(axes.forward, SIMD3(0, 0, 1))
        var fixed = ParticleOrientation()
        fixed.mode = .fixed
        let flat = fixed.axes(linear: matrix_identity_float2x2)
        assertEqual(flat.forward, SIMD3(0, 1, 0), "facing along y")
        assertEqual(flat.up, SIMD3(0, 0, -1))
        XCTAssertEqual(fixed.spriteLinear(linear: matrix_identity_float2x2).columns.1, .zero, "edge-on in the scene plane")
    }

    /// WE's rope layout (0x14023099e…0x140230a84): smoothing slides the texture as the oldest point
    /// dies, scrolling shifts it by the dead, and `uvscale` repeats it.
    func testRopeLayout() {
        var uv = ParticleRopeUV()
        uv.rate = 10
        uv.lifetime = 2
        // Filling: fewer points than E − 1 = 19 keeps the points.
        var layout = uv.layout(points: 10, oldestAge: 0.9, died: 0, rateScale: 1, lifetimeScale: 1, frameRateLimit: 60)
        XCTAssertEqual(layout.count, 10)
        XCTAssertEqual(layout.shift, 0)
        // Full: E − 1 and the oldest point's remaining fraction of a spawn interval.
        layout = uv.layout(points: 20, oldestAge: 1.97, died: 0, rateScale: 1, lifetimeScale: 1, frameRateLimit: 60)
        XCTAssertEqual(layout.count, 19, accuracy: 1e-5)
        XCTAssertEqual(layout.shift, (2 - 1.97) * 10 - 1, accuracy: 1e-4)
        // Filling faster than the frame rate: the rate is capped by it.
        uv.rate = 100
        layout = uv.layout(points: 5, oldestAge: 0, died: 0, rateScale: 1, lifetimeScale: 1, frameRateLimit: 30)
        XCTAssertEqual(layout.count, 5)
        layout = uv.layout(points: 59, oldestAge: 2, died: 0, rateScale: 1, lifetimeScale: 1, frameRateLimit: 30)
        XCTAssertEqual(layout.count, 59, accuracy: 1e-4, "E − 1 = 30 · 2 − 1")
        uv.rate = 10
        uv.smoothing = false
        XCTAssertEqual(uv.layout(points: 20, oldestAge: 1, died: 0, rateScale: 1, lifetimeScale: 1, frameRateLimit: 60).count, 20)
        uv.scrolling = true
        uv.inverseScale = 0.5
        layout = uv.layout(points: 3, oldestAge: 1, died: 42, rateScale: 2, lifetimeScale: 1, frameRateLimit: 60)
        XCTAssertEqual(layout.count, (20 * 2 - 1) * 0.5, accuracy: 1e-4, "E − 1 with the rate override, over uvscale")
        XCTAssertEqual(layout.shift, 42)
    }

    /// The engine combos a rope material takes from its renderer (0x1401d261b…0x1401d2b3e).
    func testRopeCombosFollowTheRenderer() throws {
        let rope = ParticleMaterialPlanBuilder.engineCombos(format: .rope, rendererName: "rope",
                                                            renderer: try renderer(#"{"name":"rope","orientation":"upright"}"#),
                                                            flags: 0, spriteSheet: nil, baseTexture: .image(NSImage()))
        XCTAssertEqual(rope["ORIENTATION"], 1)
        XCTAssertNil(rope["TRAILSCROLLALPHA"])
        let trail = ParticleMaterialPlanBuilder.engineCombos(format: .rope, rendererName: "ropetrail",
                                                             renderer: try renderer(#"{"name":"ropetrail","uvscrolling":true}"#),
                                                             flags: 0, spriteSheet: nil, baseTexture: .image(NSImage()))
        XCTAssertEqual(trail["ORIENTATION"], 0)
        XCTAssertEqual(trail["TRAILSCROLLALPHA"], 1)
    }

    /// WE's sprite trail stretches by `clamp(|v|·length, minlength, maxlength)` with the velocity in
    /// the system's space (`ComputeParticleTrailTangents`); the records hold the scene's velocity,
    /// the emitter's scale times it, so `length` is divided by that scale. WE's `spritetrail`
    /// preview (scale 0.10223, speed 400…500, length 0.01) stretches its halos 4…5 times.
    func testSpriteTrailsStretchByTheirSpeedInTheSystemsSpace() {
        let lengths = SIMD4<Float>(0.01, 10, 0, 0)
        let scaled = ParticleMaterialUniforms.trailRenderVar(lengths, drawSizeScale: 0.10223)
        XCTAssertEqual(450 * 0.10223 * scaled.x, 4.5, accuracy: 1e-3)
        XCTAssertEqual(SIMD3(scaled.y, scaled.z, scaled.w), SIMD3(10, 0, 0))
        XCTAssertEqual(ParticleMaterialUniforms.trailRenderVar(lengths, drawSizeScale: 1), lengths)
    }
}
