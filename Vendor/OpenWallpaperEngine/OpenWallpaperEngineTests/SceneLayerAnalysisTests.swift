import MetalKit
import XCTest
@testable import OpenWallpaperEngine

/// The per-layer dependency / coverage / dirty analysis (efficiency-plan-2d notes WP1-A).
final class SceneLayerAnalysisTests: XCTestCase {
    // MARK: - Synthetic content

    private static func layer(_ id: String, order: Int = 0, source: SceneMetalTextureSource? = nil,
                              size: SIMD2<Float> = SIMD2(100, 100), opacity: Float = 1) -> SceneMetalLayer {
        var layer = SceneMetalLayer(
            id: id, name: id, source: source ?? .image(NSImage(size: NSSize(width: 1, height: 1))),
            position: .zero, size: size, scale: SIMD2(1, 1), opacity: opacity, brightness: 1,
            color: SIMD4(repeating: 1), text: nil, parallaxDepth: .zero, perspective: false, rotation: 0)
        layer.order = order
        return layer
    }

    private static func content(_ layers: [SceneMetalLayer], origins: [String: SIMD2<Float>] = [:],
                                parents: [String: String] = [:]) -> SceneMetalContent {
        var nodes: [String: SceneTransformHierarchy.Node] = [:]
        for layer in layers {
            nodes[layer.id] = .init(parentID: parents[layer.id],
                                    local: SceneLocalTransform(origin: origins[layer.id] ?? SIMD2(100, 100),
                                                               scale: SIMD2(1, 1), angle: 0),
                                    parallaxDepth: .zero)
        }
        for parent in Set(parents.values) where nodes[parent] == nil {
            nodes[parent] = .init(parentID: nil, local: .identity, parallaxDepth: .zero)
        }
        var content = SceneMetalContent(size: SIMD2(400, 200), layers: layers, particleSystems: [],
                                        bloom: SceneBloomSettings(enabled: false, strength: 0, threshold: 0.7,
                                                                  tint: SIMD3(repeating: 1)))
        content.transforms = SceneTransformHierarchy(nodes: nodes)
        return content
    }

    /// `make` asserts it runs off the main thread, as the renderer's content queue does.
    private static func analyse(_ content: SceneMetalContent) -> SceneLayerAnalysis {
        var result: SceneLayerAnalysis?
        DispatchQueue.global().sync { result = SceneLayerAnalysis.make(content: content) }
        return result!
    }

    private static func opaqueImage(width: Int, height: Int, alpha: UInt8 = 255) -> NSImage {
        let bytes = [UInt8](repeating: 0, count: width * height * 4).enumerated().map { $0.offset % 4 == 3 ? alpha : 90 }
        let rep = TEXRawImageRep(bytes: bytes, channels: .rgba, rowPixels: width, width: width, height: height)!
        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(rep)
        return image
    }

    // MARK: - Unit

    func testStaticSceneSettlesAndOnlyTimeDependentLayersFollowTheClock() {
        let still = Self.layer("1", order: 0)
        var animated = Self.layer("2", order: 1)
        animated.textureKey = "materials/animated.tex"
        let analysis = Self.analyse(Self.content([still, animated]))
        var inputs = SceneLayerFrameInputs()
        analysis.update(inputs)
        XCTAssertEqual(analysis.dirtyCount, 2, "the first frame draws everything")
        analysis.update(inputs)
        XCTAssertEqual(analysis.dirtyCount, 0)
        inputs.time += 1.0 / 60
        analysis.update(inputs)
        let stillDirty: Bool = analysis.isDirty("1")
        let videoDirty: Bool = analysis.isDirty("2")
        XCTAssertFalse(stillDirty)
        XCTAssertTrue(videoDirty)
        XCTAssertTrue(analysis.isDirty("unknown-script-layer"))
    }

