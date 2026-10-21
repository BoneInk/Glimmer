import XCTest
import simd
@testable import OpenWallpaperEngine

/// `{"auto": true}` scenes and unsized images against WE 2.8 (docs/models-plan.md §5.21,
/// tools/peer/requests/owe-beta3/models-open/521-auto-size/README.md): an `autosize` image a script
/// moves follows the script (about 59 px/s for 60 px/s set, no per-frame re-centring); an image
/// without `size` takes its texture's size, and an `auto` scene takes that size from it (WE's GIF
/// template, `assets/scenes/gifs/gifscene.json`, writes no `size`; the 521 capture had a fixed
/// projection, so its 1920×1080 was the projection's, not `auto`'s).
final class OrthographicAutoSceneTests: XCTestCase {
    private var directory: URL!
    private var storage: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "owe-auto-scene-\(UUID().uuidString)")
        storage = FileManager.default.temporaryDirectory.appending(path: "owe-auto-scripts-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let directory, FileManager.default.fileExists(atPath: directory.path) {
            Fixtures.removeStoredSettings(for: directory)
            try FileManager.default.removeItem(at: directory)
        }
        if let storage, FileManager.default.fileExists(atPath: storage.path) { try FileManager.default.removeItem(at: storage) }
    }

    /// The first image names a size: it sizes the scene and is put at its centre, once, at load.
    func testASizedFirstImageSizesTheSceneAndIsCentred() throws {
        let content = try content(image: #""origin": "5 5 0", "size": "400 200""#)
        XCTAssertEqual(content.size, SIMD2(400, 200))
        let layer = try XCTUnwrap(content.layers.first { $0.id == "1" })
        XCTAssertEqual(layer.position, SIMD2(200, 100))
        XCTAssertEqual(layer.size, SIMD2(400, 200))
    }

    /// Without `size` the image is its texture's size, and the scene is that size, the image
    /// filling it: a GIF wallpaper made with WE's template fills the display.
    func testAnUnsizedImageSizesTheSceneFromItsTexture() throws {
        let content = try content(image: #""origin": "5 5 0""#)
        XCTAssertEqual(content.size, SIMD2(8, 4), "the texture's size")
        let layer = try XCTUnwrap(content.layers.first { $0.id == "1" })
        XCTAssertEqual(layer.size, SIMD2(8, 4), "the texture's size")
        XCTAssertEqual(layer.position, SIMD2(4, 2), "centred in it")
    }

    /// The exports and Scene Edit / Export measure the same size from the wallpaper's files.
    func testTheDrawnSizeReadsTheTexture() throws {
        _ = try content(image: #""origin": "5 5 0""#)
        let sceneData = try Data(contentsOf: directory.appending(path: "scene.json"))
        let read: (String) -> Data? = { try? Data(contentsOf: self.directory.appending(path: $0)) }
        XCTAssertEqual(try SceneDrawnSize.of(sceneData: sceneData, overlay: nil, readAsset: read), SIMD2(8, 4))
        XCTAssertEqual(try SceneDrawnSize.of(sceneData: sceneData, overlay: nil), SIMD2(1920, 1080),
                       "without the files, WE's default canvas")
    }

    /// The renderer reports the centred origin; a script's `x = 960 + 60·t` wins every frame, and
    /// nothing puts the image back in the centre.
    func testAScriptMovesTheCentredImage() throws {
        let script = "let t = 0; export function update(value) { t += engine.frametime; value.x = 960 + 60 * t; return value; }"
        let encoded = String(decoding: try JSONEncoder().encode(script), as: UTF8.self)
        let text = #"{"general": {"orthogonalprojection": {"auto": true}}, "objects": [{"id": 1, "name": "Image", "image": "models/auto.json", "origin": {"script": \#(encoded), "value": "960 540 0"}}]}"#
        let document = try SceneScriptSiteBuilder.document(from: Data(text.utf8))
        let content = SceneScriptSceneContent(wallpaperID: "auto-\(UUID().uuidString.prefix(8))", document: document,
                                              documentSignature: "1", project: nil, userValues: { [:] },
                                              file: { _ in nil }, makeLayer: { _ in nil })
        let services = SceneScriptServices(prelude: SceneScriptPrelude.load(), storage: SceneScriptStorage(directory: storage),
                                           media: SceneScriptReplayMediaSource(), spectrum: { .silent })
        let wallpaper = try XCTUnwrap(try SceneScriptWallpaper(content: content, services: services, screenID: "test"))
        addTeardownBlock { wallpaper.tearDown(); wallpaper.waitUntilIdle() }

        var xs: [Float] = []
        for _ in 0..<4 {
            var input = SceneScriptFrameInput()
            input.deltaTime = 1
            let centre = SIMD2<Float>(960, 540)
            input.objects[1] = SceneScriptObjectFeedback(origin: centre, scale: SIMD2(1, 1), angle: 0, alpha: nil, color: nil,
                                                         visible: true, size: nil,
                                                         world: SceneAffineTransform(SceneLocalTransform(origin: centre, scale: SIMD2(1, 1), angle: 0)))
            wallpaper.submit(input)
            wallpaper.waitUntilIdle()
            let state = try XCTUnwrap(wallpaper.take().state)
            xs.append(try XCTUnwrap(state.objects[1]?.vector3(.origin)).x)
        }
        XCTAssertEqual(xs, [1020, 1080, 1140, 1200], "the script's origin, 60 px per second, not the centre")
    }

    // MARK: - Support

    /// A `{"auto": true}` scene whose one image (`autosize`, an 8 × 4 texture) has `fields`.
    private func content(image fields: String) throws -> SceneMetalContent {
        let manager = FileManager.default
        for folder in ["materials", "models"] {
            try manager.createDirectory(at: directory.appending(path: folder), withIntermediateDirectories: true)
        }
        let tex = TextureReductionTests.tex(format: 0, image: SIMD2(8, 4),
                                            mipmaps: [(SIMD2(8, 4), [UInt8](repeating: 255, count: 8 * 4 * 4))])
        try tex.write(to: directory.appending(path: "materials/mask.tex"))
        let files = [
            "materials/mask.json": #"{"passes":[{"blending":"translucent","shader":"genericimage2","textures":["mask"]}]}"#,
            "models/auto.json": #"{"autosize":true,"material":"materials/mask.json"}"#,
            "scene.json": #"{"camera":{"center":"0 0 -1","eye":"0 0 0","up":"0 1 0"},"version":1,"general":{"clearcolor":"0 0 0","orthogonalprojection":{"auto":true}},"objects":[{"id":1,"name":"auto","image":"models/auto.json",\#(fields)}]}"#,
            "project.json": #"{"file":"scene.json","title":"Fixture: an auto-sized scene","type":"scene"}"#,
        ]
        for (path, text) in files { try Data(text.utf8).write(to: directory.appending(path: path)) }
        let project = try JSONDecoder().decode(WEProject.self, from: Data(contentsOf: directory.appending(path: "project.json")))
        let model = SceneContentLoader(wallpaper: WEWallpaper(using: project, where: directory))
        return try XCTUnwrap(model.metalContent())
    }
}
