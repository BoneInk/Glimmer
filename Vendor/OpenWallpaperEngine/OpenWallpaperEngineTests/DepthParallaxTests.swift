import XCTest
import OWEEditor
import OWESceneEditing
@testable import OpenWallpaperEngine

/// Depth parallax in the app: Scene Edit / Export's edits going to the overlay the Wallpaper Editor
/// reads (one source of truth), the still frame's layers and crop, and WE's depth parallax effect
/// bound to a generated depth map, rendered headlessly by the real renderer.
@MainActor
final class DepthParallaxTests: XCTestCase {
    private var scratch: URL!

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appending(path: "owe-depthparallax-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: scratch) // Scratch: a leftover is harmless.
    }

    // MARK: Both editors, one overlay

    private func makeWallpaper() throws -> WEWallpaper {
        let directory = scratch.appending(path: "wallpaper-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scene = """
        {"general": {"orthogonalprojection": {"width": 1920, "height": 1080}},
         "objects": [{"id": 7, "name": "Photo", "image": "models/photo.json", "origin": "960 540 0", "size": "1920 1080"},
                     {"id": 8, "name": "Rain", "particle": "particles/rain.json", "origin": "960 540 0"}]}
        """
        try Data(scene.utf8).write(to: directory.appending(path: "scene.json"))
        let project = #"{"file": "scene.json", "title": "Depth \#(UUID().uuidString)", "type": "scene"}"#
        try Data(project.utf8).write(to: directory.appending(path: "project.json"))
        return WEWallpaper(using: WEProject(file: "scene.json", preview: "preview.jpg", title: "Depth", type: "scene"), where: directory)
    }

    func testTheSceneEditorStoresDepthParallaxInTheWallpaperEditorsOverlay() throws {
        let wallpaper = try makeWallpaper()
        let identity = WallpaperSettingsIdentity.resolve(directory: wallpaper.wallpaperDirectory)
        defer { try? SceneEditOverlayFiles.defaultStore.remove(identity.rawValue) } // The isolated tests' store.
        let host = SceneEditorDepthMapHost(wallpaper: wallpaper, generator: DepthMapPlugin.makeGenerator())
        let session = try XCTUnwrap(host.session)
        XCTAssertNotNil(host.services)
        let texture = "depth/editor_photo-0123456789ab"

        // Scene Edit / Export applies it…
        session.applyDepthParallax(texture: texture, strength: 0.8, to: 7, actionName: "Apply")
        let saved = try XCTUnwrap(SceneEditOverlayFiles.overlay(for: identity))
        XCTAssertEqual(saved, session.overlay, "saved where the Wallpaper Editor keeps its edits")

        // …the Wallpaper Editor opens the same overlay and sees it…
        let source = try WallpaperEditorSource.read(wallpaper)
        let editor = SceneEditSession(outline: try SceneOutline(sceneData: source.scene),
                                      overlay: SceneEditOverlayFiles.overlay(for: identity) ?? SceneEditOverlay())
        XCTAssertEqual(editor.depthParallaxTexture(of: 7), texture)
        XCTAssertEqual(try XCTUnwrap(editor.depthParallaxStrength(of: 7)), 0.8, accuracy: 1e-9)

        // …adds scene depth parallax and saves, and Scene Edit / Export follows.
        editor.addDepthParallaxLayer(texture: texture, strength: 1, above: nil, name: "Scene Depth Parallax", actionName: "Apply")
        try SceneEditOverlayFiles.save(editor.overlay, for: identity, wallpaperDirectory: wallpaper.wallpaperDirectory,
                                       base: editor.baseOutline)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertNotNil(host.session?.depthParallaxLayer(above: nil))
        XCTAssertEqual(host.session?.overlay, editor.overlay)

        // Removing in Scene Edit / Export is undoable there.
        let current = try XCTUnwrap(host.session)
        current.removeDepthParallax(of: 7, actionName: "Remove")
        XCTAssertNil(SceneEditOverlayFiles.overlay(for: identity).flatMap { overlay in
            try? SceneEditSession(outline: SceneOutline(sceneData: source.scene), overlay: overlay).depthParallaxEffect(of: 7)
        })
        current.undo()
        XCTAssertEqual(try XCTUnwrap(SceneEditOverlayFiles.overlay(for: identity)), current.overlay)
        XCTAssertEqual(current.depthParallaxTexture(of: 7), texture)
    }

    func testAVideoWallpaperHasNoDepthMaps() throws {
        let directory = scratch.appending(path: "video", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let host = SceneEditorDepthMapHost(wallpaper: WEWallpaper(using: WEProject(file: "v.mp4", preview: "p.jpg", title: "V", type: "video"),
                                                                  where: directory))
        XCTAssertNil(host.session)
    }

    // MARK: Text

    /// The plugin's own table (`DepthMaps.xcstrings`): every key in every language, with its
    /// format arguments.
    func testThePluginsTextIsTranslated() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "OpenWallpaperEngine/DepthMaps/DepthMaps.xcstrings")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let strings = try XCTUnwrap(json["strings"] as? [String: [String: Any]])
        let languages = ["ar", "de", "es", "fr", "hi", "it", "ja", "ko", "pl", "pt-BR", "ru", "tr", "uk", "zh-Hans", "zh-Hant"]
        var problems: [String] = []
        for (key, entry) in strings {
            let localizations = entry["localizations"] as? [String: [String: Any]] ?? [:]
            for language in languages {
                let unit = localizations[language]?["stringUnit"] as? [String: Any]
                guard let value = unit?["value"] as? String, !value.isEmpty, unit?["state"] as? String == "translated" else {
                    problems.append("\(language): \(key)")
                    continue
                }
                if value.components(separatedBy: "%@").count != key.components(separatedBy: "%@").count {
                    problems.append("\(language): \(key) loses its argument")
                }
            }
        }
        XCTAssertEqual(problems, [])
        XCTAssertGreaterThan(strings.count, 10)
    }

    // MARK: The still frame

    func testTheStillFrameHidesTheLayersNotAskedFor() {
        let overlay = DepthMapSceneCapture.overlay(SceneEditOverlay(), drawing: [1, 3], of: [1, 2, 3, 4])
        XCTAssertNil(overlay.field("visible", of: 1))
        XCTAssertEqual(overlay.field("visible", of: 2), .bool(false))
        XCTAssertNil(overlay.field("visible", of: 3))
        XCTAssertEqual(overlay.field("visible", of: 4), .bool(false))
        XCTAssertEqual(DepthMapSceneCapture.overlay(overlay, drawing: nil, of: [1, 2]), overlay, "nil draws everything")
    }

    func testTheLayersRectangleIsCutOutOfTheFrame() throws {
        let size = SIMD2<Double>(1920, 1080)
        let rect = CGRect(x: 1600, y: 850, width: 200, height: 100)
        XCTAssertEqual(DepthMapSceneCapture.pixelRect(of: rect, sceneSize: size, pixels: SIMD2(1920, 1080)),
                       CGRect(x: 1600, y: 130, width: 200, height: 100), "scene y is up, pixels' y is down")
        XCTAssertEqual(DepthMapSceneCapture.pixelRect(of: rect, sceneSize: size, pixels: SIMD2(960, 540)),
                       CGRect(x: 800, y: 65, width: 100, height: 50))
        XCTAssertEqual(DepthMapSceneCapture.pixelRect(of: CGRect(x: 1800, y: -50, width: 400, height: 100), sceneSize: size,
                                                      pixels: SIMD2(1920, 1080)),
                       CGRect(x: 1800, y: 1030, width: 120, height: 50), "clamped to the frame")
        XCTAssertNil(DepthMapSceneCapture.pixelRect(of: CGRect(x: 3000, y: 0, width: 10, height: 10), sceneSize: size,
                                                    pixels: SIMD2(1920, 1080)))
        XCTAssertEqual(DepthMapSceneCapture.pixelSize(for: SIMD2(8000, 4000)), SIMD2(4096, 2048))
        XCTAssertEqual(DepthMapSceneCapture.pixelSize(for: SIMD2(1920, 1080)), SIMD2(1920, 1080))
        XCTAssertEqual(DepthMapSceneCapture.pixelSize(for: nil), SIMD2(1920, 1080))
    }

    // MARK: Rendering

    /// WE's depth parallax on the effect gallery's checkerboard layer, bound through the overlay to
    /// a generated depth map (a fake one: a bump, near in the middle) and baked as Save as Local
    /// Wallpaper bakes it, drawn headlessly: it changes the picture, and it follows the pointer.
    func testTheEffectBoundToAGeneratedDepthMapRendersAndFollowsThePointer() throws {
        try XCTSkipUnless(Fixtures.hasWEShaderSources, "WE's effect shader sources aren't available")
        let assets = try XCTUnwrap(WallpaperEngineAssets.directory)
        let control = try WEEffectGallery.makeProject(effect: nil, name: "depth-control", assets: assets, in: scratch)
        let directory = try WEEffectGallery.makeProject(effect: nil, name: "depth-generated", assets: assets, in: scratch)
        // What preparing the effect does: WE's files copied into the project.
        try WEEffectGallery.copyEffect(SceneDepthParallax.folderName, assets: assets, into: directory)

        var depth = DepthMapBuffer(width: 256, height: 256)
        for y in 0..<256 {
            for x in 0..<256 {
                let dx = Float(x - 128) / 128, dy = Float(y - 128) / 128
                depth[x, y] = max(0, 1 - (dx * dx + dy * dy))
            }
        }
        let png = try XCTUnwrap(depth.pngData())
        // The editor's files are merged into a saved copy (`LocalWallpaperWriter`): here, the project.
        let texture = try EditorAssetStore(directory: directory).saveDepthMap(png, title: "checkerboard")
        let sceneURL = directory.appending(path: "scene.json")
        let sceneData = try Data(contentsOf: sceneURL)
        let session = SceneEditSession(outline: try SceneOutline(sceneData: sceneData))
        // As authored, camera parallax is off: `g_ParallaxPosition` stays put until the plugin's
        // apply turns it on.
        XCTAssertNotEqual(session.authoredOutline.general["cameraparallax"]?.boolValue, true)
        _ = try XCTUnwrap(session.applyDepthParallax(texture: texture, strength: 1, to: 10, actionName: "Apply"))
        try session.overlay.applied(to: sceneData).write(to: sceneURL)

        let left = try render(directory, cursor: SIMD2(200, 540))
        let right = try render(directory, cursor: SIMD2(1720, 540))
        let plain = try render(control, cursor: SIMD2(200, 540))
        XCTAssertGreaterThan(WEEffectGallery.meanAbsoluteDifference(left, plain), 0.5, "the effect draws")
        XCTAssertGreaterThan(WEEffectGallery.meanAbsoluteDifference(left, right), 0.5, "it follows the pointer")
    }

    private func render(_ directory: URL, cursor: SIMD2<Double>) throws -> WEReferenceImage {
        let project = try decodeTolerant(WEProject.self, from: Data(contentsOf: directory.appending(path: "project.json")))
        var settings = SceneRenderSettings()
        settings.postProcessing = .enabled
        settings.textureReduction = 1
        settings.sceneDetail = .full
        settings.renderResolution = .yourDisplay
        let renderer = WEReferenceRenderer(directory: directory, project: project, settings: settings,
                                           storage: scratch.appending(path: "storage-\(UUID().uuidString)"))
        defer { Fixtures.removeStoredSettings(for: directory) }
        return try XCTUnwrap(try renderer.render([WEReferenceRenderer.Shot(time: 2, cursor: cursor)]).first)
    }
}
