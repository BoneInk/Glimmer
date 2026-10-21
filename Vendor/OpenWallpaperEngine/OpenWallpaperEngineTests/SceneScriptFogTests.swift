import XCTest
import simd
@testable import OpenWallpaperEngine

/// Scripts move the scene's fog (docs/lighting-plan.md §2.9): WE registers every `general.fog*`
/// field in the scene's property table with the fog's writer (0x140186440) as its change handler
/// (0x14019a312…), and scenescript64.dll reads `thisScene` members by name through that table.
final class SceneScriptFogTests: XCTestCase {
    private var storage: URL!

    override func setUpWithError() throws {
        storage = FileManager.default.temporaryDirectory.appending(path: "owe-script-fog-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let storage, FileManager.default.fileExists(atPath: storage.path) {
            try FileManager.default.removeItem(at: storage)
        }
    }

    /// `thisScene.fog…` start at the authored values (WE's defaults for the rest), and a script's
    /// writes come back as the scene's settings.
    func testScriptsReadAndWriteTheFog() throws {
        _ = try Fixtures.assets()
        let script = """
            export function update(value) {
                shared.read = [thisScene.fogdistance, thisScene.fogdistancestart, thisScene.fogdistanceend,
                               thisScene.fogheightend, thisScene.fogdistancecolor.x].join();
                thisScene.fogdistancestart = 7;
                thisScene.fogheightenddensity = 0.25;
                thisScene.fogheight = true;
                thisScene.fogheightcolor = new Vec3(0, 0.5, 1);
                return value;
            }
            """
        let data = try JSONSerialization.data(withJSONObject: [script])
        let quoted = String(decoding: data, as: UTF8.self).dropFirst().dropLast()
        let text = #"""
            {"general": {"orthogonalprojection": {"width": 200, "height": 100}, "fogdistance": true,
                         "fogdistancestart": 2, "fogdistancecolor": "0.5 0.5 0.5"},
             "objects": [{"id": 1, "name": "Object", "image": "models/a.json", "alpha": {"script": \#(quoted), "value": 1}}]}
            """#
        let document = try SceneScriptSiteBuilder.document(from: Data(text.utf8))
        let content = SceneScriptSceneContent(wallpaperID: "fog-\(UUID().uuidString.prefix(8))", document: document,
                                              documentSignature: "1", project: nil, userValues: { [:] },
                                              file: { _ in nil }, makeLayer: { _ in nil })
        let services = SceneScriptServices(prelude: SceneScriptPrelude.load(), storage: SceneScriptStorage(directory: storage),
                                           media: SceneScriptReplayMediaSource(), spectrum: { .silent })
        let wallpaper = try XCTUnwrap(try SceneScriptWallpaper(content: content, services: services, screenID: "test"))
        addTeardownBlock { wallpaper.tearDown(); wallpaper.waitUntilIdle() }
        var input = SceneScriptFrameInput()
        input.deltaTime = 1.0 / 60
        wallpaper.submit(input)
        wallpaper.waitUntilIdle()
        let state = try XCTUnwrap(wallpaper.take().state)
        let read = wallpaper.thread.sync { wallpaper.scriptRuntime?.context.evaluateScript("shared.read")?.toString() }
        XCTAssertEqual(read, "true,2,5,-3,0.5", "authored values, else WE's defaults (distance end 5, height end −3)")
        XCTAssertEqual(state.scene.scalar(.fogdistancestart), 7)
        XCTAssertEqual(state.scene.scalar(.fogheightenddensity), 0.25)
        XCTAssertEqual(state.scene.flag(.fogheight), true)
        XCTAssertEqual(state.scene.vector3(.fogheightcolor), SIMD3<Float>(0, 0.5, 1))
        XCTAssertNil(state.scene.scalar(.fogdistanceend), "untouched fields stay the scene's")
    }

    /// The frame's fog takes the scripts' values over the authored ones, and `g_Fog*Params`
    /// follow (start, end − start, start density, end density − start density).
    func testTheFrameFogTakesTheScriptsValues() {
        var authored = SceneFogSettings()
        authored.distance = true
        authored.distanceStart = 2
        let scripted: [SceneScriptSceneField: Float] = [.fogdistancestart: 7, .fogdistanceenddensity: 0.5, .fogheight: 1]
        let fog = authored.live(number: { scripted[$0] }, color: { $0 == .fogdistancecolor ? SIMD3(1, 0, 0) : nil })
        XCTAssertEqual(fog.distanceParams, SIMD4<Float>(7, SceneFogDefaults.distanceEnd - 7, 0, 0.5))
        XCTAssertEqual(fog.distanceColor, SIMD3<Float>(1, 0, 0))
        XCTAssertEqual(fog.heightColor, SceneFogDefaults.color)
        XCTAssertTrue(fog.distance)
        XCTAssertTrue(fog.height)
        XCTAssertEqual(authored.live(number: { _ in nil }, color: { _ in nil }), authored, "nothing scripted keeps the scene's")
    }
}
