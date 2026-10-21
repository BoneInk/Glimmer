import XCTest
@testable import OpenWallpaperEngine

/// WE 2.8.0.42's importer turns Clamp UVs on by default and writes it into the `.tex` (TEXI flags
/// bit 2). The renderer takes a texture's addressing from that flag alone, so nothing it assumes
/// runs against the default: a flagged `.tex` clamps, an unflagged one repeats (the user turned it
/// off), and an image that isn't a `.tex` clamps.
final class TexClampUVsDefaultTests: XCTestCase {
    private func builder(files: [String: Data]) -> ImageMaterialPlanBuilder {
        let cache = FileManager.default.temporaryDirectory.appending(path: "owe-clamp-\(UUID().uuidString)")
        return ImageMaterialPlanBuilder(translator: ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: cache),
                                        readFile: { files[$0] }, loadTexture: { _, _ in nil })
    }

    private func tex(flags: UInt32) -> Data {
        var bytes = Array("TEXV0005\0TEXI0001\0".utf8)
        bytes += [0, 0, 0, 0] + withUnsafeBytes(of: flags.littleEndian, Array.init) + [16, 0, 0, 0]
        return Data(bytes)
    }

    func testClampUVsFollowsTheImportersFlag() {
        let builder = builder(files: ["materials/clamped.tex": tex(flags: 2), "materials/wrapped.tex": tex(flags: 0),
                                      "materials/clampedsmooth.tex": tex(flags: 2 | 1)])
        XCTAssertTrue(builder.textureClamps("clamped", materialPath: "materials/layer.json"), "imported with the default")
        XCTAssertTrue(builder.textureClamps("clampedsmooth", materialPath: "materials/layer.json"))
        XCTAssertFalse(builder.textureClamps("wrapped", materialPath: "materials/layer.json"), "Clamp UVs turned off")
        XCTAssertTrue(builder.textureClamps("photo", materialPath: "materials/layer.json"), "not a .tex: clamps")
    }
}
