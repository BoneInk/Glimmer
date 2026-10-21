import XCTest
@testable import OpenWallpaperEngine

/// An image object without a `size` whose model declares `width` and `height` (WE's templates, no
/// `autosize`) is that big, not as big as its material's first texture. Deep Space's flowing
/// galaxy (`deep_space`, `flowimage`) names a 480 × 270 flow mask first: drawn at the mask's size
/// it covered a sixteenth of the screen, and the scene seemed not to move.
final class ModelDeclaredSizeTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "owe-model-size-\(UUID().uuidString)")
        try Self.writeScene(to: directory)
    }

    override func tearDownWithError() throws {
        if let directory {
            Fixtures.removeStoredSettings(for: directory)
            try? FileManager.default.removeItem(at: directory) // Optional: a temporary folder.
        }
    }

    func testAnUnsizedObjectTakesItsModelsSize() throws {
        let project = try JSONDecoder().decode(WEProject.self, from: Data(contentsOf: directory.appending(path: "project.json")))
        let model = SceneContentLoader(wallpaper: WEWallpaper(using: project, where: directory))
        let content = try XCTUnwrap(model.metalContent())
        XCTAssertEqual(content.layers.first { $0.id == "1" }?.size, SIMD2(64, 32), "the model's width and height")
        XCTAssertEqual(content.layers.first { $0.id == "2" }?.size, SIMD2(8, 4), "an autosize model: its texture's size")
        XCTAssertEqual(content.layers.first { $0.id == "3" }?.size, SIMD2(20, 10), "the object's own size first")
    }

    /// Deep Space itself (`OWE_LIBRARY`, a folder holding `deep_space`): its flowing layer covers
    /// the scene.
    func testDeepSpacesFlowingLayerCoversTheScene() throws {
        let roots: [Substring] = ProcessInfo.processInfo.environment["OWE_LIBRARY"]?.split(separator: ":") ?? []
        let found: URL? = roots.map { URL(fileURLWithPath: String($0)).appending(path: "deep_space") }
            .first { FileManager.default.fileExists(atPath: $0.appending(path: "project.json").path) }
        guard let library = found else { throw XCTSkip("OWE_LIBRARY holds no deep_space") }
        let project = try JSONDecoder().decode(WEProject.self, from: Data(contentsOf: library.appending(path: "project.json")))
        let model = SceneContentLoader(wallpaper: WEWallpaper(using: project, where: library))
        defer { Fixtures.removeStoredSettings(for: library) }
        let content = try XCTUnwrap(model.metalContent())
        XCTAssertEqual(content.layers.first { $0.name == "Background" }?.size, SIMD2(1920, 1080))
    }

    // MARK: - Fixture

    /// Three unsized-texture objects over one 8 × 4 image: a model with `width`/`height`, an
    /// `autosize` model, and the first model placed with an explicit `size`.
    static func writeScene(to directory: URL) throws {
        let manager = FileManager.default
        for folder in ["materials", "models"] {
            try manager.createDirectory(at: directory.appending(path: folder), withIntermediateDirectories: true)
        }
        let tex = TextureReductionTests.tex(format: 0, image: SIMD2(8, 4),
                                            mipmaps: [(SIMD2(8, 4), [UInt8](repeating: 255, count: 8 * 4 * 4))])
        try tex.write(to: directory.appending(path: "materials/mask.tex"))
        let files = [
            "materials/mask.json": #"{"passes":[{"blending":"translucent","shader":"genericimage2","textures":["mask"]}]}"#,
            "models/declared.json": #"{"width":64,"height":32,"material":"materials/mask.json"}"#,
            "models/auto.json": #"{"autosize":true,"material":"materials/mask.json"}"#,
            "scene.json": #"{"camera":{"center":"0 0 -1","eye":"0 0 0","up":"0 1 0"},"version":1,"general":{"clearcolor":"0 0 0","orthogonalprojection":{"width":128,"height":64}},"objects":[{"id":1,"name":"declared","image":"models/declared.json","origin":"32 32 0"},{"id":2,"name":"auto","image":"models/auto.json","origin":"96 32 0"},{"id":3,"name":"sized","image":"models/declared.json","origin":"96 48 0","size":"20 10"}]}"#,
            "project.json": #"{"file":"scene.json","title":"Fixture: a model's declared size","type":"scene"}"#,
        ]
        for (path, text) in files { try Data(text.utf8).write(to: directory.appending(path: path)) }
    }
}
