import XCTest
@testable import OpenWallpaperEngine

/// The 3D survey of docs/models-plan.md §2 rerun through the app's decoder: every scene of the
/// Workshop folder, OpenWallpaperStorage and WE's default projects (de-duplicated by Workshop id,
/// the Workshop copy first; `project.json` type "scene" only), its files read loose or from its
/// `.pkg`. Per scene, the decoded model objects, camera layers, `camera.paths` and projection
/// equal what the JSON authors under WE's rules, and every camera-path file decodes. The survey's
/// counts (254 model objects in 16 scenes, 15 camera layers in 7, 7 scenes with camera paths, 14
/// perspective scenes) are checked when every survey scene is present. Skipped when the library
/// is absent (CI).
final class SpatialLibraryDecodeTests: XCTestCase {
    private static let weRoot = "/Volumes/980Pro/Crossover/bottles/Steam Bottle/drive_c/Program Files (x86)/Steam/steamapps"
    private static let roots = [URL(fileURLWithPath: "\(weRoot)/workshop/content/431960"),
                                URL(fileURLWithPath: "/Volumes/980Pro/OpenWallpaperStorage"),
                                URL(fileURLWithPath: "\(weRoot)/common/wallpaper_engine/projects/defaultprojects")]

    /// The survey's model objects per scene (`dd-models/model_objects.json`).
    private static let surveyModels: [String: Int] = [
        "2350874185": 2, "3159348391": 26, "3233200129": 1, "3378346807": 100, "3384390033": 3, "3453730450": 5,
        "3455121165": 20, "3657770939": 30, "3734636606": 46, "arsenal": 1, "demon_core": 2, "dna_fragment": 5,
        "fantasticcar": 4, "neon_sunset": 2, "retro": 1, "ricepod": 6,
    ]
    /// The survey's camera layers per scene (`dd-models/camera_layers.json`).
    private static let surveyCameraLayers: [String: Int] = [
        "3159348391": 8, "3233200129": 1, "3378346807": 1, "3453730450": 2, "3455121165": 1, "3657770939": 1,
        "3734636606": 1,
    ]
    private static let surveyPathScenes: Set = ["2350874185", "arsenal", "demon_core", "dna_fragment", "fantasticcar",
                                                "neon_sunset", "ricepod"]
    private static let surveyPerspective: Set = ["2350874185", "3159348391", "3233200129", "3378346807", "3453730450",
                                                 "3455121165", "3657770939", "3734636606", "neon_sunset", "ricepod",
                                                 "arsenal", "demon_core", "dna_fragment", "fantasticcar"]

    private struct Tally {
        var models: [String: Int] = [:]
        var cameraLayers: [String: Int] = [:]
        var pathScenes = Set<String>()
        var perspective = Set<String>()
        var layerPaths = 0
        var scenePaths = 0
    }

    func testTheLibrarys3DFieldsDecode() throws {
        let roots = Self.roots.filter { FileManager.default.fileExists(atPath: $0.path) }
        try XCTSkipIf(roots.count < Self.roots.count, "wallpaper library not present")
        var seen = Set<String>()
        var tally = Tally()
        for root in roots {
            for name in try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() {
                let directory = root.appending(path: name, directoryHint: .isDirectory)
                guard let project = Self.project(in: directory) else { continue }
                let workshopID = project["workshopid"].map { "\($0)" } ?? ""
                let key = workshopID.isEmpty || workshopID == "0" ? name : workshopID
                guard !seen.contains(key), !seen.contains(name) else { continue }
                seen.formUnion([key, name])
                guard (project["type"] as? String)?.lowercased() == "scene" else { continue }
                let file = project["file"] as? String ?? "scene.json"
                let data = try XCTUnwrap(Self.read(file, in: directory), "\(name): no \(file)")
                // The survey names an item by its folder (3734636606's project says 3734635534).
                do {
                    try check(name, data: data, directory: directory, tally: &tally)
                } catch {
                    XCTFail("\(name): \(error)")
                }
            }
        }
        let expected = Set(Self.surveyModels.keys).union(Self.surveyCameraLayers.keys).union(Self.surveyPathScenes)
            .union(Self.surveyPerspective)
        let missing = expected.subtracting(seen).sorted()
        XCTAssertGreaterThan(seen.count, 0)
        if missing.isEmpty {
            XCTAssertEqual(tally.models, Self.surveyModels)
            XCTAssertEqual(tally.models.values.reduce(0, +), 254)
            XCTAssertEqual(tally.cameraLayers, Self.surveyCameraLayers)
            XCTAssertEqual(tally.cameraLayers.values.reduce(0, +), 15)
            XCTAssertEqual(tally.pathScenes, Self.surveyPathScenes)
            XCTAssertEqual(tally.perspective, Self.surveyPerspective)
        }
        var lines = ["\(tally.models.values.reduce(0, +)) model objects in \(tally.models.count) scenes; "
                     + "\(tally.cameraLayers.values.reduce(0, +)) camera layers in \(tally.cameraLayers.count) scenes "
                     + "(\(tally.layerPaths) paths); \(tally.pathScenes.count) scenes with camera paths "
                     + "(\(tally.scenePaths) paths); \(tally.perspective.count) perspective scenes"]
        if !missing.isEmpty { lines.append("survey scenes not in the library, totals not checked: \(missing.joined(separator: ", "))") }
        LibraryReport.attach("3D library survey", lines)
    }

