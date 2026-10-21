import XCTest
import simd
@testable import OpenWallpaperEngine

/// A puppet whose bind pose rearranges an atlas runs its effects on its texture as stored, where
/// their masks are painted; one whose bind pose is its texture's layout draws that pose. The posed
/// mesh then lays the output out, its triangles composited over each other.
final class ScenePuppetEffectLayoutTests: XCTestCase {
    private let size = SIMD2<Float>(3840, 3000)

    // MARK: Atlas detection

    private func vertices(_ points: [(SIMD2<Float>, SIMD2<Float>)]) -> (Data, MDLVertexFormat) {
        let format = MDLVertexFormat(rawValue: MDLVertexAttribute.named("a_Position")!.mask | MDLVertexAttribute.all[7].mask)
        var data = Data()
        for (position, uv) in points {
            for value in [position.x, position.y, 0, uv.x, uv.y] {
                withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
            }
        }
        XCTAssertEqual(format.stride, 20)
        return (data, format)
    }

    func testRigLaidOutLikeItsTextureIsDetected() {
        let (data, format) = vertices([(SIMD2(-1920, 1500), SIMD2(0, 0)), (SIMD2(0, 0), SIMD2(0.5, 0.5)),
                                       (SIMD2(960, -750), SIMD2(0.75, 0.75))])
        XCTAssertTrue(ScenePuppetPlan.isTextureLayout(data, format: format, imageSize: size))
    }

    func testAtlasRigIsDetected() {
        // The second vertex reads the atlas's corner but is assembled at the centre.
        let (data, format) = vertices([(SIMD2(-1920, 1500), SIMD2(0, 0)), (SIMD2(0, 0), SIMD2(0.1, 0.1))])
        XCTAssertFalse(ScenePuppetPlan.isTextureLayout(data, format: format, imageSize: size))
    }

    // MARK: Compositing

    /// Two parts laid over each other: the later one's transparent texels leave the earlier one
    /// showing, as the mesh draws over itself in WE, rather than replacing it.
    func testEffectOutputPartsCompositeOverEachOther() throws {
        let setup = try PuppetSetup()
        var pixels: [UInt8] = []
        for _ in 0..<16 { for x in 0..<32 { pixels += x < 16 ? [255, 0, 0, 255] : [0, 0, 255, 0] } }
        let image = ScenePuppetTests.Picture(width: 32, height: 16, pixels: pixels)
        // Both quads cover the whole image; the first reads the opaque half, the second the clear one.
        let mesh = ScenePuppetTests.mesh(quads: [(SIMD4(-16, 8, 16, -8), SIMD4(0, 0, 0.25, 1)),
                                                 (SIMD4(-16, 8, 16, -8), SIMD4(0.75, 0, 1, 1))])
        let plan = try setup.plan(mesh, bones: 1, size: SIMD2(32, 16))
        XCTAssertFalse(plan.bindPoseIsTextureLayout)
        XCTAssertTrue(setup.renderer.prepareLayer(plan, layerID: "p"))
        let texture = try ScenePuppetTests.texture(image, device: setup.device)
        let commands = try XCTUnwrap(setup.queue.makeCommandBuffer())
        let warped = try XCTUnwrap(setup.renderer.warp(plan, layerID: "p", key: "_effects", texture: texture, contentSize: nil,
                                                       pose: .bind(boneCount: 1), redraw: true, blended: true,
                                                       commandBuffer: commands))
        commands.commit()
        commands.waitUntilCompleted()
        let texels = try ScenePuppetTestSupport.rgba8(warped, device: setup.device)
        for index in stride(from: 0, to: texels.count, by: 4) {
            XCTAssertEqual(Array(texels[index..<index + 4]), [255, 0, 0, 255])
        }
    }
}
