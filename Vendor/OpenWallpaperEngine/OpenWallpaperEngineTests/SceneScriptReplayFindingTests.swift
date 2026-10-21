import JavaScriptCore
import XCTest
@testable import OpenWallpaperEngine

/// The object-model bugs the corpus replay found (scenescript-replay-findings notes): RF1, asset
/// paths under the script's Workshop item, and RF2, strings flushed although unchanged.
final class SceneScriptReplayFindingTests: XCTestCase {
    private func objectFixture(_ objects: [SceneScriptObjectDescription]) throws -> (FakeSceneScriptObjectHost, SceneScriptRuntime) {
        let host = FakeSceneScriptObjectHost(scene: SceneScriptSceneDescription(objects: objects)) { source in
            .make(.image, id: 100, name: "\(source)")
        }
        let runtime = try SceneScriptRuntime(host: TestSceneScriptHost(), compiler: SceneScriptModuleTransformer(),
                                             extensions: [SceneScriptObjectModel(host: host)])
        return (host, runtime)
    }

    // MARK: - RF1

    func testCreateLayerCarriesTheScriptsWorkshopID() throws {
        let (host, runtime) = try objectFixture([.make(.image, id: 1, name: "Bar")])
        runtime.add(SceneScriptInstance(id: "with", source: """
            'use strict';
            const handle = engine.registerAsset('models/handle.json');
            export let __workshopId = '2935714170';
            export function init() {
                thisScene.createLayer('models/bar.json');
                thisScene.createLayer(handle);
            }
            """, objectSlot: 0))
        runtime.add(SceneScriptInstance(id: "without", source: """
            export function init() { thisScene.createLayer('models/bar.json'); }
            """, objectSlot: 0))
        runtime.load()
        XCTAssertEqual(host.described, [
            .asset("models/bar.json", workshopID: "2935714170"),
            .asset("models/handle.json", workshopID: "2935714170"),
            .asset("models/bar.json", workshopID: nil),
        ])
    }

    func testAssetPathsTryTheWorkshopItemFirst() {
        XCTAssertEqual(SceneScriptLayerSource.assetPaths("models/bar.json", workshopID: "2935714170"),
                       ["models/workshop/2935714170/bar.json", "models/bar.json"])
        XCTAssertEqual(SceneScriptLayerSource.assetPaths("models/bar.json", workshopID: nil), ["models/bar.json"])
        XCTAssertEqual(SceneScriptLayerSource.assetPaths("bar.json", workshopID: "1"), ["bar.json"])
    }

    // MARK: - RF2

    func testUnchangedStringsAreNotFlushedAgain() throws {
        let (host, runtime) = try objectFixture([.make(.text, id: 1, name: "Clock", strings: [.text: "start"])])
        runtime.add(SceneScriptInstance(id: "s", source: """
            let frame = 0;
            export function update() {
                frame++;
                thisLayer.text = frame < 3 ? 'start' : 'hello';
                if (frame === 5) { thisLayer.text = 'other'; thisLayer.text = 'hello'; }
                if (frame === 6) thisLayer.name = 'Clock';
            }
            """, objectSlot: 0))
        runtime.load()
        for _ in 0..<600 { runtime.frame(deltaTime: 1.0 / 60) }
        XCTAssertEqual(host.takeCommands(), [.setString(slot: 0, field: .text, value: "hello")],
                       "the initial text, a repeated text, A → B → A in one frame and the same name send nothing")
    }

    func testABoundTextReturningAConstantIsFlushedOnce() throws {
        let f = try SceneScriptBindingFixture(objects: [.make(.text, id: 2, name: "Clock", strings: [.text: "<Clock>"])])
        try f.load("""
            {"objects": [{"id": 2, "name": "Clock", "text": {"script": "export function update(value) { return '12:00'; }", "value": "<Clock>"}}]}
            """)
        f.frames(600)
        XCTAssertEqual(f.objectHost.takeCommands(), [.setString(slot: 0, field: .text, value: "12:00")])
    }
}
