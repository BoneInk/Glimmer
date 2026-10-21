import CoreGraphics
import XCTest
import OWEControlProtocol
import OWEEditor
import OWESceneEditing
@testable import OpenWallpaperEngine

/// `use_depth_map_as_mask` with `effect: "opacity"`, against the fixture scene with a fake depth
/// model: on a layer without WE's Opacity effect it adds the effect with the depth mask in its
/// grey mask slot (the `MASK` combo on) as one undo step; with the effect there it fills that
/// effect's mask.
@MainActor
final class MCPDepthMaskTests: XCTestCase {
    private var fixture: MCPSceneFixture!
    private var router: ControlRequestRouter!
    private var prepared: [String] = []

    /// A model that answers far on the left, near on the right.
    private final class Estimator: DepthEstimating, @unchecked Sendable {
        let outputIsInverseDepth = true

        func estimate(_ image: CGImage) throws -> DepthMapBuffer {
            DepthMapBuffer(width: 16, height: 4, values: (0..<64).map { $0 % 16 < 8 ? 10 : 50 })
        }
    }

    /// WE's Opacity effect's sampler (`effects/opacity`'s `g_Texture1`).
    private static let opacitySchema = EffectSchema(textures: [
        .init(slot: 1, title: "Opacity Mask", isMask: true, combo: "MASK", paintDefault: [0, 0, 0, 1], mode: "opacitymask",
              materialName: "opacity"),
    ])

    override func setUp() async throws {
        fixture = try MCPSceneFixture()
        prepared = []
        let generator = DepthMapGenerator(
            locateModel: { DepthMapPluginLayout.ActiveModel(version: "fake-1", url: URL(fileURLWithPath: "/nonexistent/fake.mlmodelc")) },
            loadModel: { _ in Estimator() }, cache: nil, processing: nil, log: { _ in })
        fixture.depthMapServices = DepthMapEditorServices(
            generator: generator, assetStore: EditorAssetStore(directory: fixture.root.appending(path: "assets")),
            source: { _ in DepthMapSource(image: Self.picture(), isOneFrame: false) },
            prepareEffect: {}, texture: { _ in nil }, openPlugins: {},
            effectSchema: { file in DepthMask.isOpacityEffect(file) ? Self.opacitySchema : nil },
            prepareBuiltInEffect: { [unowned self] entry in self.prepared.append(entry.file) },
            encodeMask: { TEXWriter.effectMask($0, width: $1, height: $2) })
        let editors = FakeSceneEditorControl()
        editors.isDepthMapPluginInstalled = true
        let group = SceneControlRequests(service: fixture.service(), editors: editors)
        router = ControlRequestRouter(model: MCPSceneAppModel([fixture.wallpaper]), groups: [group])
    }

    override func tearDown() async throws {
        fixture?.remove()
    }

    private static func picture() -> CGImage {
        let context = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
        return context.makeImage()!
    }

    private func result(_ method: String, _ params: [String: JSONValue],
                        file: StaticString = #filePath, line: UInt = #line) async throws -> JSONValue {
        let response = await router.handle(ControlRequest(id: 7, method: method, params: params))
        XCTAssertNil(response.error, "\(method): \(response.error?.message ?? "")", file: file, line: line)
        return try XCTUnwrap(response.result, file: file, line: line)
    }

    private func overlay() throws -> SceneEditOverlay {
        try fixture.draftStore.overlay(for: fixture.identity.rawValue)
    }

    func testLayerOpacityAddsWEsOpacityEffectWithTheMaskInOneUndoStep() async throws {
        _ = try await result("depth_generate", ["wallpaper_id": "fixture", "layer": 4])
        let used = try await result("use_depth_map_as_mask", ["wallpaper_id": "fixture", "layer": 4, "effect": "opacity",
                                                              "invert": true, "contrast": 2])
        XCTAssertEqual(used["added_effect"], true)
        XCTAssertEqual(used["layer_opacity"], true)
        XCTAssertEqual(used["effect"], "+1")
        XCTAssertEqual(used["slot"], 1)
        let mask = try XCTUnwrap(used["mask"]?.stringValue)
        XCTAssertTrue(mask.hasPrefix("masks/opacity_mask_"), "WE's name for the Opacity effect's mask: \(mask)")
        XCTAssertEqual(prepared, [DepthMask.opacityEffect.file], "the effect's files are copied as adding it does")

        let session = SceneEditSession(outline: try SceneOutline(sceneData: MCPSceneFixture.scene), overlay: try overlay())
        let effect = try XCTUnwrap(session.outline.layer(4)?.effects.last)
        XCTAssertEqual(effect.file, DepthMask.opacityEffect.file)
        XCTAssertEqual(session.effectTexture(1, effect: effect.key, of: 4), mask)
        XCTAssertEqual(session.effectCombo("MASK", effect: effect.key, of: 4, default: 0), 1)

        // Again: the layer has the effect now, so it fills that effect's mask, replacing it.
        _ = try await result("depth_generate", ["wallpaper_id": "fixture", "layer": 4])
        let again = try await result("use_depth_map_as_mask", ["wallpaper_id": "fixture", "layer": 4, "effect": "opacity"])
        XCTAssertEqual(again["added_effect"], false)
        XCTAssertEqual(again["effect"], "+1")
        XCTAssertEqual(again["replaced"]?.stringValue, mask)
        XCTAssertNotEqual(again["mask"]?.stringValue, mask, "not inverted: another mask")

        _ = try await result("scene_undo", ["wallpaper_id": "fixture"])
        _ = try await result("scene_undo", ["wallpaper_id": "fixture"])
        let undone = SceneEditSession(outline: try SceneOutline(sceneData: MCPSceneFixture.scene), overlay: try overlay())
        XCTAssertEqual(undone.outline.layer(4)?.effects.map(\.file), ["effects/blur/effect.json"],
                       "one undo step took both the effect and its mask off")
    }
}