    private func check(_ key: String, data: Data, directory: URL, tally: inout Tally) throws {
        let failures = DecodeFailureLog()
        let scene = try decodeTolerant(WEScene.self, from: data, failures: failures)
        let root = try Self.json(data)
        let objects = root["objects"] as? [[String: Any]] ?? []
        // WE's dispatcher: `model` as a string, number or object; else `camera` as a string.
        let authoredModels = objects.filter { Self.makesModel($0["model"]) }.count
        let authoredCameras = objects.filter { !Self.makesModel($0["model"]) && $0["camera"] is String }.count
        let decodedModels = scene.objects.filter { $0.model != nil }.count
        let decodedCameras = scene.objects.filter { $0.model == nil && $0.cameraLayer != nil }.count
        XCTAssertEqual(decodedModels, authoredModels, "\(key): model objects")
        XCTAssertEqual(decodedCameras, authoredCameras, "\(key): camera layers")
        if decodedModels > 0 { tally.models[key] = decodedModels }
        if decodedCameras > 0 { tally.cameraLayers[key] = decodedCameras }
        let general = root["general"] as? [String: Any] ?? [:]
        let authoredPerspective = Self.isPerspective(general["orthogonalprojection"])
        XCTAssertEqual(scene.general.projection.isPerspective, authoredPerspective, "\(key): projection")
        if authoredPerspective { tally.perspective.insert(key) }
        let modelMessages = failures.messages.filter { $0.contains("animationlayers") || $0.contains("dependencies") }
        XCTAssertEqual(modelMessages, [], "\(key): model fields that didn't decode")

        let paths = scene.camera.paths ?? []
        XCTAssertEqual(paths.count, ((root["camera"] as? [String: Any])?["paths"] as? [Any])?.count ?? 0, "\(key): camera.paths")
        if !paths.isEmpty { tally.pathScenes.insert(key) }
        for path in paths {
            let data = try XCTUnwrap(Self.read(path, in: directory), "\(key): \(path)")
            let file = try WESceneCameraPathFile(data: data)
            XCTAssertFalse(file.paths.isEmpty, "\(key): \(path) has no path WE plays")
            tally.scenePaths += file.paths.count
        }
        for layer in scene.objects.compactMap(\.cameraLayer) {
            guard let path = layer.path else { continue }
            let data = try XCTUnwrap(Self.read(path, in: directory), "\(key): \(path)")
            let pathFailures = DecodeFailureLog()
            let file = try WECameraLayerPathFile(data: data, failures: pathFailures)
            XCTAssertEqual(pathFailures.messages, [], "\(key): \(path)")
            tally.layerPaths += file.paths.count
        }
    }

    private static func makesModel(_ value: Any?) -> Bool {
        guard let value, !(value is NSNull) else { return false }
        if let number = value as? NSNumber { return CFGetTypeID(number) != CFBooleanGetTypeID() }
        return value is String || value is [String: Any]
    }

    /// §2.1 on the raw JSON: an object with a true `auto`, or two numeric sizes both non-zero, is
    /// orthographic; everything else is perspective.
    private static func isPerspective(_ value: Any?) -> Bool {
        guard let object = value as? [String: Any] else { return true }
        if let auto = object["auto"] as? NSNumber, CFGetTypeID(auto) == CFBooleanGetTypeID(), auto.boolValue { return false }
        guard let width = object["width"] as? NSNumber, let height = object["height"] as? NSNumber,
              CFGetTypeID(width) != CFBooleanGetTypeID(), CFGetTypeID(height) != CFBooleanGetTypeID() else { return true }
        return width.intValue == 0 || height.intValue == 0
    }

    private static func json(_ data: Data) throws -> [String: Any] {
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        return try JSONSerialization.jsonObject(with: Data(bytes), options: [.json5Allowed]) as? [String: Any] ?? [:]
    }

    /// `project.json`; nil for a folder without one. `try?`: an unreadable one isn't a wallpaper.
    private static func project(in directory: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: directory.appending(path: "project.json")) else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.json5Allowed])) as? [String: Any]
    }

    /// A loose file wins over the same path inside a `.pkg`, as WE reads a wallpaper.
    private static func read(_ file: String, in directory: URL) -> Data? {
        if let loose = FileManager.default.contents(atPath: directory.appending(path: file).path) { return loose }
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "pkg" else { continue }
            do {
                if let data = try PKGParser(url: url).extractFile(named: file) { return data }
            } catch {
                XCTFail("\(url.path): \(error)")
            }
        }
        return nil
    }
}
