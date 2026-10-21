import XCTest
import MetalKit
import simd
@testable import OpenWallpaperEngine

/// Every Puppet Warp layer of the library (docs/models-plan.md §2.13: 32 layers in 7 scenes),
/// loaded by the real loader and drawn by the real renderer, posed by its animation layers
/// (docs/models-plan.md §4.3 M6, P2):
///
/// - none falls back to its unwarped image: each has its mesh plan, with WE's combos
///   (`SKINNING`, the exact `BONECOUNT`);
/// - each drawn image reproduces what its rig assembles from the source texture: a CPU
///   rasterisation of the mesh skinned with the pose it was drawn in (sampled bilinearly as the
///   mesh pass samples, straight-alpha "over" in index order) is the oracle; every rig also plays 5 s without a NaN or infinity, and
///   each rig in its bind pose is checked the same way, compared over a grid of pixel centres (coverage mask, alpha, colour). For the rigs
///   laid over their own picture, the oracle is the source image itself where the mesh covers it,
///   and the mesh covers the picture; the witcher's (3803167460) rearranges an atlas.
///
/// `OWE_PUPPET_OUT` names a folder for each layer's source texture and drawn image as PNG.
/// Skipped when the library is absent (CI); roots as `LightingLibraryDecodeTests`.
final class ScenePuppetLibraryTests: XCTestCase {
    private var storage: URL!

    override func setUpWithError() throws {
        storage = FileManager.default.temporaryDirectory.appending(path: "owe-puppet-sweep-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let storage, FileManager.default.fileExists(atPath: storage.path) {
            try FileManager.default.removeItem(at: storage)
        }
    }