    func testFrameBeneathAndCompositeFollowWhatTheyRead() {
        var bottom = Self.layer("1", order: 0)
        bottom.textureKey = "materials/animated.tex"
        var reader = Self.layer("2", order: 1)
        reader.sceneInput = true
        let analysis = Self.analyse(Self.content([bottom, reader]))
        var inputs = SceneLayerFrameInputs()
        analysis.update(inputs)
        analysis.update(inputs)
        XCTAssertFalse(analysis.isDirty("2"))
        inputs.time += 1
        analysis.update(inputs)
        XCTAssertTrue(analysis.isDirty("2"), "a layer reading the scene is dirty when what's beneath is")
        let deps: SceneLayerDependencies = analysis.layers[1].dependencies
        XCTAssertTrue(deps.contains(.frameBeneath))
    }

    func testScriptWritesDirtyTheLayerAndItsChildrenOnly() {
        let parent = Self.layer("10", order: 0)
        let child = Self.layer("11", order: 1)
        let other = Self.layer("12", order: 2)
        var content = Self.content([parent, child, other], parents: ["11": "10"])
        content.scripts = nil
        let analysis = Self.analyse(content)
        var inputs = SceneLayerFrameInputs()
        inputs.scripts.objects[10] = SceneScriptObjectState(values: [0, 0])
        analysis.update(inputs)
        analysis.update(inputs)
        XCTAssertEqual(analysis.dirtyCount, 0, "unchanged script state is not a change")
        inputs.scripts.objects[10]?.values[0] = 5
        analysis.update(inputs)
        XCTAssertTrue(analysis.isDirty("10"))
        XCTAssertTrue(analysis.isDirty("11"))
        XCTAssertFalse(analysis.isDirty("12"))
    }

    /// `ILayer.setParent`: after a reparent the new parent's script writes dirty the child, the
    /// old one's don't, the child's bounds no longer hold, and the next frame is drawn.
    func testReparentedLayerFollowsItsNewParent() {
        let layers = [Self.layer("10", order: 0), Self.layer("11", order: 1), Self.layer("12", order: 2)]
        var content = Self.content(layers, parents: ["11": "10"])
        content.scripts = nil
        let analysis = Self.analyse(content)
        var inputs = SceneLayerFrameInputs()
        inputs.scripts.objects[10] = SceneScriptObjectState(values: [0])
        inputs.scripts.objects[12] = SceneScriptObjectState(values: [0])
        analysis.update(inputs)
        analysis.update(inputs)
        XCTAssertFalse(analysis.coverage(at: 1).fullScene)

        var hierarchy = content.transforms
        hierarchy.setParent("11", to: "12", attachment: nil)
        let reparented = analysis.reparented(nodes: hierarchy.nodes, motions: [:])
        XCTAssertEqual(reparented.layers[1].lineage, [11, 12])
        XCTAssertTrue(reparented.coverage(at: 1).fullScene, "bounds worked out under the old parent")
        XCTAssertFalse(reparented.coverage(at: 2).fullScene, "an untouched layer keeps its bounds")
        reparented.update(inputs)
        XCTAssertEqual(reparented.dirtyCount, 3, "the frame after the reparent is drawn")
        reparented.update(inputs)
        XCTAssertEqual(reparented.dirtyCount, 0)
        inputs.scripts.objects[12]?.values[0] = 5
        reparented.update(inputs)
        XCTAssertTrue(reparented.isDirty("11"), "the new parent moves it")
        inputs.scripts.objects[10]?.values[0] = 5
        inputs.scripts.objects[12]?.values[0] = 5
        reparented.update(inputs)
        XCTAssertFalse(reparented.isDirty("11"), "the old parent no longer does")
        XCTAssertTrue(reparented.isDirty("10"))
    }

    func testCoverageAndOpacity() {
        let opaque = Self.layer("1", source: .image(Self.opaqueImage(width: 8, height: 8)), size: SIMD2(100, 50))
        let holey = Self.layer("2", source: .image(Self.opaqueImage(width: 8, height: 8, alpha: 254)))
        let faded = Self.layer("3", source: .image(Self.opaqueImage(width: 8, height: 8)), opacity: 0.5)
        let analysis = Self.analyse(Self.content([opaque, holey, faded], origins: ["1": SIMD2(60, 40)]))
        let first = analysis.coverage(at: 0)
        XCTAssertFalse(first.fullScene)
        XCTAssertTrue(first.opaque)
        XCTAssertEqual(first.min, SIMD2<Float>(10, 15))
        XCTAssertEqual(first.max, SIMD2<Float>(110, 65))
        let holeyOpaque: Bool = analysis.coverage(at: 1).opaque
        let fadedOpaque: Bool = analysis.coverage(at: 2).opaque
        XCTAssertFalse(holeyOpaque)
        XCTAssertFalse(fadedOpaque)
    }

