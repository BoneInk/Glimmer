import JavaScriptCore
import XCTest
import simd
@testable import OpenWallpaperEngine

private struct NoProperties: SceneValueContext {
    func userProperty(_ name: String) -> String? { nil }
}

/// docs/models-plan.md M3 against the library: in every orthographic scene the orthographic view
/// of each object's 3D world matrix equals today's 2D `SceneAffineTransform` (so the two paths
/// agree, tilted objects included), and 3734636606's camera-sync script agrees with WE's rows.
/// Roots: the Workshop folder, OpenWallpaperStorage and WE's default projects, or `OWE_LIBRARY`
/// (paths separated by ':'); skipped when none is present (CI).
final class SceneTransform3DLibraryTests: XCTestCase {
    private static let weRoot = "/Volumes/980Pro/Crossover/bottles/Steam Bottle/drive_c/Program Files (x86)/Steam/steamapps"

    static var roots: [URL] {
        let paths = ProcessInfo.processInfo.environment["OWE_LIBRARY"].map { $0.split(separator: ":").map(String.init) }
            ?? ["\(weRoot)/workshop/content/431960", "/Volumes/980Pro/OpenWallpaperStorage",
                "\(weRoot)/common/wallpaper_engine/projects/defaultprojects"]
        return paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private struct Scene {
        var key: String
        var directory: URL
        var data: Data
    }

    /// Every scene item once (by Workshop id, the first root first).
    private func scenes() throws -> [Scene] {
        let roots = Self.roots
        try XCTSkipIf(roots.isEmpty, "wallpaper library not present")
        var seen = Set<String>()
        var scenes: [Scene] = []
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
                guard let data = Self.read(file, in: directory) else {
                    XCTFail("\(name): no \(file)")
                    continue
                }
                scenes.append(Scene(key: name, directory: directory, data: data))
            }
        }
        return scenes
    }

    /// The ortho projection of the 3D matrix equals the 2D path for every object of every
    /// orthographic scene, the tilted ones (`angles.x`/`.y`) counted: 8 in the survey
    /// (2734461061, 3000562427, 3019043758, 3352730400, 3384390033, shimmering_particles ×3),
    /// none under a tilted parent. Both put a root without an `origin` at 0 (§5.13).
    func testOrthographicViewOfTheWorldMatrixEqualsThe2DPath() throws {
        var checked = 0
        var tilted: [String] = []
        var lines: [String] = []
        for scene in try scenes() {
            var decoded = try decodeTolerant(WEScene.self, from: scene.data)
            guard !decoded.general.projection.isPerspective else { continue }
            decoded.objects = SceneObjectIdentity.assigningFallbackIDs(decoded.objects)
            let flat = SceneTransformHierarchy(objects: decoded.objects)
            let deep = SceneTransformHierarchy3D(objects: decoded.objects)
            for (index, object) in decoded.objects.enumerated() {
                let id = String(object.id ?? index)
                let chain = [id] + deep.ancestors(of: id)
                let isTilted = chain.contains { deep.nodes[$0].map { $0.local.angles.x != 0 || $0.local.angles.y != 0 } ?? false }
                if isTilted { tilted.append("\(scene.key)/\(id)") }
                let expected = flat.world(of: id)
                let projected = SceneWorldMatrix.orthographic(deep.world(of: id))
                // Relative for the translation: origins run to thousands of pixels.
                let error = max(simd_length(projected.translation - expected.translation)
                                    / max(1, simd_length(expected.translation)),
                                simd_length(projected.linear.columns.0 - expected.linear.columns.0),
                                simd_length(projected.linear.columns.1 - expected.linear.columns.1))
                if error > 1e-4 {
                    XCTFail("\(scene.key) object \(id) (\(object.name ?? "")): 3D \(projected) vs 2D \(expected)")
                }
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 0)
        XCTAssertFalse(tilted.isEmpty, "no tilted object in the library's orthographic scenes")
        lines.append("\(checked) objects in orthographic scenes; \(tilted.count) tilted or under a tilt: "
                     + tilted.joined(separator: ", "))
        LibraryReport.attach("3D transforms in orthographic scenes", lines)
    }

    /// 3734636606's community script copies its camera layer's transform into the scene camera:
    /// `angles` (degrees at the API) → R = Rz·Ry·Rx, centre = eye + R·(0, 0, −1), up = R·(0, 1, 0).
    /// Run as written through JavaScriptCore, its forward is −row2 and its up row1 of WE's rows,
    /// for random angles; and the layer's authored angles (radians) look from its origin at the
    /// scene's middle.
    func testCameraSyncScriptsForwardIsMinusRow2() throws {
        // `scenes()` throws XCTSkip without the library; inside XCTUnwrap that would be a failure.
        let found = try scenes().first { $0.key == "3734636606" }
        guard let scene = found else { throw XCTSkip("3734636606 not in the library") }
        let root = try JSONSerialization.jsonObject(with: scene.data) as? [String: Any] ?? [:]
        let objects = root["objects"] as? [[String: Any]] ?? []
        let layer = try XCTUnwrap(objects.first { $0["camera"] is String }, "no camera layer")
        let angles = try XCTUnwrap(layer["angles"] as? [String: Any], "the layer's angles aren't scripted")
        let source = try XCTUnwrap(angles["script"] as? String)
        XCTAssertTrue(source.contains("setCameraTransforms"))

        let context = try XCTUnwrap(JSContext())
        context.exceptionHandler = { _, exception in XCTFail("script: \(exception?.toString() ?? "?")") }
        context.evaluateScript("""
        class Vec3 { constructor(x, y, z) { this.x = x; this.y = y; this.z = z; } }
        var captured = null;
        var thisScene = { fov: 50, setCameraTransforms(t) { captured = t; } };
        var thisLayer = { visible: true };
        """)
        context.evaluateScript(source.replacingOccurrences(of: "export function", with: "function"))
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let degrees = SIMD3<Float>(Float.random(in: -180...180, using: &generator),
                                       Float.random(in: -180...180, using: &generator),
                                       Float.random(in: -180...180, using: &generator))
            context.evaluateScript("""
            syncCameraToLayer({ origin: { x: 1, y: 2, z: 3 }, angles: { x: \(degrees.x), y: \(degrees.y), z: \(degrees.z) } });
            """)
            func vector(_ name: String) throws -> SIMD3<Float> {
                let value = try XCTUnwrap(context.objectForKeyedSubscript("captured")?.objectForKeyedSubscript(name))
                return SIMD3(Float(value.objectForKeyedSubscript("x").toDouble()),
                             Float(value.objectForKeyedSubscript("y").toDouble()),
                             Float(value.objectForKeyedSubscript("z").toDouble()))
            }
            let (_, row1, row2) = SceneWorldMatrix.rows(degrees * .pi / 180)
            let forward = try vector("center") - vector("eye")
            XCTAssertLessThan(simd_length(forward - -row2), 1e-4, "forward at \(degrees)°")
            XCTAssertLessThan(simd_length(try vector("up") - row1), 1e-4, "up at \(degrees)°")
        }

        let authored = SceneLocalTransform3D(origin: Self.vector(layer["origin"]), scale: SIMD3(repeating: 1),
                                             angles: Self.vector(angles["value"]))
        let forward = SceneWorldMatrix.forward(authored.matrix)
        let toMiddle = simd_normalize(-authored.origin)
        XCTAssertGreaterThan(simd_dot(forward, toMiddle), cos(10 * Float.pi / 180),
                             "the camera at \(authored.origin) looks along \(forward)")
    }

    private static func vector(_ value: Any?) -> SIMD3<Float> {
        let numbers = (value as? String ?? "").split(separator: " ").compactMap { Float($0) }
        return SIMD3(numbers.count > 0 ? numbers[0] : 0, numbers.count > 1 ? numbers[1] : 0,
                     numbers.count > 2 ? numbers[2] : 0)
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
