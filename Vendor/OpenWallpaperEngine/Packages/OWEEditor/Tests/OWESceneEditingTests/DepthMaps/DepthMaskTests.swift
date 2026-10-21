import XCTest
@testable import OWESceneEditing

/// A depth map shaped into an effect mask (Invert, Contrast) and kept where WE keeps a painted
/// effect mask.
final class DepthMaskTests: XCTestCase {
    func testAsItIsNearShowsTheEffect() {
        XCTAssertEqual(DepthMask.shaped([0, 64, 128, 255], invert: false, contrast: 1), [0, 64, 128, 255])
    }

    func testInvertSwapsNearAndFar() {
        XCTAssertEqual(DepthMask.shaped([0, 64, 255], invert: true, contrast: 1), [255, 191, 0])
    }

    func testContrastScalesAroundTheMiddleAndClamps() {
        XCTAssertEqual(DepthMask.shaped([0, 60, 100, 128, 150, 255], invert: false, contrast: 3), [0, 0, 45, 129, 195, 255])
        XCTAssertEqual(DepthMask.shaped([0, 255], invert: false, contrast: 0.5), [64, 191], "softer below 1")
        XCTAssertEqual(DepthMask.shaped([0], invert: false, contrast: 100), [0], "kept in range")
        XCTAssertEqual(DepthMask.shaped([255], invert: true, contrast: 4), [0])
    }

    func testTheMaskIsKeptAsWEKeepsAnEffectMask() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "owe-depthmask-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) } // Scratch: a leftover is harmless.
        let store = EditorAssetStore(directory: directory)
        let tex = Data("TEXV0005".utf8) + Data([1, 2, 3])
        let path = try store.saveEffectMask(tex, name: "waterripple")
        XCTAssertNotNil(path.range(of: "^masks/waterripple_mask_[0-9a-f]{12}$", options: .regularExpression), path)
        let url = try XCTUnwrap(store.url(for: "materials/\(path).tex"))
        XCTAssertEqual(try Data(contentsOf: url), tex)
        XCTAssertEqual(try store.saveEffectMask(tex, name: "waterripple"), path, "named by content")
        XCTAssertNotEqual(try store.saveEffectMask(tex + Data([4]), name: "waterripple"), path)
        XCTAssertTrue(try store.saveEffectMask(tex, name: "blur_combine").hasPrefix("masks/blur_combine_mask_"))
    }
}
