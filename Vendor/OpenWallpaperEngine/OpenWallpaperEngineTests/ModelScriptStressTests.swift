import XCTest
import MetalKit
import simd
@testable import OpenWallpaperEngine

/// Script model data changed on the script thread while the render thread draws it, through the
/// real loader, script runtime and renderer (docs/models-plan.md §4.3 T): `applyData` every
/// `update`, `replaceData` from a timer every few frames (other shape counts, 16- and 32-bit
/// indices), frames drawn back to back without waiting for the script thread, and the content
/// rebuilt twice mid-run. Nothing may fail on the GPU or hang; run it under the Thread Sanitizer
/// (`-enableThreadSanitizer YES`) to see a data race.
final class ModelScriptStressTests: XCTestCase {
    private var scratch: URL!
    private var storage: URL!

    override func setUpWithError() throws {
        let id = UUID().uuidString
        scratch = FileManager.default.temporaryDirectory.appending(path: "owe-model-stress-\(id)")
        storage = FileManager.default.temporaryDirectory.appending(path: "owe-model-stress-storage-\(id)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for url in [scratch, storage].compactMap({ $0 }) where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private static let script = """
        'use strict';
        let data;
        let frames = 0;
        let replacements = 0;
        let layout = { count: 1, columns: 16 };
        function grid(columns, phase) {
            const vertices = new Float32Array(columns * 4 * 6);
            for (let c = 0; c < columns; c++) {
                const x = -2 + 4 * c / columns, w = 4 / columns, y = Math.sin(phase + c) * 0.2;
                const corners = [[x, y - 0.5], [x + w, y - 0.5], [x + w, y + 0.5], [x, y + 0.5]];
                corners.forEach(function (p, i) {
                    vertices.set([p[0], p[1], 0, 0, 0, 1], (c * 4 + i) * 6);
                });
            }
            return vertices;
        }
        function indices(columns, wide) {
            const list = wide ? new Uint32Array(columns * 6) : new Uint16Array(columns * 6);
            for (let c = 0; c < columns; c++) list.set([c * 4, c * 4 + 1, c * 4 + 2, c * 4, c * 4 + 2, c * 4 + 3], c * 6);
            return list;
        }
        function shapes(count, columns, wide) {
            const list = [];
            for (let s = 0; s < count; s++) {
                list.push({ vertexBuffer: grid(columns, s), indexBuffer: indices(columns, wide),
                            vertexFormat: ['position', 'normal'], material: 'materials/facecolor.json',
                            isVertexBufferDynamic: true, isIndexBufferDynamic: true });
            }
            return list;
        }
        function replace() {
            replacements += 1;
            layout = { count: 1 + replacements % 3, columns: 8 + replacements % 5 };
            data.replaceData({ shapes: shapes(layout.count, layout.columns, replacements % 2 == 0) });
            engine.setTimeout(replace, 30);
        }
        export function init(value) {
            data = thisScene.createModelData({ boundingBoxMins: new Vec3(-3, -3, -3), boundingBoxMaxs: new Vec3(3, 3, 3),
                                               shapes: shapes(1, 16, false) });
            thisScene.createLayer({ name: 'stressed', model: data });
            engine.setTimeout(replace, 30);
            return value;
        }
        export function update(value) {
            frames += 1;
            const updates = [];
            for (let s = 0; s < layout.count; s++) updates.push({ vertexBuffer: grid(layout.columns, frames * 0.1 + s) });
            data.applyData({ shapes: updates });
            return value;
        }
        """

    func testApplyAndReplaceDataWhileFramesDraw() throws {
        _ = try Fixtures.assets()
        let text = String(data: try JSONSerialization.data(withJSONObject: [Self.script]), encoding: .utf8)!
        let host = #"{"id":1,"name":"host","origin":{"script":\#(text.dropFirst().dropLast()),"value":"0 0 0"}}"#
        let wallpaper = try ModelFixtureWallpaper(in: scratch, name: "stress", objects: [host])
        let harness = try ModelSceneHarness(directory: wallpaper.directory, settings: SceneRenderSettings(),
                                            size: SIMD2(256, 144), storage: storage)
        defer { harness.close() }
        try harness.settle(seconds: 10)
        let store = try XCTUnwrap(harness.content.scripts?.modelData, "the scene runs scripts")
        harness.renderer.scripts.frameWait = 0
        let drawable = SIMD2<Float>(256, 144)
        var errors: [String] = []
        let start = Date()
        for frame in 0..<400 {
            // Frames back to back: the script thread runs its update and timers while these draw.
            harness.renderer.wallTime = { [start] in 1000 + Date().timeIntervalSince(start) }
            harness.renderer.renderShared([SceneViewport(drawableSize: drawable, pointSize: drawable, cursor: nil,
                                                         frameRateLimit: 120)])
            if let buffer = harness.renderer.lastCommandBuffer {
                buffer.waitUntilCompleted()
                if let error = buffer.error { errors.append("frame \(frame): \(error)") }
            }
            RunLoop.main.run(until: Date())
            if frame == 150 || frame == 300 {
                // The content rebuilt mid-run, as a user property change does.
                harness.model.invalidateContent()
                harness.renderer.setContent(try XCTUnwrap(harness.model.metalContent()))
            }
        }
        harness.renderer.scripts.wallpaper?.waitUntilIdle()
        XCTAssertEqual(errors, [])
        XCTAssertLessThan(Date().timeIntervalSince(start), 120, "400 frames in under two minutes")
        XCTAssertGreaterThan(harness.models?.drawsEncoded ?? 0, 0, "the script's model drew")
        let replaced = (1...8).compactMap { store.replaced($0)?.generation }.max() ?? 0
        XCTAssertGreaterThan(replaced, 5, "the timer replaced the data while frames drew")
    }
}
