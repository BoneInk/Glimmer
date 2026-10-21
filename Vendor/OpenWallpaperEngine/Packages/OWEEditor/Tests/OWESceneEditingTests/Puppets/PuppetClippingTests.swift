import CoreGraphics
import XCTest
import simd
@testable import OWESceneEditing

/// Puppet Warp clipping masks in the editor (docs/models-plan.md §2.13a): WE 2.8.0.42's own files
/// (capture 532, `Tests/Fixtures/Models/PuppetGroundTruth532`) open with their masks and save
/// them back; masks assigned in the editor split the ranges by limb and become groups.
final class PuppetClippingTests: XCTestCase {
    private static let folder = PuppetFixtureRigTests.models.appending(path: "PuppetGroundTruth532")

    private static func open(_ name: String) throws -> PuppetDocument {
        try PuppetMDLReader.read(try Data(contentsOf: folder.appending(path: "\(name).mdl")), imageSize: SIMD2(512, 256))
    }

    /// The groups WE's file holds, read back from bytes.
    private static func groups(_ data: Data) throws -> (ranges: [SIMD4<UInt32>], groups: [PuppetMDLReader.Group]) {
        let ranges = try PuppetMDLReader.read(data, imageSize: SIMD2(512, 256)).preserved.boneRanges ?? []
        return (ranges, try PuppetMDLReader.rawGroups(data))
    }

    /// g_mask: the blue limb clipped by mask 30, painted over the red one.
    func testWEsMaskOpensOnItsLimbs() throws {
        let document = try Self.open("g_mask")
        XCTAssertEqual(document.mesh.islandCount, 2)
        let clipping = try XCTUnwrap(document.clipping)
        XCTAssertEqual(clipping.masks.map(\.id), [30])
        XCTAssertEqual(clipping.masks[0].texture, "masks/clipping_mask_608392ae")
        XCTAssertFalse(clipping.masks[0].invert)
        XCTAssertFalse(clipping.masks[0].hidesMaskGeometry)
        // The red bar's island is the masking limb, the blue one's the clipped.
        let red = try XCTUnwrap(clipping.masks[0].maskingLimbs.first)
        XCTAssertEqual(clipping.masks[0].maskingLimbs, [red])
        XCTAssertEqual(clipping.limbs.compactMap { $0?.mask }, [30])
        XCTAssertNil(clipping.limbs[red])
        XCTAssertTrue(try Self.open("g_mask_hide").clipping?.masks.first?.hidesMaskGeometry == true)
        XCTAssertTrue(try Self.open("g_mask_invert").clipping?.masks.first?.invert == true)
        XCTAssertNil(try Self.open("g_locked").clipping)
    }

    /// Saved again, each file has the ranges and groups WE wrote.
    func testWEsMasksSaveBackAsTheyWere() throws {
        for name in ["g_mask", "g_mask_hide", "g_mask_invert"] {
            let original = try Data(contentsOf: Self.folder.appending(path: "\(name).mdl"))
            let saved = try PuppetMDLWriter.write(try Self.open(name))
            let before = try Self.groups(original), after = try Self.groups(saved)
            XCTAssertEqual(after.ranges, before.ranges, name)
            XCTAssertEqual(after.groups.map(\.id), before.groups.map(\.id), name)
            XCTAssertEqual(after.groups.map(\.texture), before.groups.map(\.texture), name)
            XCTAssertEqual(after.groups.map(\.flags), before.groups.map(\.flags), name)
            XCTAssertEqual(after.groups.map(\.clipped), before.groups.map(\.clipped), name)
            XCTAssertEqual(after.groups.map(\.masking), before.groups.map(\.masking), name)
        }
    }

    /// Removing the only mask leaves the limb unclipped: no groups, and the split ranges stay.
    func testRemovingTheMaskWritesNoGroup() throws {
        var document = try Self.open("g_mask")
        let blue = try XCTUnwrap(document.clipping?.limbs.firstIndex { $0 != nil })
        document.removeClippingMask(from: blue)
        XCTAssertNil(document.clipping)
        let saved = try Self.groups(try PuppetMDLWriter.write(document))
        XCTAssertEqual(saved.groups.count, 0)
        XCTAssertEqual(saved.ranges.count, 3)
    }

