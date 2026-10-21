import Metal
import simd
import XCTest
@testable import OpenWallpaperEngine

/// A script's model data changes on the script's thread while the renderer draws it and the loader
/// rebuilds the scene: `applyData` every frame, `replaceData` now and then (which re-creates the
/// model), frames drawing it, and the scene reloading, all at once. The new plan is made on the
/// script's thread under the loader's scene lock (`SceneScriptModelGeometry.dataReplaced`); the
/// render thread only takes it. Before, the render thread planned it, reading the loader's asset
/// cache without the lock while a reload emptied it. Run it under the Thread Sanitizer
/// (`-enableThreadSanitizer YES`, `TSAN_OPTIONS=halt_on_error=1`) to see a race as a failure.
final class SceneScriptModelConcurrencyTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appending(path: "owe-modeldata-race-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch, FileManager.default.fileExists(atPath: scratch.path) {
            try FileManager.default.removeItem(at: scratch)
        }
    }

    /// `count` quads side by side from `left`, each its own shape with position and normal.
    private static func data(shapes count: Int, left: Float) throws -> SceneScriptModelData {
        let format = try XCTUnwrap(SceneScriptModelData.format(["position", "normal"]))
        let indices: [UInt16] = [0, 1, 2, 0, 2, 3]
        let shapes = (0..<count).map { index in
            SceneScriptModelData.Shape(
                format: format, materialPaths: ["materials/facecolor.json"],
                vertices: quad(left: left + Float(index)).withUnsafeBytes { Data($0) },
                indices: indices.withUnsafeBytes { Data($0) }, usesUInt32Indices: false,
                dynamicVertices: true, dynamicIndices: true)
        }
        return SceneScriptModelData(shapes: shapes, bounds: MDLBounds(min: SIMD3(-4, -1, -1), max: SIMD3(4, 1, 1)))
    }

    private static func quad(left: Float) -> [Float] {
        [SIMD2<Float>(left, -0.5), SIMD2(left + 1, -0.5), SIMD2(left + 1, 0.5), SIMD2(left, 0.5)]
            .flatMap { [$0.x, $0.y, 0, 0, 0, 1] }
    }

    /// A 64 × 64 scene with one scripted value (so it runs scripts) and the model material and
    /// its shaders in the wallpaper.
    private func wallpaper(_ name: String = "wallpaper") throws -> WEWallpaper {
        let fm = FileManager.default
        let directory = scratch.appending(path: name, directoryHint: .isDirectory)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        for folder in ["materials", "shaders"] {
            try fm.copyItem(at: Fixtures.url("ModelMaterials").appending(path: folder), to: directory.appending(path: folder))
        }
        let scene = #"""
        {"camera":{"center":"0 0 -1","eye":"0 0 0","up":"0 1 0"},
         "general":{"clearcolor":"0 0 0","orthogonalprojection":{"width":64,"height":64}},
         "objects":[{"id":1,"name":"script host","origin":{"script":"export function update(value) { return value; }",
                                                           "value":"32 32 0"}}]}
        """#
        try Data(scene.utf8).write(to: directory.appending(path: "scene.json"))
        let project = #"{"file":"scene.json","title":"modeldata race","type":"scene","general":{"properties":{}}}"#
        try Data(project.utf8).write(to: directory.appending(path: "project.json"))
        return WEWallpaper(using: try decodeTolerant(WEProject.self, from: Data(project.utf8)), where: directory)
    }

    func testReplaceApplyAndFramesRunTogether() throws {
        let shown = try wallpaper(), other = try wallpaper("other")
        let model = SceneContentLoader(wallpaper: shown)
        defer {
            Fixtures.removeStoredSettings(for: shown.wallpaperDirectory)
            Fixtures.removeStoredSettings(for: other.wallpaperDirectory)
        }
        let scripts = try XCTUnwrap(model.metalContent()?.scripts, "the scene has script content")
        let store = scripts.modelData
        let token = store.create(try Self.data(shapes: 1, left: -0.5))
        guard case .model(let object, _, _)? = scripts.makeLayer(["name": .string("cloth"), "model": .number(Double(token))]),
              let authored = object.plan else { return XCTFail("the model layer plans") }

        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let renderer = try XCTUnwrap(SceneModelRenderer(device: device, archive: nil))
        let depthStates = try XCTUnwrap(SceneDepthStates(device: device))
        renderer.setContent([object], content: SceneMetalContent(size: SIMD2(64, 64), layers: [], particleSystems: [],
                                                                 bloom: SceneBloomSettings(enabled: false, strength: 0,
                                                                                           threshold: 0.7, tint: SIMD3(repeating: 1))))
        XCTAssertTrue(renderer.waitUntilReady(authored, pixelFormat: .bgra8Unorm))
        let target = try ModelRenderTests.target(device: device, size: 64)
        let depth = SceneDepthBuffer(device: device)
        XCTAssertTrue(depth.prepare(width: 64, height: 64, sampleCount: 1))
        let camera = ModelRenderTests.camera(eye: SIMD3(0, 0, 6))
        func drawFrame() {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            depth.attach(to: pass, clear: true)
            guard let buffer = queue.makeCommandBuffer(), let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
            var frame = BuiltinFrameContext()
            frame.camera = camera
            frame.eyePosition = camera.eye
            renderer.draw(object, SceneModelDraw(world: matrix_identity_float4x4, camera: camera, frame: frame,
                                                 values: EffectGraphTests.FixedValues(), pixelFormat: .bgra8Unorm, sampleCount: 1,
                                                 depth: depthStates, mipMappedFrameBuffer: nil, assetTexture: { _, _ in nil }),
                          encoder: encoder, commandBuffer: buffer)
            encoder.endEncoding()
            buffer.commit()
            buffer.waitUntilCompleted()
        }

        let replacements = 24
        let lastShapes = (replacements - 1) % 3 + 1
        let scriptDone = DispatchSemaphore(value: 0), loaderDone = DispatchSemaphore(value: 0)
        let stop = ManagedAtomicFlag()
        let scriptErrors = LockedList<Error>()
        // The script's thread: applyData every step, replaceData every eighth, and asset reads.
        let script = Thread {
            defer { scriptDone.signal() }
            do {
                for step in 0..<(replacements * 8) {
                    let left = Float(step % 7) / 7 - 0.5
                    if step % 8 == 7 {
                        try store.replace(token, with: Self.data(shapes: step / 8 % 3 + 1, left: left))
                    } else {
                        let shapes = store.snapshot(token)?.data.shapes.count ?? 1
                        try store.apply(token, (0..<shapes).map { index in
                            SceneScriptModelDataUpdate(vertices: Self.quad(left: left + Float(index)).withUnsafeBytes { Data($0) })
                        })
                    }
                    _ = scripts.file("materials/facecolor.json")
                }
            } catch {
                scriptErrors.append(error)
            }
        }
        // The loader: another wallpaper loads (emptying the asset caches) and builds, then this one
        // again, as switching wallpapers does.
        let loader = Thread {
            defer { loaderDone.signal() }
            while !stop.isSet {
                for wallpaper in [other, shown] {
                    model.loadScene(from: wallpaper, prepareDefaults: false)
                    model.invalidateContent()
                    _ = model.metalContent()
                }
            }
        }
        script.start()
        loader.start()
        // The render thread: frames drawing the model, taking replaced plans and applied geometry.
        var frames = 0
        while scriptDone.wait(timeout: .now()) == .timedOut {
            drawFrame()
            frames += 1
        }
        stop.set()
        loaderDone.wait()
        XCTAssertTrue(scriptErrors.items.isEmpty, "\(scriptErrors.items)")
        XCTAssertGreaterThan(frames, 0)

        let final = renderer.currentPlan(authored, objectID: object.id)
        XCTAssertEqual(final.meshes.count, lastShapes, "the last replaceData's shapes draw")
        XCTAssertNil(final.geometry?.replacement(for: final), "each replacement is taken once")
        drawFrame()
    }
}

/// What one thread collects for another to read.
private final class LockedList<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Element] = []
    var items: [Element] { lock.withLock { values } }
    func append(_ value: Element) { lock.withLock { values.append(value) } }
}

/// A flag one thread sets and another polls.
private final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
