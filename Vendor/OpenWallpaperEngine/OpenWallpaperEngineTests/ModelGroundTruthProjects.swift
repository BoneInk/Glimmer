import XCTest
import simd
@testable import OpenWallpaperEngine

/// Writes the generated WE projects the Windows WE session captures for the models' open points
/// (docs/test-risks.md "Needs WE ground truth (models)": MG4 root motion, MG3 additive layers,
/// MG6 depth in an orthographic frame with models), each with our frames at the capture times as
/// the prediction to compare with. Only runs when `OWE_GROUND_TRUTH_OUT` names the output folder:
/// `<out>/<project>/` is the project (copy it into WE's `projects/myprojects`), `<out>/ours/` our
/// 1920×1080 frames.
final class ModelGroundTruthProjects: XCTestCase {
    private static let times: [Double] = [0.5, 1, 2, 3, 4]

    private static func material(_ color: String) -> Data {
        Data(#"{"passes":[{"shader":"generic4","combos":{"LIGHTING":0,"FOG":0},"constantshadervalues":{"color":"\#(color)"},"textures":["util/white"]}]}"#.utf8)
    }

    private static let colors = ["red": "1 0 0", "green": "0 1 0", "blue": "0 0 1", "white": "1 1 1"]

    private static var materials: [String: Data] {
        Dictionary(uniqueKeysWithValues: colors.map { ("materials/gt_\($0.key).json", material($0.value)) })
    }

    func testWriteTheGroundTruthProjects() throws {
        guard let path = ProcessInfo.processInfo.environment["OWE_GROUND_TRUTH_OUT"], !path.isEmpty else {
            throw XCTSkip("set OWE_GROUND_TRUTH_OUT to write the ground-truth projects")
        }
        let out = URL(fileURLWithPath: path, isDirectory: true)
        let ours = out.appending(path: "ours", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: ours, withIntermediateDirectories: true)
        let storage = FileManager.default.temporaryDirectory.appending(path: "owe-ground-truth-\(UUID().uuidString)")
        defer {
            if FileManager.default.fileExists(atPath: storage.path) {
                do { try FileManager.default.removeItem(at: storage) } catch { XCTFail("\(storage.path): \(error)") }
            }
        }
        var projects: [ModelFixtureWallpaper] = []
        projects += try orthographicDepth(out)
        projects += try rootMotion(out)
        projects += try additive(out)
        for project in projects {
            let harness = try ModelSceneHarness(directory: project.directory, settings: SceneRenderSettings(),
                                                size: SIMD2(1920, 1080), storage: storage)
            defer { harness.close() }
            try harness.settle(seconds: 10)
            var time = 0.0
            for shot in Self.times {
                while time + 1.0 / 60 < shot {
                    harness.frame()
                    time += 1.0 / 30
                }
                let bytes = try TextureUploadTests.read(try XCTUnwrap(harness.renderer.sharedFrame), device: harness.device)
                let name = "\(project.directory.lastPathComponent)-t\(shot).png"
                try WEReferenceImage(width: 1920, height: 1080, pixels: bytes).write(to: ours.appending(path: name))
            }
            XCTAssertEqual(harness.gpuErrors, [], project.directory.lastPathComponent)
        }
    }

    /// MG3 against WE 2.8.0.42's captures of the two projects: the arm's screen angle (the red
    /// centroid from the white one, y up) is 168.8° with the additive layer at blend 1 (−x:
    /// `base · additive`) and −175.3° at 0.5 (45° about z, the delta nlerped by the blend).
    func testAdditiveLayersMatchWEsCaptures() throws {
        _ = try Fixtures.assets()
        let scratch = FileManager.default.temporaryDirectory.appending(path: "owe-mg3-\(UUID().uuidString)")
        defer {
            if FileManager.default.fileExists(atPath: scratch.path) {
                do { try FileManager.default.removeItem(at: scratch) } catch { XCTFail("\(scratch.path): \(error)") }
            }
        }
        let storage = scratch.appending(path: "storage", directoryHint: .isDirectory)
        for (project, weAngle) in zip(try additive(scratch), [168.8, -175.3]) {
            let harness = try ModelSceneHarness(directory: project.directory, settings: SceneRenderSettings(),
                                                size: SIMD2(1920, 1080), storage: storage)
            defer { harness.close() }
            try harness.settle(seconds: 3)
            let bytes = try TextureUploadTests.read(try XCTUnwrap(harness.renderer.sharedFrame), device: harness.device)
            let angle = try XCTUnwrap(Self.armAngle(bytes, width: 1920), project.directory.lastPathComponent)
            XCTAssertEqual(angle, weAngle, accuracy: 1.5, project.directory.lastPathComponent)
            XCTAssertEqual(harness.gpuErrors, [], project.directory.lastPathComponent)
        }
    }

    /// MG6 against WE's captures: an orthographic scene with models depth-tests them, so the
    /// nearer red cube covers the overlap at (960, 540) whichever is drawn first (WE: (253, 0, 0)
    /// in both).
    func testOrthographicDepthMatchesWEsCaptures() throws {
        _ = try Fixtures.assets()
        let scratch = FileManager.default.temporaryDirectory.appending(path: "owe-mg6-\(UUID().uuidString)")
        defer {
            if FileManager.default.fileExists(atPath: scratch.path) {
                do { try FileManager.default.removeItem(at: scratch) } catch { XCTFail("\(scratch.path): \(error)") }
            }
        }
        let storage = scratch.appending(path: "storage", directoryHint: .isDirectory)
        for project in try orthographicDepth(scratch) {
            let harness = try ModelSceneHarness(directory: project.directory, settings: SceneRenderSettings(),
                                                size: SIMD2(1920, 1080), storage: storage)
            defer { harness.close() }
            try harness.settle(seconds: 3)
            let bytes = try TextureUploadTests.read(try XCTUnwrap(harness.renderer.sharedFrame), device: harness.device)
            let index = (540 * 1920 + 960) * 4
            let pixel = SIMD3<Int>(Int(bytes[index]), Int(bytes[index + 1]), Int(bytes[index + 2]))
            let name = project.directory.lastPathComponent
            XCTAssertGreaterThan(pixel.x, 200, "\(name): \(pixel)")
            XCTAssertLessThan(pixel.y, 40, "\(name): \(pixel)")
            XCTAssertEqual(harness.gpuErrors, [], name)
        }
    }

    /// MG6's particles: WE's `collisionmodel` element preview (an orthographic scene) hides the
    /// particles behind its sphere when their material tests depth. The orange density inside the
    /// sphere's disc over that outside it, 1.5–5 s after load, was 0.28 (shipped, depth test on),
    /// 0.13 (on) and 1.55 (off) in WE's captures.
    func testCollisionModelParticlesHideBehindTheSphereAsInWE() throws {
        _ = try Fixtures.assets()
        let preview = URL(fileURLWithPath: Self.weAssets + "/scenes/particleelementpreviews/collisionmodel", isDirectory: true)
        guard FileManager.default.fileExists(atPath: preview.appending(path: "scene.json").path) else {
            throw XCTSkip("WE's collisionmodel preview isn't installed")
        }
        let scratch = FileManager.default.temporaryDirectory.appending(path: "owe-mg6p-\(UUID().uuidString)")
        defer {
            if FileManager.default.fileExists(atPath: scratch.path) {
                do { try FileManager.default.removeItem(at: scratch) } catch { XCTFail("\(scratch.path): \(error)") }
            }
        }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        var ratios: [String: Double] = [:]
        for depthTest in ["enabled", "disabled"] {
            let directory = scratch.appending(path: "colmodel-\(depthTest)", directoryHint: .isDirectory)
            try FileManager.default.copyItem(at: preview, to: directory)
            let project = directory.appending(path: "project.json")
            if !FileManager.default.fileExists(atPath: project.path) {
                try Data(#"{"file":"scene.json","title":"colmodel","type":"scene","general":{"properties":{}}}"#.utf8).write(to: project)
            }
            let materials = directory.appending(path: "materials/particle", directoryHint: .isDirectory)
            for file in try FileManager.default.contentsOfDirectory(at: materials, includingPropertiesForKeys: nil)
            where file.pathExtension == "json" {
                let text = try String(contentsOf: file, encoding: .utf8)
                let changed = text.replacingOccurrences(of: #"("depthtest"\s*:\s*)"\w+""#, with: "$1\"\(depthTest)\"",
                                                        options: .regularExpression)
                try changed.write(to: file, atomically: true, encoding: .utf8)
            }
            let harness = try ModelSceneHarness(directory: directory, settings: SceneRenderSettings(), size: SIMD2(1920, 1080),
                                                storage: scratch.appending(path: "storage", directoryHint: .isDirectory))
            defer { harness.close() }
            try harness.settle(seconds: 3)
            var frames: [[UInt8]] = []
            var width = 0
            for frame in 1...150 {
                harness.frame()
                if frame >= 45, frame % 15 == 0 {
                    let texture = try XCTUnwrap(harness.renderer.sharedFrame)
                    width = texture.width
                    frames.append(try TextureUploadTests.read(texture, device: harness.device))
                }
            }
            ratios[depthTest] = try XCTUnwrap(Self.discDensityRatio(frames, width: width), depthTest)
            XCTAssertEqual(harness.gpuErrors, [], depthTest)
        }
        print("MG6 collisionmodel density ratios: \(ratios)")
        let enabled = try XCTUnwrap(ratios["enabled"]), disabled = try XCTUnwrap(ratios["disabled"])
        XCTAssertLessThan(enabled, 0.3, "WE: 0.13–0.28")
        XCTAssertGreaterThan(disabled, 0.8, "WE: 1.55")
        XCTAssertGreaterThan(disabled, 4 * enabled, "the depth test hides most of what is over the sphere")
    }

    private static let weAssets = "/Volumes/980Pro/Crossover/bottles/Steam Bottle/drive_c/Program Files (x86)/Steam/"
        + "steamapps/common/wallpaper_engine/assets"

    /// The orange pixels' density inside the sphere's disc over their density outside it, over
    /// `frames` (RGBA rows), as the capture measured it. The disc is the widest row of the pixels
    /// grey in at least half the frames (the particles pass over it; the frame may crop its top
    /// and bottom, not its sides).
    static func discDensityRatio(_ frames: [[UInt8]], width: Int) -> Double? {
        guard let first = frames.first, width > 0 else { return nil }
        let count = first.count / 4
        var greyFrames = [Int](repeating: 0, count: count)
        for bytes in frames {
            for pixel in 0..<count {
                let r = Int(bytes[pixel * 4]), g = Int(bytes[pixel * 4 + 1]), b = Int(bytes[pixel * 4 + 2])
                if abs(r - g) < 10, abs(g - b) < 10 { greyFrames[pixel] += 1 }
            }
        }
        var widest = (row: 0, first: 0, last: -1)
        for row in 0..<(count / width) {
            let columns = (0..<width).filter { greyFrames[row * width + $0] * 2 >= frames.count }
            guard let first = columns.first, let last = columns.last, last - first > widest.last - widest.first else { continue }
            widest = (row, first, last)
        }
        guard widest.last > widest.first else { return nil }
        let centre = SIMD2<Double>(Double(widest.first + widest.last) / 2, Double(widest.row))
        let radius: Double = Double(widest.last - widest.first) / 2 * 0.95
        var inside = 0.0, outside = 0.0, orangeInside = 0.0, orangeOutside = 0.0
        for bytes in frames {
            for pixel in 0..<count {
                let r = Int(bytes[pixel * 4]), g = Int(bytes[pixel * 4 + 1]), b = Int(bytes[pixel * 4 + 2])
                let orange = r > b + 25 && r > g + 25
                let point = SIMD2<Double>(Double(pixel % width), Double(pixel / width))
                if simd_distance(point, centre) < radius {
                    inside += 1
                    if orange { orangeInside += 1 }
                } else {
                    outside += 1
                    if orange { orangeOutside += 1 }
                }
            }
        }
        guard inside > 0, outside > 0, orangeOutside > 0 else { return nil }
        return (orangeInside / inside) / (orangeOutside / outside)
    }

    /// Degrees, y up, from the white pixels' centroid to the red ones' (RGBA rows); nil without both.
    static func armAngle(_ bytes: [UInt8], width: Int) -> Double? {
        var red = SIMD3<Double>(0, 0, 0), white = SIMD3<Double>(0, 0, 0)
        for pixel in 0..<(bytes.count / 4) {
            let r = bytes[pixel * 4], g = bytes[pixel * 4 + 1], b = bytes[pixel * 4 + 2]
            let point = SIMD3<Double>(Double(pixel % width), Double(pixel / width), 1)
            if r > 150, g < 60, b < 60 { red += point }
            if r > 235, g > 235, b > 235 { white += point }
        }
        guard red.z > 0, white.z > 0 else { return nil }
        let dx: Double = red.x / red.z - white.x / white.z
        let dy: Double = red.y / red.z - white.y / white.z
        return atan2(-dy, dx) * 180 / Double.pi
    }

    // MARK: - MG6: depth in an orthographic frame with models

    /// Two cubes overlapping on screen at different depths, in both draw orders: if WE's
    /// orthographic frame has depth when models are present, the nearer (red) cube covers the
    /// overlap in both; without depth, the one drawn last does.
    private func orthographicDepth(_ out: URL) throws -> [ModelFixtureWallpaper] {
        let cube = FixtureMDL.cube(material: "materials/gt_red.json", uv: true)
        func mdl(_ color: String) -> Data {
            FixtureMDL(format: FixtureMDL.positionNormal | FixtureMDL.uv, materialsPerMesh: 1, meshes: [FixtureMDL.Mesh(
                materials: ["materials/gt_\(color).json"], vertices: cube.vertices, indices: cube.indices)]).data
        }
        var files = Self.materials
        files["models/gt_red_cube.mdl"] = mdl("red")
        files["models/gt_green_cube.mdl"] = mdl("green")
        let near = #"{"id":1,"name":"near red","model":"models/gt_red_cube.mdl","origin":"900 540 -500","scale":"150 150 150"}"#
        let far = #"{"id":2,"name":"far green","model":"models/gt_green_cube.mdl","origin":"1020 540 -1500","scale":"150 150 150"}"#
        let general = #""clearcolor":"0 0 0","orthogonalprojection":{"width":1920,"height":1080}"#
        return [
            try ModelFixtureWallpaper(in: out, name: "gt-ortho-depth-near-first", objects: [near, far], general: general,
                                      eye: "960 540 0", center: "960 540 -1", files: files),
            try ModelFixtureWallpaper(in: out, name: "gt-ortho-depth-far-first", objects: [far, near], general: general,
                                      eye: "960 540 0", center: "960 540 -1", files: files),
        ]
    }

    // MARK: - MG4: root motion

    /// A box on one bone whose looping 1 s clip moves the bone by (1, 2, 3)·t and turns it by
    /// (0.3, 0.6, 0.9)·t rad, with one of the root-motion flags 0x800…0x10000 set (or none). The
    /// flagged clip is cut from the first as WE's model editor cuts one (Match loop, the clip
    /// record with the root bone; docs/test-risks.md MG4: without the record WE refuses the model).
    private func rootMotion(_ out: URL) throws -> [ModelFixtureWallpaper] {
        let box = FixtureMDL.cube(material: "materials/gt_red.json", bone: 0, size: SIMD3(1, 0.5, 0.25), uv: true)
        let frames: UInt32 = 30
        let track: [MDLBonePose] = (0...Int(frames)).map { frame in
            let t = Float(frame) / Float(frames)
            return MDLBonePose(position: SIMD3<Float>(1, 2, 3) * t, euler: SIMD3<Float>(0.3, 0.6, 0.9) * t, scale: SIMD3(repeating: 1))
        }
        var projects: [ModelFixtureWallpaper] = []
        for flag in [0, 0x800, 0x1000, 0x2000, 0x4000, 0x8000, 0x10000] as [UInt32] {
            var mdl = FixtureMDL(format: FixtureMDL.skinned | FixtureMDL.uv, materialsPerMesh: 1, meshes: [FixtureMDL.Mesh(
                materials: ["materials/gt_red.json"], vertices: box.vertices, indices: box.indices)], bones: 1)
            let cut = MDLAnimation.Reference(animation: 0, startFrame: 0, endFrame: frames, frameOffset: 0, rootBone: 0)
            mdl.clips = [FixtureMDL.Clip(id: 1, name: "source", frames: frames, tracks: [track]),
                         FixtureMDL.Clip(id: 2, name: "drift", frames: frames, flags: MDLAnimation.Flag.matchLoop | flag,
                                         tracks: [track], reference: flag == 0 ? nil : cut)]
            var files = Self.materials
            files["models/gt_rootmotion.mdl"] = mdl.data
            let object = #"{"id":1,"name":"box","model":"models/gt_rootmotion.mdl","origin":"0 0 0","#
                + #""animationlayers":[{"animation":2,"id":1,"name":"drift","rate":1,"blend":1,"visible":true}]}"#
            projects.append(try ModelFixtureWallpaper(in: out, name: String(format: "gt-rootmotion-0x%05x", flag), objects: [object],
                                                      eye: "0 3 15", center: "0 2 0", files: files))
        }
        return projects
    }

    // MARK: - MG3: additive layers

    /// A red arm (bone 1, along +y) on a white base (bone 0): a replacing layer turns the arm
    /// 90° about x (+y → +z), an additive layer 90° about z (+y → −x). Composed as
    /// `additive · base` the arm points along +z; as `base · additive` along −x, which is WE's.
    /// The second project weighs the additive layer 0.5.
    private func additive(_ out: URL) throws -> [ModelFixtureWallpaper] {
        let base = FixtureMDL.cube(material: "materials/gt_white.json", bone: 0, size: SIMD3(repeating: 0.6), uv: true)
        let arm = FixtureMDL.cube(material: "materials/gt_red.json", centre: SIMD3(0, 1.5, 0), bone: 1,
                                  size: SIMD3(0.3, 3, 0.3), uv: true)
        let frames: UInt32 = 30
        func constant(_ euler: SIMD3<Float>) -> [MDLBonePose] {
            Array(repeating: MDLBonePose(position: .zero, euler: euler, scale: SIMD3(repeating: 1)), count: Int(frames) + 1)
        }
        let still = constant(.zero)
        var mdl = FixtureMDL(format: FixtureMDL.skinned | FixtureMDL.uv, materialsPerMesh: 1, meshes: [
            FixtureMDL.Mesh(materials: ["materials/gt_white.json"], vertices: base.vertices, indices: base.indices),
            FixtureMDL.Mesh(materials: ["materials/gt_red.json"], vertices: arm.vertices, indices: arm.indices),
        ], bones: 2)
        mdl.clips = [
            FixtureMDL.Clip(id: 1, name: "base about x", frames: frames, tracks: [still, constant(SIMD3<Float>(Float.pi / 2, 0, 0))]),
            FixtureMDL.Clip(id: 2, name: "additive about z", frames: frames, tracks: [still, constant(SIMD3<Float>(0, 0, Float.pi / 2))]),
        ]
        var files = Self.materials
        files["models/gt_additive.mdl"] = mdl.data
        func object(additiveBlend: Double) -> String {
            #"{"id":1,"name":"rig","model":"models/gt_additive.mdl","origin":"0 0 0","animationlayers":["#
                + #"{"animation":1,"id":1,"name":"base","rate":1,"blend":1,"visible":true},"#
                + #"{"animation":2,"id":2,"name":"additive","rate":1,"blend":\#(additiveBlend),"visible":true,"additive":true}]}"#
        }
        return [
            try ModelFixtureWallpaper(in: out, name: "gt-additive-full", objects: [object(additiveBlend: 1)],
                                      eye: "6 4 10", center: "0 1 0", files: files),
            try ModelFixtureWallpaper(in: out, name: "gt-additive-half", objects: [object(additiveBlend: 0.5)],
                                      eye: "6 4 10", center: "0 1 0", files: files),
        ]
    }
}