    /// The docs' setup made in the editor: two separate limbs, the second clipped by a mask painted
    /// over the first. The ranges split at the limbs without moving a triangle; the group clips the
    /// second limb's ranges and is drawn through the first's; Invert, Hide and Additive set its flags.
    func testAnAssignedMaskSplitsTheRangesByLimb() throws {
        var document = PuppetDocument.new(imageSize: SIMD2(40, 20), material: "materials/two.json")
        func quad(_ x0: Float, _ x1: Float) -> [PuppetVertex] {
            [SIMD2(x0, -10), SIMD2(x1, -10), SIMD2(x1, 10), SIMD2(x0, 10)].map { PuppetVertex(position: $0, uv: document.textureCoordinate(of: $0)) }
        }
        document.replaceMesh(PuppetMesh(vertices: quad(-20, 0) + quad(0, 20),
                                        triangles: [SIMD3(0, 1, 2), SIMD3(0, 2, 3), SIMD3(4, 5, 6), SIMD3(4, 6, 7)]))
        document.weights = document.mesh.vertices.map { _ in [PuppetWeight(bone: 0, weight: 1)] }
        XCTAssertEqual(document.mesh.islands, [0, 0, 1, 1])
        XCTAssertEqual(document.limb(at: SIMD2(10, 0)), 1)

        let id = document.addClippingMask(named: "maskA", to: 1)
        // Painted over the left half: the first limb.
        let painted = try XCTUnwrap(Self.mask(width: 40, height: 20) { x, _ in x < 20 })
        let limbs = PuppetClipping.paintedLimbs(document.mesh, islands: document.mesh.islands, painted: painted)
        XCTAssertEqual(limbs, [0])
        document.updateClippingMask(id) { $0.texture = "masks/editor_clipping_mask"; $0.maskingLimbs = limbs }

        var written = try Self.groups(try PuppetMDLWriter.write(document))
        XCTAssertEqual(written.ranges, [SIMD4(0, 0, 0, 6), SIMD4(0, 0, 6, 6)])
        XCTAssertEqual(written.groups.count, 1)
        XCTAssertEqual(written.groups[0].id, id)
        XCTAssertEqual(written.groups[0].texture, "masks/editor_clipping_mask")
        XCTAssertEqual(written.groups[0].flags, 0)
        XCTAssertEqual(written.groups[0].clipped, [1])
        XCTAssertEqual(written.groups[0].masking, [0])

        document.updateClippingMask(id) { $0.invert = true; $0.hidesMaskGeometry = true }
        document.setClippingAdditive(true, limb: 1)
        written = try Self.groups(try PuppetMDLWriter.write(document))
        XCTAssertEqual(written.groups[0].flags, 0x1 | 0x2 | 0x4 | 0x8)

        // The mesh's topology changes to another limb count: the limbs are unassigned.
        document.deleteVertices([7])
        XCTAssertEqual(document.mesh.islandCount, 2, "one triangle of the second quad is left")
        XCTAssertTrue(document.clipping?.isActive ?? false, "as many limbs: kept")
        document.deleteVertices([4])
        XCTAssertEqual(document.mesh.islandCount, 1)
        XCTAssertFalse(document.clipping?.isActive ?? false)
    }

    /// A mask nested back into the mask that clips it is flagged (the docs' A → B → A).
    func testAMaskNestedBackIsFlagged() {
        var clipping = PuppetClipping(masks: [PuppetClipping.Mask(id: 1, name: "A", maskingLimbs: [0]),
                                              PuppetClipping.Mask(id: 2, name: "B", maskingLimbs: [1])],
                                      limbs: [PuppetClipping.Limb(mask: 2), PuppetClipping.Limb(mask: 1)])
        var document = PuppetDocument.new(imageSize: SIMD2(4, 4), material: "m.json")
        document.clipping = clipping
        XCTAssertTrue(document.hasIncorrectlyNestedClippingMask)
        clipping.limbs[0] = nil
        document.clipping = clipping
        XCTAssertFalse(document.hasIncorrectlyNestedClippingMask)
    }

    /// A grey mask, white where `painted`, rows from the top.
    private static func mask(width: Int, height: Int, painted: (Int, Int) -> Bool) -> CGImage? {
        var bytes = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width where painted(x, y) { bytes[y * width + x] = 255 } }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
