import MetalKit
import XCTest
import OWESceneEditing
@testable import OpenWallpaperEngine

/// Effects made in the Wallpaper Editor (New / Duplicate Effect): copied from the user's WE
/// assets into the edits, read by the scene loader from there, drawn on the canvas, and written
/// into a wallpaper saved with the edits.
@MainActor
final class WallpaperEditorCustomEffectTests: XCTestCase {
    private static let sceneJSON = """
    {"camera": {"center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"},
     "general": {"orthogonalprojection": {"width": 480, "height": 272}, "clearcolor": "0 0 0"}, "objects": []}
    """

    /// A local wallpaper with an empty 480 × 272 scene; its overlay files are removed after.
    private func makeWallpaper() throws -> (directory: URL, identity: WallpaperSettingsIdentity, wallpaper: WEWallpaper) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "owe-custom-effect-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"file": "scene.json", "type": "scene", "title": "Custom \#(UUID().uuidString)"}"#.utf8)
            .write(to: directory.appending(path: "project.json"))
        try Data(Self.sceneJSON.utf8).write(to: directory.appending(path: "scene.json"))
        let identity = WallpaperSettingsIdentity.resolve(directory: directory)
        addTeardownBlock {
            let store = SceneEditOverlayFiles.defaultStore
            try? store.remove(identity.rawValue)
            try? FileManager.default.removeItem(at: store.assetsDirectory(for: identity.rawValue))
            try? FileManager.default.removeItem(at: directory)
            Fixtures.removeStoredSettings(for: directory)
        }
        let project = try JSONDecoder().decode(WEProject.self, from: Data(contentsOf: directory.appending(path: "project.json")))
        return (directory, identity, WEWallpaper(using: project, where: directory))
    }

    private func session(for directory: URL) throws -> SceneEditSession {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        return SceneEditSession(outline: try SceneOutline(sceneData: Data(contentsOf: directory.appending(path: "scene.json"))),
                                undoManager: undoManager)
    }

    /// A new effect is WE's blank effect from the user's assets, renamed; its fragment shader is
    /// edited to paint red, and the canvas draws the layer red from the draft's files alone.
    func testANewEffectFromWEsBlankEffectDrawsFromTheEdits() throws {
        let assets = try Fixtures.assets()
        try XCTSkipUnless(FileManager.default.fileExists(atPath: assets.appending(path: CustomEffect.templateFile).path),
                          "WE's blank effect isn't in the assets")
        let (directory, identity, wallpaper) = try makeWallpaper()
        let session = try session(for: directory)
        let resources = EditorWallpaperResources(wallpaper: wallpaper, package: nil, assets: SceneEditOverlayFiles.assets(for: identity))
        resources.draftFiles = { session.overlay.effectFiles ?? [:] }

        let effect = try CustomEffect.make(named: "Paint Red", read: { resources.data($0) })
        XCTAssertEqual(effect.file, "effects/paint_red/effect.json")
        session.createCustomEffect(effect, actionName: "Create New Effect")
        let fragment = "effects/paint_red/shaders/effects/paint_red.frag"
        let blank = try XCTUnwrap(session.overlay.effectFile(fragment))
        XCTAssertTrue(blank.contains("texSample2D(g_Texture0"), "WE's blank effect passes the image through")
        session.setEffectFile(fragment, text: blank.replacingOccurrences(of: "gl_FragColor = albedo;",
                                                                         with: "gl_FragColor = vec4(1.0, 0.0, 0.0, albedo.a);"),
                              actionName: "Edit Shader")
        // It is one of My Effects, and its schema reads the edited files.
        let mine = try XCTUnwrap(resources.effectCatalog(outline: session.authoredOutline).first { $0.file == effect.file })
        XCTAssertTrue(mine.isEditable && mine.isMadeHere)
        XCTAssertNotNil(resources.effectSchema(effect.file))

        let solid = session.addLayer(SceneLayerFactory.solid(name: "Fill", color: SIMD3(1, 1, 1), size: SIMD2(480, 272),
                                                             origin: SIMD2(240, 136)), actionName: "Add")
        XCTAssertNotNil(session.addEffect(mine, to: solid, actionName: "Add Effect"))
        try SceneEditOverlayFiles.save(session.overlay, for: identity, wallpaperDirectory: directory)
        XCTAssertNil(SceneEditOverlayFiles.assetData(fragment, for: identity), "the effect's files are in the overlay, not the edits' folder")

        let harness = try SceneFrameHarness(directory: directory, size: SIMD2(480, 272))
        defer { harness.close() }
        var red = SIMD3(255, 255, 255)
        for _ in 0..<60 where red.y > 60 {
            harness.draw(frames: 5)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            red = try XCTUnwrap(Self.pixel(harness, x: 240, y: 136))
        }
        XCTAssertGreaterThan(red.x, 200, "the edited shader paints red: \(red)")
        XCTAssertLessThan(red.y, 60)
    }

    /// Save as New Wallpaper writes the effect's files into the copy, where its layer finds them.
    func testSaveAsNewWritesTheEffectsFiles() throws {
        let (directory, identity, wallpaper) = try makeWallpaper()
        let session = try session(for: directory)
        let effect = CustomEffect(file: "effects/mine/effect.json", name: "Mine", files: [
            "effects/mine/effect.json": #"{"passes": [{"material": "materials/effects/mine.json"}]}"#,
            "effects/mine/shaders/effects/mine.frag": "void main() {}\n",
        ])
        session.createCustomEffect(effect, actionName: "Create New Effect")
        let folder = try LocalWallpaperSave.save(wallpaper, overlay: session.overlay,
                                                 assetsDirectory: SceneEditOverlayFiles.assets(for: identity).directory,
                                                 title: "Custom Effect Copy \(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        XCTAssertEqual(try String(contentsOf: folder.appending(path: "effects/mine/shaders/effects/mine.frag"), encoding: .utf8),
                       "void main() {}\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appending(path: "effects/mine/effect.json").path))
    }

    private static func pixel(_ harness: SceneFrameHarness, x: Int, y: Int) throws -> SIMD3<Int>? {
        guard let texture = harness.view.currentDrawable?.texture, let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(), x >= 0, y >= 0, x < texture.width, y < texture.height,
              let buffer = device.makeBuffer(length: 4, options: .storageModeShared),
              let commands = queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: x, y: y, z: 0),
                  sourceSize: MTLSize(width: 1, height: 1, depth: 1), to: buffer, destinationOffset: 0,
                  destinationBytesPerRow: 4, destinationBytesPerImage: 4)
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        let bytes = buffer.contents().assumingMemoryBound(to: UInt8.self)
        // BGRA.
        return SIMD3(Int(bytes[2]), Int(bytes[1]), Int(bytes[0]))
    }
}
