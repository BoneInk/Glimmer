import XCTest
@testable import OpenWallpaperEngine

/// An image object that names no `size` (an `autosize` model placed by `thisScene.createLayer`, or
/// an authored object without one) is as big as its image, and for a sprite sheet that is one
/// frame, not the atlas the frames are packed in. Dino Run's coins (`createLayer('models/coin_0.json')`,
/// 16 × 16 frames in a 256 × 64 atlas) were drawn 256 × 64.
final class SpriteSheetAutosizeTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "owe-sheet-autosize-\(UUID().uuidString)")
        try Self.writeScene(to: directory)
    }

    override func tearDownWithError() throws {
        if let directory {
            Fixtures.removeStoredSettings(for: directory)
            try? FileManager.default.removeItem(at: directory) // Optional: a temporary folder.
        }
    }

    func testTheFrameSizesAnUnsizedSpriteSheet() throws {
        let data = try Data(contentsOf: directory.appending(path: "materials/sheet.tex"))
        let sheet = try XCTUnwrap(TEXParser(data: data).extractAnimatedImages())
        let source = SceneMetalTextureSource.animated(sheet)
        XCTAssertEqual(source.pixelSize, SIMD2(64, 32), "the atlas")
        XCTAssertEqual(source.unsizedLayerSize, SIMD2(16, 16), "one frame")
    }

    func testAnUnsizedObjectAndACreatedLayerAreOneFrameBig() throws {
        let project = try JSONDecoder().decode(WEProject.self, from: Data(contentsOf: directory.appending(path: "project.json")))
        let model = SceneContentLoader(wallpaper: WEWallpaper(using: project, where: directory))
        let content = try XCTUnwrap(model.metalContent())
        let authored = try XCTUnwrap(content.layers.first { $0.id == "1" }, "the unsized object is built")
        XCTAssertEqual(authored.size, SIMD2(16, 16))

        let makeLayer = try XCTUnwrap(content.scripts?.makeLayer)
        guard case .layer(let created)? = makeLayer(["id": .number(100), "image": .string("models/sheet.json"), "name": .string("made")]) else {
            return XCTFail("createLayer('models/sheet.json') makes an image layer")
        }
        XCTAssertEqual(created.size, SIMD2(16, 16))
    }

    /// WE's Dino Run (`OWE_LIBRARY`, a folder holding `dino_run`): its script's coins are 16 × 16.
    func testDinoRunCoinsAreOneFrameBig() throws {
        let roots: [Substring] = ProcessInfo.processInfo.environment["OWE_LIBRARY"]?.split(separator: ":") ?? []
        let found: URL? = roots.map { URL(fileURLWithPath: String($0)).appending(path: "dino_run") }
            .first { FileManager.default.fileExists(atPath: $0.appending(path: "project.json").path) }
        guard let library = found else { throw XCTSkip("OWE_LIBRARY holds no dino_run") }
        _ = try Fixtures.assets()
        let project = try ModelSceneHarness.project(in: library)
        let model = SceneContentLoader(wallpaper: WEWallpaper(using: project, where: library))
        defer { Fixtures.removeStoredSettings(for: library) }
        let content = try XCTUnwrap(model.metalContent())
        let makeLayer = try XCTUnwrap(content.scripts?.makeLayer)
        guard case .layer(let coin)? = makeLayer(["id": .number(100), "image": .string("models/coin_0.json"), "name": .string("coin")]) else {
            return XCTFail("createLayer('models/coin_0.json') makes an image layer")
        }
        XCTAssertEqual(coin.size, SIMD2(16, 16))
    }

    // MARK: - Fixture

    /// A scene with one unsized image object whose texture is a 64 × 32 RGBA atlas holding four
    /// 16 × 16 frames in its top row (`TEXS0003`).
    static func writeScene(to directory: URL) throws {
        let manager = FileManager.default
        for folder in ["materials", "models"] {
            try manager.createDirectory(at: directory.appending(path: folder), withIntermediateDirectories: true)
        }
        var tex = TextureReductionTests.tex(format: 0, image: SIMD2(64, 32),
                                            mipmaps: [(SIMD2(64, 32), [UInt8](repeating: 255, count: 64 * 32 * 4))])
        tex.append(contentsOf: Array("TEXS0003\u{0}".utf8))
        for value: UInt32 in [4, 16, 16] { TextureReductionTests.word(value, into: &tex) }
        for frame in 0..<4 {
            TextureReductionTests.word(0, into: &tex)
            for value: Float in [0.1, Float(frame * 16), 0, 16, 0, 0, 16] {
                TextureReductionTests.word(value.bitPattern, into: &tex)
            }
        }
        try tex.write(to: directory.appending(path: "materials/sheet.tex"))
        let files = [
            "materials/sheet.json": #"{"passes":[{"blending":"translucent","combos":{"SPRITESHEET":1},"shader":"genericimage2","textures":["sheet"]}]}"#,
            "models/sheet.json": #"{"autosize":true,"material":"materials/sheet.json"}"#,
            "scene.json": #"{"camera":{"center":"0 0 -1","eye":"0 0 0","up":"0 1 0"},"version":1,"general":{"clearcolor":"0 0 0","orthogonalprojection":{"width":64,"height":64}},"objects":[{"id":1,"name":"sheet","image":"models/sheet.json","origin":"32 32 0"}]}"#,
            "project.json": #"{"file":"scene.json","title":"Fixture: unsized sprite sheet","type":"scene"}"#,
        ]
        for (path, text) in files { try Data(text.utf8).write(to: directory.appending(path: path)) }
    }
}