    /// A material's vertex stage places the vertices, so a layer drawn through one covers the
    /// scene whatever its material is named.
    func testMaterialLayersCoverTheScene() {
        let pass = SceneEffectPassPlan(command: .render, variantKey: "", variant: nil, blending: "normal", target: nil,
                                       textures: [:], constants: .init(staticValues: [:], dynamic: []))
        var layers: [SceneMetalLayer] = []
        for (id, path) in [("1", "materials/genericimage2.json"), ("2", "materials/wobble.json")] {
            var layer = Self.layer(id, source: .image(Self.opaqueImage(width: 8, height: 8)))
            layer.imageMaterial = ImageMaterialPlan(materialPath: path, pass: pass, usesSpriteSheetUniforms: false,
                                                    liveFactors: [:])
            layers.append(layer)
        }
        layers.append(Self.layer("3", source: .image(Self.opaqueImage(width: 8, height: 8))))
        let analysis = Self.analyse(Self.content(layers))
        XCTAssertTrue(analysis.coverage(at: 0).fullScene)
        XCTAssertTrue(analysis.coverage(at: 1).fullScene)
        XCTAssertFalse(analysis.coverage(at: 2).fullScene, "a natively drawn quad keeps its bounds")
    }

    func testShaderDependenciesComeFromTheBuiltinsItReads() {
        func variant(_ fragment: String) -> TranslatedShaderVariant {
            TranslatedShaderVariant(vertexMSL: "", fragmentMSL: fragment, uniforms: nil, textureSlots: [0], attributes: [:],
                                    combos: [:])
        }
        XCTAssertEqual(SceneLayerAnalysis.shaderDependencies(variant("float t = u.g_Time;")), [.time])
        XCTAssertEqual(SceneLayerAnalysis.shaderDependencies(variant("u.g_PointerPosition")), [.cursor])
        XCTAssertEqual(SceneLayerAnalysis.shaderDependencies(variant("u.g_AudioSpectrum16Left[0]")), [.audio])
        XCTAssertEqual(SceneLayerAnalysis.shaderDependencies(variant("return c;")), [])
        XCTAssertEqual(SceneLayerAnalysis.shaderDependencies(nil), [.time], "unknown is dynamic")
    }

    func testContentClassHeuristic() {
        let side = 64
        var lines = [Float](repeating: 1, count: side * side)
        for y in stride(from: 0, to: side, by: 8) { for x in 0..<side { lines[y * side + x] = 0 } }
        XCTAssertEqual(SceneLayerAnalysis.classify(luma: lines, width: side, height: side), .lineArt)
        var generator = SystemRandomNumberGenerator()
        let noise = (0..<(side * side)).map { _ in Float.random(in: 0...1, using: &generator) }
        XCTAssertEqual(SceneLayerAnalysis.classify(luma: noise, width: side, height: side), .photo)
        var text = Self.layer("t")
        text = SceneMetalLayer(id: "t", name: "t", source: text.source, position: .zero, size: text.size, scale: text.scale,
                               opacity: 1, brightness: 1, color: text.color,
                               text: SceneMetalText(value: "12:00", font: nil, pointSize: 12, horizontalAlignment: nil,
                                                    verticalAlignment: nil, padding: .zero, maxWidth: nil, maxRows: nil,
                                                    useEllipsis: false, anchor: nil, blockAlign: false),
                               parallaxDepth: .zero, perspective: false, rotation: 0)
        XCTAssertEqual(SceneLayerAnalysis.classify(text).0, .text)
    }

