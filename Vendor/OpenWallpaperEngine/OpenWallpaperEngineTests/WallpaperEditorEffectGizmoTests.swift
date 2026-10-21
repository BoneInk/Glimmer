import XCTest
import OWESceneEditing
@testable import OpenWallpaperEngine

/// The Wallpaper Editor's effect gizmos as WE's own effects declare them: `effect.json`'s
/// `gizmos` and the shaders' `"position": true` and `"direction": true` constants reach the
/// schema the inspector and the canvas read.
@MainActor
final class WallpaperEditorEffectGizmoTests: XCTestCase {
    private func resources() throws -> EditorWallpaperResources {
        let directory = FileManager.default.temporaryDirectory.appending(path: "owe-gizmos-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"file": "scene.json", "type": "scene", "title": "Gizmos"}"#.utf8).write(to: directory.appending(path: "project.json"))
        try Data(#"{"general": {"orthogonalprojection": {"width": 100, "height": 100}}, "objects": []}"#.utf8)
            .write(to: directory.appending(path: "scene.json"))
        let identity = WallpaperSettingsIdentity.resolve(directory: directory)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory) // Cleanup: the scratch wallpaper.
            try? FileManager.default.removeItem(at: SceneEditOverlayFiles.defaultStore.assetsDirectory(for: identity.rawValue))
        }
        let project = try JSONDecoder().decode(WEProject.self, from: Data(contentsOf: directory.appending(path: "project.json")))
        return try EditorWallpaperResources(wallpaper: WEWallpaper(using: project, where: directory), package: nil,
                                            assets: SceneEditOverlayFiles.assets(for: identity))
    }

    func testSpinsGizmoAndItsCentreAsAPosition() throws {
        let assets = try Fixtures.assets()
        try XCTSkipUnless(FileManager.default.fileExists(atPath: assets.appending(path: "effects/spin/effect.json").path),
                          "WE's Spin effect isn't in the assets")
        let schema = try XCTUnwrap(try resources().effectSchema("effects/spin/effect.json"))
        XCTAssertEqual(schema.gizmos.map(\.kind), [.spinUV])
        XCTAssertEqual(schema.gizmos.first?.vars, ["center": "center", "ratio": "ratio", "angle": "angle", "size": "size"])
        XCTAssertEqual(schema.parameter("center")?.control, .position)
        XCTAssertEqual(schema.parameter("center")?.defaultValue, [0.5, 0.5])
    }

    func testFluidSimulationsEmittersAndTheirDirections() throws {
        let assets = try Fixtures.assets()
        try XCTSkipUnless(FileManager.default.fileExists(atPath: assets.appending(path: "effects/fluidsimulation/effect.json").path),
                          "WE's Advanced Fluid Simulation isn't in the assets")
        let schema = try XCTUnwrap(try resources().effectSchema("effects/fluidsimulation/effect.json"))
        XCTAssertEqual(schema.gizmos.map(\.kind), [.pointEmitter, .pointEmitter, .pointEmitter, .pointEmitter,
                                                  .lineEmitter, .lineEmitter, .lineEmitter, .perspectiveUV],
                       "read through WE's trailing commas")
        XCTAssertEqual(schema.gizmos[3].conditions, [EffectGizmo.Condition(combo: "POINTEMITTER", op: "ge", value: 4)])
        let angle = try XCTUnwrap(schema.parameter("emitterAngle0"))
        XCTAssertEqual(angle.control, .direction)
        XCTAssertTrue(angle.showsDegrees, "`conversion: rad2deg`")
    }
}