    func testEveryLibraryPuppetDrawsItsPose() throws {
        _ = try Fixtures.assets()
        let roots = LightingLibraryDecodeTests.roots.filter { FileManager.default.fileExists(atPath: $0.path) }
        try XCTSkipIf(roots.count < LightingLibraryDecodeTests.roots.count, "wallpaper library not present")
        let items = try Self.puppetScenes(in: roots)
        let ids = Set(items.map(\.workshopID))
        for expected in ["2542737668", "3803167460", "2804817823", "2321732083", "2515150033", "3802767544", "3803042537"] {
            XCTAssertTrue(ids.contains(expected), "\(expected)'s puppets weren't found")
        }
        XCTAssertGreaterThanOrEqual(items.reduce(0) { $0 + $1.layers.count }, 32, "the survey's 32 puppet layers")
        let output = ProcessInfo.processInfo.environment["OWE_PUPPET_OUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        var report = "scene\tlayer\tbones\tvertices\ttexture\tIoU\talpha MAE\tcolour MAE\tpicture covered\tunwarped\tposed\n"
        for item in items { report += try sweep(item, output: output) }
        print("Library puppets, posed (and their bind pose against the picture):\n\(report)")
    }

    /// A puppet with effects moves with its pose, frame after frame. The Cyberpunk Samurai
    /// (2321732083: `pulse` and `blend` on the puppet) stood in its first pose while its effects'
    /// kept output was keyed by the image's texture alone, which the mesh redraws in place; only
    /// the pulse moved. Its crop now changes as its cape and head layers play.
    func testAPuppetWithEffectsMovesWithItsPose() throws {
        _ = try Fixtures.assets()
        let directory = LibrarySweepTests.libraryRoot.appending(path: "2321732083", directoryHint: .isDirectory)
        let projectURL = directory.appending(path: "project.json")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: projectURL.path), "2321732083 not in the library")
        let text = String(decoding: try Data(contentsOf: projectURL), as: UTF8.self)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
        let project = try decodeTolerant(WEProject.self, from: Data(text.utf8))
        var settings = SceneRenderSettings()
        settings.postProcessing = .enabled
        let renderer = WEReferenceRenderer(directory: directory, project: project, settings: settings, storage: storage)
        let frames = try renderer.render((0..<5).map { WEReferenceRenderer.Shot(time: 10 + Double($0) * 0.25, cursor: SIMD2(960, 540)) })
        // The samurai's crop of the 1920×1080 frame, grey.
        let crops = frames.map { frame -> [Float] in
            stride(from: 250, to: 810, by: 2).flatMap { y in
                stride(from: 550, to: 1050, by: 2).map { x -> Float in
                    let index = (y * frame.width + x) * 4
                    return 0.299 * Float(frame.pixels[index]) + 0.587 * Float(frame.pixels[index + 1])
                        + 0.114 * Float(frame.pixels[index + 2])
                }
            }
        }
        let steps = zip(crops, crops.dropFirst()).map { a, b in
            zip(a, b).reduce(Float(0)) { $0 + abs($1.0 - $1.1) } / Float(a.count)
        }
        let mean = steps.reduce(0, +) / Float(steps.count)
        // Frozen with only the pulse: 0.7–1.0 a step; posed: 2–6.
        XCTAssertGreaterThan(mean, 1.8, "the samurai's crop per 0.25 s: \(steps)")
    }

    /// A puppet's effects run in its image's own layout, where their masks are painted, and the
    /// posed mesh lays their output out. Katana Girl (3238423642) keeps her head apart in the
    /// texture's left eighth and poses it onto her neck; the eye effects' masks are painted on
    /// that part of the texture (the eyes' tint, blink, movement and iris). Run on the posed
    /// image, they hit empty sky and the eye properties changed nothing. Clock held, the tint is
    /// `tintlow`, the user's eye colour.
    func testAnAtlasPuppetsEffectsFollowTheirMasks() throws {
        _ = try Fixtures.assets()
        let directory = LibrarySweepTests.libraryRoot.appending(path: "3238423642", directoryHint: .isDirectory)
        let projectURL = directory.appending(path: "project.json")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: projectURL.path), "3238423642 not in the library")
        Fixtures.removeStoredSettings(for: directory)
        defer { Fixtures.removeStoredSettings(for: directory) }
        let project = try decodeTolerant(WEProject.self, from: Data(contentsOf: projectURL))
        let model = SceneContentLoader(wallpaper: WEWallpaper(using: project, where: directory))
        let content = try XCTUnwrap(model.metalContent())
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let size = SIMD2<Float>(1920, 1080)
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.autoResizeDrawable = false
        view.drawableSize = CGSize(width: 1920, height: 1080)
        let renderer = try XCTUnwrap(SceneMetalRenderer(view: view, scriptServices: nil, screenID: "atlas-puppet"))
        defer { renderer.releaseContent() }
        view.isPaused = true
        renderer.setPlacement(.fill)
        var now: CFTimeInterval = 1000
        renderer.wallTime = { now }
        renderer.setContent(content)
        func frame() throws -> [UInt8]? {
            renderer.renderShared([SceneViewport(drawableSize: size, pointSize: size, cursor: .zero, frameRateLimit: 30)])
            renderer.lastCommandBuffer?.waitUntilCompleted()
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
            return try renderer.sharedFrame.map { try TextureUploadTests.read($0, device: device) }
        }
        // The content lands in the background and the scene's clock starts then: frames drawn before
        // it don't count, so the posed time (and her blink's phase with it) is the same every run.
        let landing = Date().addingTimeInterval(60)
        while !renderer.hasContent, Date() < landing { _ = try frame() }
        XCTAssertTrue(renderer.hasContent, "the content never landed")
        // Posed: her head leaves the texture's corner for her neck as her layers play.
        for _ in 0..<90 {
            now += 1.0 / 30
            _ = try frame()
        }
        // The first frame after the content landed starts the clock; each later one is a step.
        XCTAssertEqual(renderer.sceneTime, 89.0 / 30, accuracy: 1e-6, "the clock ran only from the content's landing")
        // Settled, the clock held: every pipeline compiled, two frames alike.
        renderer.holdsClock = true
        var before: [UInt8]?
        let deadline = Date().addingTimeInterval(120)
        var frames = 0
        repeat {
            for _ in 0..<10 { _ = try frame() }
            frames += 11
            let next = try frame()
            if frames >= 120, next != nil, next == before { break }
            before = next
        } while Date() < deadline
        let shown = try XCTUnwrap(before)
        WallpaperServices.shared.setUserProperties(["eyesglowingcolor": "0 1 0"], wallpaper: model.propertyStoreKey, replacing: false)
        // The change reaches the renderer as the wallpaper instance hands it on: the bindings that
        // read the property take it under a new revision (`SceneWallpaperInstance`).
        renderer.userPropertiesDidChange(["eyesglowingcolor"], owners: model.bindingUpdate(for: ["eyesglowingcolor"]).owners)
        let tinted = try XCTUnwrap(try frame())
        // Her eye, on her face at the frame's right of centre (the frame is the scene's target).
        let width = try XCTUnwrap(renderer.sharedFrame).width
        let scale = Float(width) / 1920
        var changed = 0
        for y in Int(380 * scale)..<Int(460 * scale) {
            for x in Int(1090 * scale)..<Int(1190 * scale) {
                let index = (y * width + x) * 4
                if (0..<3).contains(where: { abs(Int(shown[index + $0]) - Int(tinted[index + $0])) > 16 }) { changed += 1 }
            }
        }
        XCTAssertGreaterThan(changed, 10, "the eye's pixels the eye colour changed")
    }

    // MARK: - One scene

    private func sweep(_ item: Item, output: URL?) throws -> String {
        let model = SceneContentLoader(wallpaper: WEWallpaper(using: item.project, where: item.directory))
        var content = try XCTUnwrap(model.metalContent(), "\(item.id): no content")
        defer { Fixtures.removeStoredSettings(for: item.directory) }
        var plans: [String: ScenePuppetPlan] = [:]
        // A rig that rearranges an atlas and has effects runs them on its texture as stored, where
        // their masks are painted, and its posed mesh lays their output out: it draws no image of
        // its own for the oracle, only that layout.
        var atlases: Set<String> = []
        for id in item.layers {
            guard let layer = content.layers.first(where: { $0.id == id }) else {
                XCTFail("\(item.id) layer \(id): not in the content")
                continue
            }
            guard let plan = layer.puppet else {
                XCTFail("\(item.id) layer \(id) (\(layer.name)): drawn unwarped")
                continue
            }
            let variant = try XCTUnwrap(plan.material.pass.variant)
            XCTAssertEqual(variant.combos["SKINNING"], 1, "\(item.id) \(id)")
            XCTAssertEqual(variant.combos["BONECOUNT"], plan.skeleton.bones.count, "\(item.id) \(id): the exact bone count")
            let animator = plan.makeAnimator()
            XCTAssertEqual(animator.stack.layers.count, plan.animationLayers.count, "\(item.id) \(id): every layer names a clip")
            for _ in 0..<60 { animator.advance(delta: 1.0 / 12, values: EmptySceneValues()) }
            XCTAssertTrue(animator.pose.bones.allSatisfy { bone in
                [bone.columns.0, bone.columns.1, bone.columns.2, bone.columns.3].allSatisfy { column in
                    (0..<4).allSatisfy { column[$0].isFinite }
                }
            }, "\(item.id) \(id): a finite pose")
            if !plan.bindPoseIsTextureLayout, !layer.weEffects.isEmpty {
                atlases.insert(id)
            } else {
                plans[id] = plan
            }
            // Hidden puppets (a user property's variant) are drawn too, for the check.
            content.visibility[id] = true
        }

        // The renderer resolves user-bound visibility again as it takes the content; with no user
        // values that is what `visibility` already holds, except the hidden puppets shown above.
        content.userVisibility = SceneUserVisibility()

        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 320, height: 180), device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.autoResizeDrawable = false
        view.drawableSize = CGSize(width: 320, height: 180)
        let services = SceneScriptServices(prelude: SceneScriptPrelude.load(), storage: SceneScriptStorage(directory: storage),
                                           media: SceneScriptReplayMediaSource(), spectrum: { .silent })
        let renderer = try XCTUnwrap(SceneMetalRenderer(view: view, scriptServices: services, screenID: "puppets"))
        defer { renderer.releaseContent() }
        view.isPaused = true
        var now: CFTimeInterval = 1000
        renderer.wallTime = { now }
        renderer.setContent(content)
        var deadline = Date().addingTimeInterval(60)
        while !renderer.hasContent, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(renderer.hasContent, "\(item.id) never got its content")
        func frame() {
            renderer.renderShared([SceneViewport(drawableSize: SIMD2(320, 180), pointSize: SIMD2(320, 180),
                                                 cursor: SIMD2(160, 90), frameRateLimit: 30)])
            renderer.lastCommandBuffer?.waitUntilCompleted()
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        // The clock is held at 0 until every mesh has drawn and nothing compiles for 3 frames in a
        // row (how long that takes depends on which pipelines earlier tests compiled), then runs a
        // fixed second: every run checks the same pose. A frame that merely stands still still
        // steps WE's shortest frame (`SceneClock.minimumFrameDelta`), so without the hold the
        // pose's time grew with the frames the warm-up took.
        renderer.holdsClock = true
        deadline = Date().addingTimeInterval(90)
        var settled = 0
        while settled < 3, Date() < deadline {
            frame()
            let ready = !plans.keys.contains(where: { renderer.puppetImage(ofLayer: $0) == nil })
                && !atlases.contains(where: { !renderer.puppetLaidOutEffects(ofLayer: $0) }) && !renderer.pipelinesCompiling
            settled = ready ? settled + 1 : 0
        }
        XCTAssertEqual(settled, 3, "\(item.id) never settled")
        XCTAssertEqual(renderer.sceneTime, 0, "\(item.id): the clock held")
        renderer.holdsClock = false
        for _ in 0..<30 {
            now += 1.0 / 30
            frame()
        }
        XCTAssertEqual(renderer.sceneTime, 1, accuracy: 1e-9, "\(item.id): the posed time")
        for id in atlases.sorted() {
            XCTAssertNil(renderer.puppetImage(ofLayer: id), "\(item.id) layer \(id): an atlas rig with effects draws no image")
            XCTAssertTrue(renderer.puppetLaidOutEffects(ofLayer: id), "\(item.id) layer \(id): its effect output was never posed")
        }

        var lines = ""
        for (id, plan) in plans.sorted(by: { $0.key < $1.key }) {
            guard let drawn = renderer.puppetImage(ofLayer: id) else {
                XCTFail("\(item.id) layer \(id): its mesh was never drawn")
                continue
            }
            let source = try ScenePuppetTestSupport.rgba8(drawn.source, device: device)
            let image = try ScenePuppetTestSupport.rgba8(drawn.image, device: device)
            let size = SIMD2(drawn.image.width, drawn.image.height)
            XCTAssertEqual(size, SIMD2(drawn.source.width, drawn.source.height), "\(item.id) \(id): the source's layout")
            let pose = try XCTUnwrap(renderer.puppetImagePose(ofLayer: id), "\(item.id) \(id)")
            // A layer without effects covers its posed mesh (`ScenePuppetCanvas`).
            let result = Self.compare(plan, source: source, image: image, size: size, pose: pose,
                                      canvas: renderer.puppetCanvas(ofLayer: id))
            // The oracle in the bind pose against the picture: a rig laid over its picture covers it.
            let bind = Self.compare(plan, source: source, image: source, size: size, pose: .bind(boneCount: plan.boneCount))
            let label = "\(item.id) layer \(id)"
            if bind.unwarped {
                XCTAssertGreaterThanOrEqual(bind.iou, 0.97, "\(label): the rig covers its picture")
                XCTAssertLessThanOrEqual(bind.colourError, 2, "\(label): the rig reproduces its picture")
            }
            XCTAssertGreaterThanOrEqual(result.iou, 0.999, "\(label): coverage")
            XCTAssertLessThanOrEqual(result.alphaError, 0.5, "\(label): alpha")
            XCTAssertLessThanOrEqual(result.colourError, 1, "\(label): colour")
            let posed = pose != .bind(boneCount: plan.boneCount)
            lines += [item.id, id, String(plan.boneCount), String(plan.vertexData.count / plan.format.stride),
                      "\(size.x)×\(size.y)", String(format: "%.4f", result.iou), String(format: "%.2f", result.alphaError),
                      String(format: "%.2f", result.colourError), String(format: "%.4f", bind.iou),
                      bind.unwarped ? "yes" : "no", posed ? "yes" : "no"].joined(separator: "\t") + "\n"
            if let output {
                let folder = output.appending(path: item.id, directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try Self.png(source, size: size).write(to: folder.appending(path: "\(id)-source.png"))
                try Self.png(image, size: size).write(to: folder.appending(path: "\(id)-posed.png"))
            }
        }
        return lines
    }

    // MARK: - The oracle

    struct Comparison {
        /// Intersection over union of the drawn and expected coverage (alpha ≥ ½).
        var iou: Double
        /// Mean absolute alpha difference, 0…255, over the samples.
        var alphaError: Double
        /// Mean absolute colour difference, 0…255, where both are nearly opaque.
        var colourError: Double
        /// The share of the source picture's opaque texels the mesh covers (rigs laid over their picture).
        var pictureCovered: Double
        /// Every vertex sits where its texture coordinate is in the picture: the bind pose is the picture.
        var unwarped: Bool
    }

    /// The mesh skinned with `pose` (`p′ = Σ wᵢ · bone[iᵢ] · p`) rasterised on the CPU at pixel
    /// centres (every `step`th row and column): the source sampled bilinearly at each centre's
    /// texture coordinate, triangles composited "over" in index order; compared with the drawn image there.
    /// `canvas` is what of the mesh's space the image covers (nil: the image's rect).
    static func compare(_ plan: ScenePuppetPlan, source: [UInt8], image: [UInt8], size: SIMD2<Int>,
                        pose: ScenePuppetPose, canvas: ScenePuppetCanvas? = nil) -> Comparison {
        let canvas = canvas ?? .image(plan.imageSize)
        let content = SIMD2(Float(plan.contentPixels.x), Float(plan.contentPixels.y))
        let texture = SIMD2(Float(size.x), Float(size.y))
        let mesh = MDLMesh(materials: [], flags: plan.usesUInt32Indices ? 1 : 0, format: plan.format,
                           vertexData: plan.vertexData, indexData: plan.indexData)
        let positions = mesh.floatValues(.position) ?? mesh.floatValues(.positionVec4)!
        let components = mesh.format.contains(.position) ? 3 : 4
        let uvs = mesh.floatValues(.texCoord)!
        let count = mesh.vertexCount
        let bones = mesh.unsignedValues(.blendIndices) ?? [UInt32](repeating: 0, count: count * 4)
        let weights = mesh.floatValues(.blendWeights) ?? (0..<count * 4).map { $0 % 4 == 0 ? 1 : 0 }
        // Vertices in target pixels, y down; texture coordinates in texels.
        let pixel = (0..<count).map { index -> SIMD2<Float> in
            let bind = SIMD4(positions[index * components], positions[index * components + 1], positions[index * components + 2], 1)
            var skinned = SIMD4<Float>.zero
            for k in 0..<4 where weights[index * 4 + k] != 0 && Int(bones[index * 4 + k]) < pose.bones.count {
                skinned += weights[index * 4 + k] * (pose.bones[Int(bones[index * 4 + k])] * bind)
            }
            let p = SIMD2(skinned.x, skinned.y)
            return SIMD2((p.x - canvas.min.x) / canvas.size.x * content.x, (canvas.max.y - p.y) / canvas.size.y * content.y)
        }
        let texel = (0..<count).map { SIMD2(uvs[$0 * 2], uvs[$0 * 2 + 1]) * texture }
        let unwarped = zip(pixel, texel).allSatisfy { simd_length($0 - $1) < 0.05 }

        // The mesh pass samples its image bilinearly (clamped or repeated as the material says), as
        // WE's linear sampler does; a nearest texel moves an alpha edge by up to half a texel once
        // the pose moves the mesh off the texel grid.
        let clamped = plan.material.clampedSlots.contains(0)
        func texelAt(_ x: Int, _ y: Int) -> SIMD4<Float> {
            let tx = clamped ? min(max(x, 0), size.x - 1) : ((x % size.x) + size.x) % size.x
            let ty = clamped ? min(max(y, 0), size.y - 1) : ((y % size.y) + size.y) % size.y
            let offset = (ty * size.x + tx) * 4
            return SIMD4(Float(source[offset]), Float(source[offset + 1]), Float(source[offset + 2]), Float(source[offset + 3])) / 255
        }
        func bilinear(_ uv: SIMD2<Float>) -> SIMD4<Float> {
            let p = uv - 0.5, base = p.rounded(.down), f = p - base
            let x = Int(base.x), y = Int(base.y)
            let top = texelAt(x, y) * (1 - f.x) + texelAt(x + 1, y) * f.x
            let bottom = texelAt(x, y + 1) * (1 - f.x) + texelAt(x + 1, y + 1) * f.x
            return top * (1 - f.y) + bottom * f.y
        }

        let step = max(1, Int((Double(plan.contentPixels.x * plan.contentPixels.y) / 400_000).squareRoot().rounded(.up)))
        let columns = (plan.contentPixels.x + step - 1) / step, rows = (plan.contentPixels.y + step - 1) / step
        var expected = [SIMD4<Float>](repeating: .zero, count: columns * rows) // premultiplied
        let indices = mesh.indices
        for triangle in stride(from: 0, to: indices.count - 2, by: 3) {
            let (a, b, c) = (Int(indices[triangle]), Int(indices[triangle + 1]), Int(indices[triangle + 2]))
            let (pa, pb, pc) = (pixel[a], pixel[b], pixel[c])
            let area = (pb.x - pa.x) * (pc.y - pa.y) - (pb.y - pa.y) * (pc.x - pa.x)
            guard abs(area) > 1e-8 else { continue }
            let low = simd_max(simd_min(simd_min(pa, pb), pc), .zero), high = simd_max(simd_max(pa, pb), pc)
            let firstColumn = max(0, Int(((low.x - 0.5) / Float(step)).rounded(.up)))
            let firstRow = max(0, Int(((low.y - 0.5) / Float(step)).rounded(.up)))
            guard firstColumn < columns, firstRow < rows else { continue }
            let lastColumn = min(columns - 1, Int(((high.x - 0.5) / Float(step)).rounded(.down)))
            let lastRow = min(rows - 1, Int(((high.y - 0.5) / Float(step)).rounded(.down)))
            guard firstColumn <= lastColumn, firstRow <= lastRow else { continue }
            for row in firstRow...lastRow {
                for column in firstColumn...lastColumn {
                    let point = SIMD2(Float(column * step) + 0.5, Float(row * step) + 0.5)
                    let wa = ((pb.x - point.x) * (pc.y - point.y) - (pb.y - point.y) * (pc.x - point.x)) / area
                    let wb = ((pc.x - point.x) * (pa.y - point.y) - (pc.y - point.y) * (pa.x - point.x)) / area
                    let wc = 1 - wa - wb
                    guard wa >= 0, wb >= 0, wc >= 0 else { continue }
                    let uv = texel[a] * wa + texel[b] * wb + texel[c] * wc
                    let colour = bilinear(uv)
                    let premultiplied = SIMD4(colour.x * colour.w, colour.y * colour.w, colour.z * colour.w, colour.w)
                    let slot = row * columns + column
                    expected[slot] = premultiplied + expected[slot] * (1 - colour.w)
                }
            }
        }

        var union = 0, intersection = 0, samples = 0, opaque = 0, pictureOpaque = 0, pictureCovered = 0
        var alphaError = 0.0, colourError = 0.0
        for row in 0..<rows {
            for column in 0..<columns {
                let x = column * step, y = row * step
                let offset = (y * size.x + x) * 4
                let want = expected[row * columns + column]
                let wantAlpha = Double(want.w) * 255
                let gotAlpha = Double(image[offset + 3])
                samples += 1
                alphaError += abs(wantAlpha - gotAlpha)
                let wantCovered = wantAlpha >= 127.5, gotCovered = gotAlpha >= 127.5
                if wantCovered || gotCovered { union += 1 }
                if wantCovered && gotCovered { intersection += 1 }
                if wantAlpha >= 230, gotAlpha >= 230 {
                    opaque += 1
                    for channel in 0..<3 {
                        colourError += abs(Double(want[channel] / want.w) * 255 - Double(image[offset + channel])) / 3
                    }
                }
                if source[offset + 3] >= 128 {
                    pictureOpaque += 1
                    if gotCovered { pictureCovered += 1 }
                }
            }
        }
        return Comparison(iou: union == 0 ? 1 : Double(intersection) / Double(union),
                          alphaError: alphaError / Double(max(samples, 1)),
                          colourError: colourError / Double(max(opaque, 1)),
                          pictureCovered: pictureOpaque == 0 ? 1 : Double(pictureCovered) / Double(pictureOpaque),
                          unwarped: unwarped)
    }

    static func png(_ pixels: [UInt8], size: SIMD2<Int>) throws -> Data {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(width: size.x, height: size.y, bitsPerComponent: 8, bitsPerPixel: 32,
                                          bytesPerRow: size.x * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                          provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let rep = NSBitmapImageRep(cgImage: image)
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    // MARK: - The library

    private struct Item {
        var id: String
        var workshopID: String
        var directory: URL
        var project: WEProject
        /// The ids of the image objects whose model names a `puppet`.
        var layers: [String]
    }

    /// Scenes with Puppet Warp images (de-duplicated by Workshop id, the first root first).
    private static func puppetScenes(in roots: [URL]) throws -> [Item] {
        var seen = Set<String>(), items: [Item] = []
        for root in roots {
            for name in try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() {
                let directory = root.appending(path: name, directoryHint: .isDirectory)
                // `try?`: a folder without a readable project.json isn't a wallpaper.
                guard let data = try? Data(contentsOf: directory.appending(path: "project.json")) else { continue }
                let text = Data(String(decoding: data, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}")).utf8)
                guard let json = try? JSONSerialization.jsonObject(with: text, options: [.json5Allowed]) as? [String: Any] else { continue }
                let workshopID = json["workshopid"].map { "\($0)" } ?? ""
                let key = workshopID.isEmpty || workshopID == "0" ? name : workshopID
                guard !seen.contains(key), !seen.contains(name) else { continue }
                seen.formUnion([key, name])
                guard (json["type"] as? String)?.lowercased() == "scene" else { continue }
                let reader = Reader(directory: directory)
                guard let file = reader.read(json["file"] as? String ?? "scene.json") else { continue }
                let scene = try decodeTolerant(WEScene.self, from: file)
                var layers: [String] = []
                for object in scene.objects {
                    // Optional: an object whose model can't be read has no rig to check.
                    guard let image = object.image, let modelData = reader.read(image),
                          let model = try? decodeTolerant(WEModel.self, from: modelData), model.puppet != nil else { continue }
                    layers.append(String(object.id ?? -1))
                }
                guard !layers.isEmpty else { continue }
                let project = try decodeTolerant(WEProject.self, from: text)
                items.append(Item(id: name, workshopID: key, directory: directory, project: project, layers: layers))
            }
        }
        return items
    }

    /// A loose file wins over the same path inside the folder's `.pkg`, as WE reads a wallpaper.
    private struct Reader {
        let directory: URL
        private let packages: [PKGParser]

        init(directory: URL) {
            self.directory = directory
            var packages: [PKGParser] = []
            let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
            while let url = enumerator?.nextObject() as? URL {
                guard url.pathExtension == "pkg" else { continue }
                do { packages.append(try PKGParser(url: url)) } catch { XCTFail("\(url.path): \(error)") }
            }
            self.packages = packages
        }

        func read(_ file: String) -> Data? {
            if let loose = FileManager.default.contents(atPath: directory.appending(path: file).path) { return loose }
            for package in packages {
                if let data = package.extractFile(named: file) { return data }
            }
            return nil
        }
    }
}
