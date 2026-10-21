import XCTest
import simd
@testable import OpenWallpaperEngine

/// WE's camera layers (docs/models-plan.md §2.3; the layer update 0x1401f2ad0, the camera update
/// 0x140189220…0x140189402): the active layer, its view from its world matrix and parents, path
/// playback with both queue modes, the write-back, and where the fov comes from.
final class SceneCameraLayersTests: XCTestCase {
    private static func assertClose(_ a: SIMD3<Float>, _ b: SIMD3<Float>, accuracy: Float = 1e-4, _ message: String = "",
                                    file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThan(simd_length(a - b), accuracy, "\(a) vs \(b) \(message)", file: file, line: line)
    }

    /// A constant channel: one keyframe per component.
    private static func vector(_ value: SIMD3<Float>) -> String {
        #"{"c0": [{"frame": 0, "value": \#(value.x)}], "c1": [{"frame": 0, "value": \#(value.y)}], "c2": [{"frame": 0, "value": \#(value.z)}]}"#
    }

    /// A path of `frames` frames at 10 fps, played once.
    private static func path(eye: SIMD3<Float>? = nil, center: SIMD3<Float>? = nil, fov: Float? = nil, frames: Int = 5,
                             visible: Bool = true) -> String {
        var fields = [#""options": {"fps": 10, "length": \#(frames), "mode": "single", "wraploop": false}"#,
                      #""visible": \#(visible)"#]
        if let eye { fields.append(#""eye": \#(vector(eye))"#) }
        if let center { fields.append(#""center": \#(vector(center))"#) }
        if let fov { fields.append(#""fov": [{"frame": 0, "value": \#(fov)}]"#) }
        return "{" + fields.joined(separator: ", ") + "}"
    }

    private static func layer(_ id: String, order: Int, paths: [String] = [], queue: WESceneCameraLayer.QueueMode = .sequential,
                              fov: Double = 40, authorsVisible: Bool = true) throws -> SceneCameraLayerObject {
        let file = try WECameraLayerPathFile(data: Data(#"{"paths": [\#(paths.joined(separator: ", "))]}"#.utf8))
        XCTAssertEqual(file.paths.count, paths.count)
        return SceneCameraLayerObject(id: id, name: id, order: order,
                                      authored: WESceneCameraLayer(camera: "default", path: "p.json", queueMode: queue,
                                                                   values: [.fov: .number(fov)], authorsVisible: authorsVisible),
                                      pathFile: file)
    }

    /// The objects' authored transforms and parents (M3's hierarchy).
    private static func transforms(_ nodes: [String: (local: SceneLocalTransform3D, parent: String?)] = [:]) -> SceneTransformHierarchy3D {
        SceneTransformHierarchy3D(nodes: nodes.mapValues { SceneTransformHierarchy3D.Node(parentID: $0.parent, local: $0.local) })
    }

    private static func local(origin: SIMD3<Float> = .zero, angles: SIMD3<Float> = .zero) -> SceneLocalTransform3D {
        SceneLocalTransform3D(origin: origin, scale: SIMD3(repeating: 1), angles: angles)
    }

    private static func input(visible: Set<String>? = nil, live: [String: SceneLocalTransform3D] = [:],
                              fov: [String: Float] = [:], zoom: [String: Float] = [:]) -> SceneCameraLayers.FrameInput {
        SceneCameraLayers.FrameInput(deltaTime: 0.1, isVisible: { visible?.contains($0) ?? true },
                                     live: { live[$0] }, fov: { fov[$0] }, zoom: { zoom[$0] })
    }

    // MARK: - The active layer and its view

    /// The last visible layer in scene order is the camera; it looks down its local −z with +y up,
    /// from its origin, with its own fov while no path plays.
    func testTheLastVisibleLayerIsTheCamera() throws {
        let tilted = Self.local(origin: SIMD3(0, 4, 5), angles: SIMD3(-0.38397, 0, 0))
        let layers = SceneCameraLayers([try Self.layer("a", order: 0, fov: 30), try Self.layer("b", order: 1, fov: 58.09)],
                                       transforms: Self.transforms(["b": (tilted, nil)]), values: SpatialProperties())
        let both = try XCTUnwrap(layers.update(Self.input()))
        XCTAssertEqual(both.id, "b")
        XCTAssertEqual(both.fov, 58.09, accuracy: 1e-5)
        Self.assertClose(both.pose.eye, SIMD3(0, 4, 5))
        // Rx(−0.384): row 2 = (0, sin x·…, cos x) — forward is −row 2, tipped down.
        let x: Float = -0.38397
        Self.assertClose(simd_normalize(both.pose.center - both.pose.eye), SIMD3(0, sin(x), -cos(x)))
        XCTAssertLessThan(both.pose.center.y, both.pose.eye.y, "the camera looks down")
        XCTAssertEqual(try XCTUnwrap(layers.update(Self.input(visible: ["a"]))).id, "a")
        XCTAssertNil(layers.update(Self.input(visible: [])))
        // A script's `fov` on the layer.
        XCTAssertEqual(try XCTUnwrap(layers.update(Self.input(fov: ["b": 70]))).fov, 70)
        // A script's `zoom` (`ICamera.zoom`) on the layer, over its authored 1.
        XCTAssertEqual(try XCTUnwrap(layers.update(Self.input())).zoom, 1)
        XCTAssertEqual(try XCTUnwrap(layers.update(Self.input(zoom: ["b": 2.5]))).zoom, 2.5)
        // A script's transform on the layer wins.
        let moved = try XCTUnwrap(layers.update(Self.input(live: ["b": Self.local(origin: SIMD3(1, 1, 1))])))
        Self.assertClose(moved.pose.eye, SIMD3(1, 1, 1))
    }

    /// A parented layer's view is its world matrix: the parent's transform applies.
    func testAParentMovesTheCamera() throws {
        let parent = Self.local(origin: SIMD3(10, 0, 0), angles: SIMD3(0, .pi / 2, 0))
        let hierarchy = Self.transforms(["p": (parent, nil), "cam": (Self.local(origin: SIMD3(0, 0, 2)), "p")])
        let layers = SceneCameraLayers([try Self.layer("cam", order: 0)], transforms: hierarchy, values: SpatialProperties())
        let camera = try XCTUnwrap(layers.update(Self.input()))
        let world = parent.matrix * Self.local(origin: SIMD3(0, 0, 2)).matrix
        Self.assertClose(camera.pose.eye, SIMD3(world[3].x, world[3].y, world[3].z))
        // Ry(π/2): row 2 = (cos x·sin y, …, cos x·cos y) = (1, 0, 0), so the camera looks down −x.
        Self.assertClose(simd_normalize(camera.pose.center - camera.pose.eye), SIMD3(-1, 0, 0))
        Self.assertClose(camera.pose.eye, SIMD3(12, 0, 0))
    }

    /// `ILayer.setParent` reaches the camera layers' copy of the parent graph.
    func testReparentingMovesTheCamera() throws {
        let parent = Self.local(origin: SIMD3(10, 0, 0), angles: SIMD3(0, .pi / 2, 0))
        let hierarchy = Self.transforms(["p": (parent, nil), "cam": (Self.local(origin: SIMD3(0, 0, 2)), nil)])
        let layers = SceneCameraLayers([try Self.layer("cam", order: 0)], transforms: hierarchy, values: SpatialProperties())
        Self.assertClose(try XCTUnwrap(layers.update(Self.input())).pose.eye, SIMD3(0, 0, 2))
        layers.setParent("cam", to: "p", attachment: nil)
        Self.assertClose(try XCTUnwrap(layers.update(Self.input())).pose.eye, SIMD3(12, 0, 0))
        layers.setParent("cam", to: nil, attachment: nil)
        Self.assertClose(try XCTUnwrap(layers.update(Self.input())).pose.eye, SIMD3(0, 0, 2))
    }

    // MARK: - Paths

    /// WE 2.8.42 plays a camera layer's paths only when the object authors `visible`, in any form
    /// (docs/models-plan.md §5.19, models-open/519b): without the key the layer is still the
    /// camera, from its own transform, and its path doesn't move it.
    func testPathsPlayOnlyWhenTheLayerAuthorsVisible() throws {
        let eye = SIMD3<Float>(5, 0, 0)
        let path = Self.path(eye: eye, center: SIMD3(5, 0, -5), frames: 50)
        let silent = SceneCameraLayers([try Self.layer("cam", order: 0, paths: [path], authorsVisible: false)],
                                       transforms: Self.transforms(), values: SpatialProperties())
        for _ in 0..<5 { Self.assertClose(try XCTUnwrap(silent.update(Self.input())).pose.eye, .zero) }
        XCTAssertNil(silent.playingPath("cam"))
        XCTAssertNil(silent.writtenBack("cam"))
        let playing = SceneCameraLayers([try Self.layer("cam", order: 0, paths: [path])],
                                        transforms: Self.transforms(), values: SpatialProperties())
        Self.assertClose(try XCTUnwrap(playing.update(Self.input())).pose.eye, eye)

        func authors(_ object: String) throws -> Bool {
            try XCTUnwrap(JSONDecoder().decode(WESceneObject.self, from: Data(object.utf8)).cameraLayer).authorsVisible
        }
        XCTAssertFalse(try authors(#"{"camera": "default", "path": "p.json"}"#))
        XCTAssertTrue(try authors(#"{"camera": "default", "visible": {"value": true}}"#))
        XCTAssertTrue(try authors(#"{"camera": "default", "visible": true}"#))
        XCTAssertTrue(try authors(#"{"camera": "default", "visible": {"user": {"condition": "0", "name": "camerastyle"}, "value": true}}"#))
    }

    /// While a path plays, its write-back wins over a script's `origin` and `angles` on the layer
    /// (WE 2.8.42, models-open/520: the script's drift never shows); without a path the script
    /// moves the camera (`testTheLastVisibleLayerIsTheCamera`).
    func testAPlayingPathWinsOverAScriptedOrigin() throws {
        let eye = SIMD3<Float>(5, 0, 0)
        let layers = SceneCameraLayers([try Self.layer("cam", order: 0, paths: [Self.path(eye: eye, center: SIMD3(5, 0, -5), frames: 50)])],
                                       transforms: Self.transforms(), values: SpatialProperties())
        let scripted = Self.input(live: ["cam": Self.local(origin: SIMD3(-400, 0, 0), angles: SIMD3(0, 30, 0))])
        for _ in 0..<3 {
            let camera = try XCTUnwrap(layers.update(scripted))
            Self.assertClose(camera.pose.eye, eye)
            Self.assertClose(simd_normalize(camera.pose.center - camera.pose.eye), SIMD3(0, 0, -1))
        }
    }

    /// "sequential": each finished path hands over to the next visible one, wrapping. A path's
    /// channels drive the camera and are written back into the layer; a component without keys
    /// follows the layer's transform as it stands, which is the last write-back.
    func testSequentialPathsPlayInTurnAndWriteBack() throws {
        let layers = SceneCameraLayers([try Self.layer("cam", order: 0, paths: [
            Self.path(eye: SIMD3(1, 2, 3), center: SIMD3(1, 2, 0), fov: 30),
            Self.path(visible: false),
            Self.path(eye: SIMD3(4, 5, 6)),
        ])], transforms: Self.transforms(), values: SpatialProperties())
        var played: [Int] = []
        var cameras: [SceneCameraLayers.Camera] = []
        for _ in 0..<13 {
            cameras.append(try XCTUnwrap(layers.update(Self.input())))
            played.append(try XCTUnwrap(layers.playingPath("cam")))
        }
        // Five frames of 0.1 s fill each 0.5 s path; the hidden one never plays.
        XCTAssertEqual(played, [0, 0, 0, 0, 0, 2, 2, 2, 2, 2, 0, 0, 0])
        let first = cameras[0]
        Self.assertClose(first.pose.eye, SIMD3(1, 2, 3))
        Self.assertClose(simd_normalize(first.pose.center - first.pose.eye), SIMD3(0, 0, -1))
        XCTAssertEqual(first.fov, 30, "the path's fov")
        let written = try XCTUnwrap(layers.writtenBack("cam"))
        Self.assertClose(written.origin, SIMD3(1, 2, 3))
        // Path 2 has an eye and no centre: the centre is 5 ahead of the layer as path 0 left it.
        let second = cameras[5]
        Self.assertClose(second.pose.eye, SIMD3(4, 5, 6))
        Self.assertClose(simd_normalize(second.pose.center - second.pose.eye), simd_normalize(SIMD3(1, 2, -2) - SIMD3(4, 5, 6)))
        XCTAssertEqual(second.fov, 50, "a path without a fov channel keeps WE's 50, not the layer's")
    }

    /// `count` one-frame paths (each update draws the next), each authoring `visible` or not.
    private static func randomLayers(_ count: Int, authorsVisible: Bool = true, seed: UInt64) throws -> SceneCameraLayers {
        var paths = (0..<count).map { path(eye: SIMD3(Float($0), 0, 1), frames: 1) }
        if !authorsVisible { paths = paths.map { $0.replacingOccurrences(of: #", "visible": true"#, with: "") } }
        return SceneCameraLayers([try layer("cam", order: 0, paths: paths, queue: .random)],
                                 transforms: transforms(), values: SpatialProperties(), seed: seed)
    }

    private static func draws(_ layers: SceneCameraLayers, _ count: Int) throws -> [Int] {
        try (0..<count).map { _ in
            let camera = try XCTUnwrap(layers.update(input()))
            let index = try XCTUnwrap(layers.playingPath("cam"))
            XCTAssertEqual(camera.pose.eye.x, Float(index), "the drawn path is the one playing")
            return index
        }
    }

    /// "random" (0x1401f2bab…0x1401f2e70): a uniform index into a bag, stepped past the path drawn
    /// last, removed once drawn; an empty bag is refilled with each visible path once. The first
    /// bag is what the file's load leaves: every path that authors `visible` queues the ones loaded
    /// before it, and the load queues them all again, so 13 paths start as 12 twice and the last
    /// once (25 draws), then bags of 13. A path can follow itself only when the bag holds nothing
    /// else: the first bag's 25th draw, when its two last entries are one path (0x1401f2e2d takes
    /// the drawn entry once the step found no other).
    func testRandomPathsDrawFromTheBagTheLoadLeaves() throws {
        for seed in UInt64(1)...40 {
            let played = try Self.draws(try Self.randomLayers(13, seed: seed), 25 + 13 * 2)
            let first = Dictionary(grouping: played[..<25], by: { $0 }).mapValues(\.count)
            XCTAssertEqual(first, Dictionary(uniqueKeysWithValues: (0..<13).map { ($0, $0 == 12 ? 1 : 2) }), "seed \(seed): \(played)")
            XCTAssertEqual(Set(played[25..<38]).count, 13, "a refill holds each path once: \(played)")
            XCTAssertEqual(Set(played[38..<51]).count, 13, "\(played)")
            for index in 1..<played.count where index != 24 {
                XCTAssertNotEqual(played[index], played[index - 1], "seed \(seed): \(played)")
            }
        }
        // Without `visible` keys the hook never runs: the first bag holds each path once.
        let plain = try Self.draws(try Self.randomLayers(5, authorsVisible: false, seed: 3), 10)
        XCTAssertEqual(Set(plain[..<5]).count, 5, "\(plain)")
        XCTAssertEqual(Set(plain[5...]).count, 5, "\(plain)")
    }

    /// WE's measured behaviour on PaRappa's 13 paths (docs/test-risks.md MG1, three 70 s runs): no
    /// path follows itself, a path repeats before all 13 have played, none plays three times in
    /// the first 15, and the order and the first path differ from load to load.
    func testRandomPathsMatchWEsStatistics() throws {
        let runs = 2000
        var selfFollows = 0, repeatsEarly = 0, triples = 0
        var firsts = [Int](repeating: 0, count: 13)
        var orders = Set<[Int]>()
        for run in 0..<runs {
            // One draw plays hidden under the intro (MG1), then 15 are seen.
            let played = Array(try Self.draws(try Self.randomLayers(13, seed: UInt64(run) &* 7919 &+ 17), 16).dropFirst())
            selfFollows += zip(played, played.dropFirst()).filter { $0 == $1 }.count
            if Set(played[..<13]).count < 13 { repeatsEarly += 1 }
            if Dictionary(grouping: played, by: { $0 }).values.contains(where: { $0.count >= 3 }) { triples += 1 }
            firsts[played[0]] += 1
            orders.insert(played)
        }
        XCTAssertEqual(selfFollows, 0)
        XCTAssertEqual(triples, 0, "a two-copy bag never plays a path three times in its first 25 draws")
        XCTAssertGreaterThan(Double(repeatsEarly) / Double(runs), 0.95, "WE repeated a path before all 13 in every run")
        XCTAssertEqual(orders.count, runs, "every load draws its own order")
        // The first seen path over the 13 (the last one, queued once, is half as likely).
        let expected = (0..<13).map { Double(runs) * ($0 == 12 ? 1.0 / 25 : 2.0 / 25) }
        for (index, count) in firsts.enumerated() {
            XCTAssertEqual(Double(count), expected[index], accuracy: 5 * expected[index].squareRoot(), "path \(index): \(firsts)")
        }
    }

    /// Two loads without a given seed draw different orders (WE has no fixed seed).
    func testRandomQueuesAreSeededPerLoad() throws {
        let paths = (0..<13).map { Self.path(eye: SIMD3(Float($0), 0, 1), frames: 1) }
        var orders = Set<[Int]>()
        for _ in 0..<4 {
            let layers = SceneCameraLayers([try Self.layer("cam", order: 0, paths: paths, queue: .random)],
                                           transforms: Self.transforms(), values: SpatialProperties())
            orders.insert(try Self.draws(layers, 13))
        }
        XCTAssertGreaterThan(orders.count, 1)
    }

    /// A hidden layer doesn't play: its path's time stands until it shows again.
    func testAHiddenLayerDoesntPlay() throws {
        let layers = SceneCameraLayers([try Self.layer("cam", order: 0, paths: [Self.path(eye: SIMD3(0, 0, 1)),
                                                                                  Self.path(eye: SIMD3(9, 0, 1))])],
                                       transforms: Self.transforms(), values: SpatialProperties())
        for _ in 0..<3 { _ = layers.update(Self.input()) }
        for _ in 0..<10 { XCTAssertNil(layers.update(Self.input(visible: []))) }
        XCTAssertEqual(layers.playingPath("cam"), 0)
        for _ in 0..<2 { _ = layers.update(Self.input()) }
        XCTAssertEqual(layers.playingPath("cam"), 0, "five frames in, still the first path")
        _ = layers.update(Self.input())
        XCTAssertEqual(layers.playingPath("cam"), 1)
    }
}
