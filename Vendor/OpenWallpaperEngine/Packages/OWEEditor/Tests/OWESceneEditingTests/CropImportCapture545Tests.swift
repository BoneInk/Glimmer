import XCTest
@testable import OWESceneEditing

/// WE 2.8.0.42 capture 545: Import Image with Crop transparent area on and Padding 50, of a 512 × 512
/// picture whose figure covers 206…440 × 80…400. WE cut it to 335 × 421, wrote the model's
/// `"cropoffset": "67.50000 15.50000"` and placed the layer at (1027.5, 555.5), 960 + 67.5 and
/// 540 + 15.5, so the figure stays where it was in the full frame.
final class CropImportCapture545Tests: XCTestCase {
    static let picture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Tests/Fixtures/CropImport545/figure3.png")

    func testACroppedImportRecordsWEsCropOffset() throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EditorAssetStore(directory: directory)
        var options = TextureImportOptions()
        options.cropTransparency = true
        options.cropPadding = 50
        let imported = try store.importImage(from: Self.picture, options: options)
        XCTAssertEqual(imported.size, SIMD2(335, 421))
        XCTAssertEqual(imported.cropOffset, SIMD2(67.5, 15.5))
        let model = try XCTUnwrap(store.url(for: imported.model))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: model)) as? [String: Any])
        XCTAssertEqual(json["cropoffset"] as? String, "67.50000 15.50000")
        XCTAssertEqual(json["autosize"] as? Bool, true)

        // Without the crop, no offset.
        let plain = try store.importImage(from: Self.picture, options: TextureImportOptions())
        XCTAssertNil(plain.cropOffset)
        let plainModel = try XCTUnwrap(store.url(for: plain.model))
        XCTAssertNil((try JSONSerialization.jsonObject(with: Data(contentsOf: plainModel)) as? [String: Any])?["cropoffset"])
    }
}
