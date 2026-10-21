import Metal
import XCTest
@testable import OpenWallpaperEngine

/// Scene Edit / Export's material blending (`WEMaterialBlending`, `sceneObjectBlendingKey`): the
/// values it offers are the ones the renderer draws, and a change reaches the layer's pipeline.
final class WEMaterialBlendingTests: XCTestCase {
    private struct BlendState: Hashable {
        var blends: Bool
        var coverage: Bool
        var source: MTLBlendFactor
        var destination: MTLBlendFactor
    }

    private func imageBlendState(_ blending: String) -> BlendState {
        let descriptor = MTLRenderPipelineDescriptor()
        ImageMaterialRenderer.applyBlending(blending, to: descriptor)
        let attachment = descriptor.colorAttachments[0]!
        return BlendState(blends: attachment.isBlendingEnabled, coverage: descriptor.isAlphaToCoverageEnabled,
                          source: attachment.sourceRGBBlendFactor, destination: attachment.destinationRGBBlendFactor)
    }

    /// An image layer offers WE's four blend-byte values, each of which the image renderer draws
    /// with its own state and none of which it logs as unknown.
    func testImageLayersOfferTheBlendingsTheImageRendererDraws() {
        XCTAssertEqual(WEMaterialBlending.imageLayer.map(\.rawValue), ["normal", "translucent", "additive", "alphatocoverage"])
        let states = WEMaterialBlending.imageLayer.map { imageBlendState($0.rawValue) }
        XCTAssertEqual(Set(states).count, states.count, "each offered blending draws differently")
        XCTAssertEqual(states, [
            BlendState(blends: false, coverage: false, source: .one, destination: .zero),
            BlendState(blends: true, coverage: false, source: .sourceAlpha, destination: .oneMinusSourceAlpha),
            BlendState(blends: true, coverage: false, source: .sourceAlpha, destination: .one),
            BlendState(blends: false, coverage: true, source: .one, destination: .zero),
        ])
        XCTAssertTrue(EffectGraphRenderer.unknownBlendingValues.isDisjoint(with: WEMaterialBlending.imageLayer.map(\.rawValue)))
    }

    /// A particle system offers the values its renderer blends (`EffectGraphRenderer.blendMode`,
    /// normal unblended); it has no alpha-to-coverage draw, so that isn't offered.
    func testParticleSystemsOfferTheBlendingsTheParticleRendererDraws() {
        XCTAssertEqual(WEMaterialBlending.particleSystem, [.normal, .translucent, .additive])
        XCTAssertNil(EffectGraphRenderer.blendMode(WEMaterialBlending.normal.rawValue))
        XCTAssertEqual(EffectGraphRenderer.blendMode(WEMaterialBlending.translucent.rawValue)?.destination, .oneMinusSourceAlpha)
        XCTAssertEqual(EffectGraphRenderer.blendMode(WEMaterialBlending.additive.rawValue)?.destination, .one)
        XCTAssertTrue(EffectGraphRenderer.unknownBlendingValues.isDisjoint(with: WEMaterialBlending.particleSystem.map(\.rawValue)))
    }

    /// WE's defaults for a pass without `blending`, and its parser ignoring case.
    func testAuthoredValues() {
        XCTAssertEqual(WEMaterialBlending.authored(nil, particle: false), .normal)
        XCTAssertEqual(WEMaterialBlending.authored(nil, particle: true), .translucent)
        XCTAssertEqual(WEMaterialBlending.authored("Additive", particle: false), .additive)
        XCTAssertEqual(WEMaterialBlending.authored("AlphaToCoverage", particle: false), .alphaToCoverage)
        XCTAssertEqual(WEMaterialBlending.authored("disabled", particle: false), .normal)
    }

    /// The edit is one of the Inspector's (saved, reset with them) and rebuilds the content
    /// without reloading the scene.
    func testTheEditRebuildsContentOnly() {
        let key = sceneObjectBlendingKey(objectID: 20)
        XCTAssertEqual(SceneChangeImpact.impact(of: key), .rebuildContent)
        XCTAssertTrue(WallpaperPropertyReset.isSceneInspectorEdit(key))
    }

    /// Setting a layer's blending rebuilds its material with it: the pass the scene draws the
    /// image with, and so its pipeline's blend state, and the particle system's material.
    /// The Inspector's Reset removes the edit and replaces the running store, so the key is
    /// dropped there as a change that rebuilds the content with the material's own blending.
    func testResetDropsTheEditFromTheRunningStore() {
        let key = sceneObjectBlendingKey(objectID: 7)
        var stores = SceneUserPropertyStores()
        stores.set(["speed": "1", key: "additive"], for: "wallpaper", replacing: false)
        let changed = stores.set(["speed": "1"], for: "wallpaper", replacing: true)
        XCTAssertEqual(changed, [key])
        XCTAssertEqual(SceneChangeImpact.impact(of: key), .rebuildContent)
    }

    func testChangingTheBlendingUpdatesTheLayersPipelineBlendState() throws {
        _ = try Fixtures.assets()
        let directory = Fixtures.url("Scenes/ordering")
        let project = try JSONDecoder().decode(WEProject.self, from: Fixtures.data("Scenes/ordering/project.json"))
        addTeardownBlock { Fixtures.removeStoredSettings(for: directory) }
        let model = SceneContentLoader(wallpaper: WEWallpaper(using: project, where: directory))
        let store = model.propertyStoreKey
        addTeardownBlock { WallpaperServices.shared.setUserProperties([:], wallpaper: store, replacing: true) }

        func content() throws -> (image: ImageMaterialPlan, particles: SceneMetalParticleSystem) {
            let content = try XCTUnwrap(model.metalContent())
            let image = try XCTUnwrap(content.layers.first { $0.id == "20" }?.imageMaterial, "drawn through its WE material")
            let particles = try XCTUnwrap(content.particleSystems.first { $0.objectID == "30" })
            return (image, particles)
        }

        let authored = try content()
        XCTAssertEqual(authored.image.pass.blending, "translucent")
        XCTAssertEqual(imageBlendState(authored.image.pass.blending).destination, .oneMinusSourceAlpha)
        XCTAssertEqual(authored.particles.blending, "additive")

        let edits = [sceneObjectBlendingKey(objectID: 20): "additive", sceneObjectBlendingKey(objectID: 30): "translucent"]
        WallpaperServices.shared.setUserProperties(edits, wallpaper: model.propertyStoreKey, replacing: false)
        XCTAssertEqual(model.impact(of: Array(edits.keys)), .rebuildContent)

        let edited = try content()
        XCTAssertEqual(edited.image.pass.blending, "additive")
        XCTAssertEqual(imageBlendState(edited.image.pass.blending),
                       BlendState(blends: true, coverage: false, source: .sourceAlpha, destination: .one))
        XCTAssertEqual(edited.particles.blending, "translucent")
        if let material = edited.particles.material {
            XCTAssertEqual(material.blending, "translucent")
        }

        // A value the layer doesn't draw with keeps its material's.
        WallpaperServices.shared.setUserProperties([sceneObjectBlendingKey(objectID: 30): "alphatocoverage"],
                                                   wallpaper: model.propertyStoreKey, replacing: false)
        XCTAssertEqual(try content().particles.blending, "additive")
    }
}
