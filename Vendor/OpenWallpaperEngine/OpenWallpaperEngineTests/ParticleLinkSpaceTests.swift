import XCTest
import simd
@testable import OpenWallpaperEngine

/// A child system's links in depth (`ParticleLinkSpace`): WE draws a child through its parent's
/// model matrix times each link's 3D local matrix (origin, angles and scale, 0x1401d09ea…0x1401d0d36);
/// here the 2D emitter carries the plane's part and `space` the rest.
final class ParticleLinkSpaceTests: XCTestCase {
    private func assertEqual(_ a: simd_float4x4, _ b: simd_float4x4, _ message: String = "",
                             file: StaticString = #filePath, line: UInt = #line) {
        for column in 0..<4 {
            let difference: Float = simd_length(a[column] - b[column])
            XCTAssertLessThan(difference, 1e-4, "\(message) column \(column): \(a[column]) vs \(b[column])", file: file, line: line)
        }
    }

    private func local(origin: SIMD3<Float> = .zero, scale: SIMD3<Float> = SIMD3(repeating: 1),
                       degrees: SIMD3<Float> = .zero) -> SceneLocalTransform3D {
        SceneLocalTransform3D(origin: origin, scale: scale, angles: degrees * (Float.pi / 180))
    }

    /// The plane's links leave nothing to carry.
    func testAFlatLinkNeedsNoDepth() {
        let link = local(origin: SIMD3(30, -20, 0), scale: SIMD3(2, 0.5, 1), degrees: SIMD3(0, 0, 40))
        assertEqual(ParticleLinkSpace.identity.appending(link, kind: .static).space, matrix_identity_float4x4)
    }

    /// A static chain's 2D emitters times `space` are its links' 3D product: the depth offset, the
    /// depth scale and the turn out of the plane, nested links included.
    func testStaticLinksCarryTheirDepth() {
        let first = local(origin: SIMD3(30, -20, 15), scale: SIMD3(1, 1, 2), degrees: SIMD3(25, -10, 30))
        let second = local(origin: SIMD3(-5, 40, -8), scale: SIMD3(1.5, 1, 0.5), degrees: SIMD3(-15, 35, -60))
        let one = ParticleLinkSpace.identity.appending(first, kind: .static)
        let flatOne = ParticleLinkSpace.embedded(SceneAffineTransform(first.planar))
        assertEqual(one.space * flatOne, first.matrix, "one link")
        let two = one.appending(second, kind: .static)
        let flatTwo = ParticleLinkSpace.embedded(SceneAffineTransform(first.planar) * SceneAffineTransform(second.planar))
        assertEqual(two.space * flatTwo, first.matrix * second.matrix, "two links")
    }

    /// An event link's instances sit on their parent particles, so its turn out of the plane (which
    /// pivots on the link) stays the 2D emitter's; its depth offset and scale are carried, and so
    /// for every link below it.
    func testEventLinksCarryOnlyTheirDepthOffsetAndScale() {
        let event = local(origin: SIMD3(10, 0, 12), scale: SIMD3(1, 1, 3), degrees: SIMD3(30, 0, 0))
        let below = local(origin: SIMD3(0, 0, -4), degrees: SIMD3(0, 20, 0))
        let space = ParticleLinkSpace.identity.appending(event, kind: .spawn).appending(below, kind: .static).space
        var expected = matrix_identity_float4x4
        expected.columns.2.z = 3
        expected.columns.3.z = 12 + 3 * -4
        assertEqual(space, expected)
    }

    /// The builder hands each child its chain; a root has none.
    func testTheFamilyCarriesEachChildsChain() throws {
        let parent = try JSONDecoder().decode(WEParticleSystem.self, from: Data(#"""
            {"children": [{"name": "child.json", "origin": "0 0 25", "angles": "0 0 0"}]}
            """#.utf8))
        let builder = ParticleFamilyBuilder(
            load: { $0 == "parent.json" ? parent : WEParticleSystem() },
            build: { _, _, _, _ in ParticleTestSystem().configuration },
            report: { XCTFail($0) })
        let family = builder.family("parent.json", world: .identity, overrides: SceneParticleOverrides())
        XCTAssertEqual(family.count, 2)
        assertEqual(family[0].linkSpace, matrix_identity_float4x4, "the root")
        var expected = matrix_identity_float4x4
        expected.columns.3.z = 25
        assertEqual(family[1].linkSpace, expected, "the child")
    }
}