    /// Each frame input, changed alone, reports its dependency kind, and a layer that depends on it
    /// is dirtied: the quick tier's cover for `testEachDependencyKindDirtiesItsLayersOnCIScenes`.
    func testEachInputChangedAloneReportsItsDependencyKind() {
        // Every layer depends on shake and the inspector.
        let analysis = Self.analyse(Self.content([Self.layer("1")]))
        let mutations: [(SceneLayerDependencies, (inout SceneLayerFrameInputs) -> Void)] = [
            (.time, { $0.time += 1 }),
            (.video, { $0.videoRevision += 1 }),
            (.cursor, { $0.pointer += 0.1 }),
            (.parallax, { $0.parallax += 0.1 }),
            (.parallax, { $0.parallaxActive.toggle() }),
            (.shake, { $0.shake += 1 }),
            (.shake, { $0.cameraShake += 1 }),
            (.audio, { $0.audioLevel += 0.5 }),
            (.userProperties, { $0.userPropertiesRevision += 1 }),
            (.inspector, { $0.inspectorRevision += 1 }),
        ]
        for (kind, mutate) in mutations {
            let settled = SceneLayerFrameInputs()
            analysis.update(settled)
            analysis.update(settled)
            let settledCount: Int = analysis.dirtyCount
            XCTAssertEqual(settledCount, 0, "\(kind): unchanged inputs leave the layer clean")
            var changed = settled
            mutate(&changed)
            analysis.update(changed)
            let reported: SceneLayerDependencies = analysis.changed
            XCTAssertTrue(reported.contains(kind), "\(kind) changed but wasn't reported")
            if kind != .inspector {
                let sceneWide: Bool = analysis.sceneWideDirty
                XCTAssertFalse(sceneWide, "\(kind) alone isn't scene-wide")
            }
            if kind == .shake || kind == .inspector {
                let isDirty: Bool = analysis.isDirty("1")
                XCTAssertTrue(isDirty, "\(kind) changed but the layer that depends on it stayed clean")
            }
        }
    }

    func testUpdateCostFor200Layers() {
        let layers = (0..<200).map { Self.layer(String($0 + 1), order: $0) }
        let analysis = Self.analyse(Self.content(layers))
        var inputs = SceneLayerFrameInputs()
        for id in stride(from: 1, through: 200, by: 4) { inputs.scripts.objects[id] = SceneScriptObjectState(values: [0, 1, 2, 3]) }
        inputs.animatedSites = (1...20).map { SceneAnimationSite(owner: .object($0), key: "origin") }
        var samples: [Double] = []
        for frame in 0..<400 {
            inputs.time = Double(frame) / 60
            inputs.pointer.x = Float(frame % 7) / 7
            analysis.update(inputs)
            samples.append(analysis.lastUpdateSeconds)
        }
        samples.sort()
        let median: Double = samples[samples.count / 2]
        let medianMilliseconds: Double = median * 1000
        print("SceneLayerAnalysis update, 200 layers: median \(medianMilliseconds) ms, p99 \(samples[samples.count * 99 / 100] * 1000) ms")
        // The target is 0.05 ms in an optimised build; tests run unoptimised.
        #if DEBUG
        let limit: Double = 0.25
        #else
        let limit: Double = 0.05
        #endif
        XCTAssertLessThan(medianMilliseconds, limit)
    }

    // MARK: - CI scenes

    /// Every fixture scene that is a wallpaper folder, bar `Fixtures.unrenderableScenes`.
    private static var ciScenes: [String] {
        let root = Fixtures.url("Scenes")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.sorted().filter { name in
            !Fixtures.unrenderableScenes.contains(name)
                && FileManager.default.fileExists(atPath: root.appending(path: "\(name)/project.json").path)
        }
    }

