import XCTest
import CryptoKit
@testable import OpenWallpaperEngine

final class SceneCacheFileTests: XCTestCase {
    private func baseKey() -> SceneCacheKey {
        SceneCacheKey(sources: [.init(path: "/scene.pkg", size: 100, modified: 5)],
                      edits: ["_owe_scene_object_1_origin": "1 2 3"],
                      userProperties: ["speed": "1"],
                      displays: [.init(pixelWidth: 3840, pixelHeight: 2160, scale: 2)],
                      settings: "hdr", environment: "os1", shaderRevision: 10, gpu: "gpu|apple9")
    }

    // MARK: - Key

    func testKeyChangesWithEveryInput() {
        let base = baseKey()
        var variants: [(String, SceneCacheKey)] = []
        var key = base; key.sources[0].size = 101; variants.append(("size", key))
        key = base; key.sources[0].modified = 6; variants.append(("mtime", key))
        key = base; key.sources.append(.init(path: "/x", size: 1, modified: 1)); variants.append(("file", key))
        key = base; key.edits["_owe_scene_object_1_origin"] = "1 2 4"; variants.append(("edit", key))
        key = base; key.userProperties["speed"] = "2"; variants.append(("property", key))
        key = base; key.displays[0].scale = 1; variants.append(("scale", key))
        key = base; key.displays[0].pixelWidth = 2560; variants.append(("display", key))
        key = base; key.settings = "sdr"; variants.append(("settings", key))
        key = base; key.environment = "os2"; variants.append(("environment", key))
        key = base; key.shaderRevision = 11; variants.append(("revision", key))
        key = base; key.gpu = "gpu|apple8"; variants.append(("gpu", key))
        let baseName: String = base.name
        for (label, variant) in variants {
            let name: String = variant.name
            XCTAssertNotEqual(name, baseName, label)
        }
        let again: String = baseKey().name
        XCTAssertEqual(again, baseName)
    }

    func testKeyIgnoresDictionaryAndDisplayOrder() {
        var a = baseKey()
        a.userProperties = ["a": "1", "b": "2", "c": "3"]
        a.displays = [.init(pixelWidth: 1, pixelHeight: 1, scale: 1), .init(pixelWidth: 2, pixelHeight: 2, scale: 2)]
        var b = a
        b.displays.reverse()
        let nameA: String = a.name
        let nameB: String = b.name
        XCTAssertEqual(nameA, nameB)
    }

    // MARK: - Edits

    func testEditsAreAppliedToThePlan() throws {
        let data = Data("{\"objects\":[{\"id\":4,\"origin\":\"0 0 0\"}]}".utf8)
        let resolved = try ScenePreparation.resolvedScene(data, edits: ["_owe_scene_object_4_origin": "5 6 0"])
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: resolved) as? [String: Any])
        let objects = try XCTUnwrap(root["objects"] as? [[String: Any]])
        XCTAssertEqual(objects.first?["origin"] as? String, "5 6 0")
    }
}