    /// Every dependency kind, changed alone, dirties every layer that depends on it.
    /// About 60 s in Debug, so it runs nightly and locally (`OWE_SLOW_TESTS=1`), not on every PR;
    /// `testEachInputChangedAloneReportsItsDependencyKind` covers each kind on every PR.
    func testEachDependencyKindDirtiesItsLayersOnCIScenes() throws {
        try SlowTests.require()
        var checked = 0
        for name in Self.ciScenes {
            let scene = try SceneFrameHarness(directory: Fixtures.url("Scenes/\(name)"))
            defer { scene.close() }
            scene.draw(frames: 1)
            let analysis = try XCTUnwrap(scene.renderer.layerAnalysis, name)
            // Frame-wide stages that animate on their own keep every frame dirty: nothing to isolate.
            if analysis.sceneStagesAnimate { continue }
            let base = SceneLayerFrameInputs()
            let mutations: [(SceneLayerDependencies, (inout SceneLayerFrameInputs, SceneLayerAnalysis.Layer) -> Void)] = [
                (.time, { inputs, _ in inputs.time += 1 }),
                (.video, { inputs, _ in inputs.videoRevision += 1 }),
                (.cursor, { inputs, _ in inputs.pointer += 0.1 }),
                (.parallax, { inputs, _ in inputs.parallax += 0.1 }),
                (.shake, { inputs, _ in inputs.shake += 1 }),
                (.audio, { inputs, _ in inputs.audioLevel += 0.5 }),
                (.userProperties, { inputs, _ in inputs.userPropertiesRevision += 1 }),
                (.inspector, { inputs, _ in inputs.inspectorRevision += 1 }),
                (.script, { inputs, layer in
                    if let id = layer.objectID { inputs.scripts.objects[id] = SceneScriptObjectState(values: [1]) }
                }),
                (.timeline, { inputs, layer in inputs.time += 1 }),
            ]
            for (index, layer) in analysis.layers.enumerated() {
                for (kind, mutate) in mutations where layer.dependencies.contains(kind) {
                    var settled = base
                    if kind == .timeline, let id = layer.objectID {
                        settled.animatedSites = [SceneAnimationSite(owner: .object(id), key: "alpha")]
                    }
                    analysis.update(settled)
                    analysis.update(settled)
                    let settledCount: Int = analysis.dirtyCount
                    XCTAssertEqual(settledCount, 0, "\(name): unchanged inputs leave every layer clean")
                    var changed = settled
                    mutate(&changed, layer)
                    if kind == .script, layer.objectID == nil { continue }
                    analysis.update(changed)
                    let isDirty: Bool = analysis.dirty[index]
                    XCTAssertTrue(isDirty, "\(name) layer \(layer.id): \(kind) changed but the layer stayed clean")
                    checked += 1
                }
            }
        }
        XCTAssertGreaterThan(checked, 50)
    }

    /// Whenever the analysis says nothing is dirty, the frame the renderer draws is the last one.
    func testCleanFramesMatchTheLastFrameOnCIScenes() throws {
        var compared = 0
        for name in Self.ciScenes {
            let scene = try SceneFrameHarness(directory: Fixtures.url("Scenes/\(name)"))
            defer { scene.close() }
            var last: PerceptualImage?
            // Half the frames hold the clock (nothing but scripts can move), half advance it.
            for frame in 0..<24 {
                scene.draw(frames: 1, step: frame % 2 == 0 ? 0 : 1.0 / 30)
                let image = Self.read(scene)
                let analysis = try XCTUnwrap(scene.renderer.layerAnalysis, name)
                if let last, frame > 1, !analysis.anyDirty {
                    let ssim: Double = PerceptualCompare.ssim(last, image)
                    XCTAssertGreaterThanOrEqual(ssim, 0.999, "\(name) frame \(frame): clean but the picture changed")
                    compared += 1
                }
                last = image
            }
        }
        print("SceneLayerAnalysis: \(compared) clean frames compared")
        XCTAssertGreaterThan(compared, 20)
    }

    private static func read(_ scene: SceneFrameHarness) -> PerceptualImage {
        OWEPhaseTiming.measure(.readback) {
            let size = scene.size
            var bytes = [UInt8](repeating: 0, count: size.x * size.y * 4)
            scene.view.currentDrawable?.texture.getBytes(&bytes, bytesPerRow: size.x * 4,
                                                         from: MTLRegionMake2D(0, 0, size.x, size.y), mipmapLevel: 0)
            // BGRA → RGBA, opaque.
            for pixel in stride(from: 0, to: bytes.count, by: 4) {
                bytes.swapAt(pixel, pixel + 2)
                bytes[pixel + 3] = 255
            }
            return PerceptualImage(width: size.x, height: size.y, rgba: bytes)
        }
    }
}
