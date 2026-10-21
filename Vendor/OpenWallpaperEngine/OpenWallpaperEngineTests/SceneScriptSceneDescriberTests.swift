import XCTest
@testable import OpenWallpaperEngine

/// The object model's view of a scene document (`SceneScriptSceneDescriber`, WP11).
final class SceneScriptSceneDescriberTests: XCTestCase {
    private func document(_ text: String) throws -> SceneJSON {
        try SceneScriptSiteBuilder.document(from: Data(text.utf8))
    }

    private func describer(properties: String = "{}", files: [String: String] = [:]) throws -> SceneScriptSceneDescriber {
        let project = try document(#"{"general": {"properties": \#(properties)}}"#)
        return SceneScriptSceneDescriber(userProperties: SceneScriptUserProperties(project: project),
                                         file: { files[$0].map { Data($0.utf8) } })
    }

    /// scene.json writes angles in radians, the table's unit; user-bound values take the user's
    /// value, a `{"name", "condition"}` binding a flag.
    func testValuesAreUserResolvedInTableUnits() throws {
        let scene = try describer(properties: #"{"size": {"type": "slider", "value": 3}, "mode": {"type": "combo", "value": 2}}"#)
            .scene(try document(#"""
            {"general": {"bloomstrength": {"user": "size", "value": 1}},
             "objects": [{"id": 7, "name": "A", "image": "models/a.json", "parent": 3,
                          "angles": "0 0 1.5707963", "scale": {"user": "size", "value": "1 1 1"},
                          "visible": {"user": {"name": "mode", "condition": "1"}, "value": true},
                          "effects": [{"file": "effects/tint/effect.json", "visible": false,
                                       "passes": [{"constantshadervalues": {"color": "0 0 1", "alpha": {"user": "size", "value": 1}}}]}]},
                         {"name": "B", "text": {"value": "hi", "script": "export function update(v) { return v; }"}}]}
            """#))
        let a = scene.objects[0]
        XCTAssertEqual(a.id, 7)
        XCTAssertEqual(a.parentID, 3)
        XCTAssertEqual(a.kind, .image)
        XCTAssertEqual(a.values[.angles], [0, 0, 1.5707963])
        XCTAssertEqual(a.values[.scale], [3, 3, 3], "one number fills a vector, as WE's converter reads it")
        XCTAssertEqual(a.values[.visible], [0], "mode is 2, the condition 1")
        XCTAssertEqual(a.effects.first?.visible, false)
        XCTAssertEqual(a.effects.first?.name, "tint")
        XCTAssertEqual(a.effects.first?.materials.first?.constants.map(\.name), ["alpha", "color"])
        XCTAssertEqual(a.effects.first?.materials.first?.constants.first?.value, [3])
        let b = scene.objects[1]
        XCTAssertEqual(b.id, 1, "an object without an id is known by its index")
        XCTAssertEqual(b.kind, .text)
        XCTAssertEqual(b.strings[.text], "hi")
        XCTAssertEqual(scene.settings[.bloomstrength], [3])
    }

    /// `createLayer(path)`: the path under the script's Workshop item first (RF1), a model becomes
    /// an image object showing it, a particle definition a particle system; nothing when missing.
    func testCreatedLayersFromAssetsAndConfigurations() throws {
        let files = ["models/workshop/42/bar.json": #"{"material": "materials/bar.json"}"#,
                     "particles/sparks.json": #"{"emitter": [], "renderer": []}"#]
        let describer = try describer(files: files)
        let bar = try XCTUnwrap(describer.layer(.asset("models/bar.json", workshopID: "42"), id: 9, copying: nil))
        XCTAssertEqual(bar.json["image"], .string("models/workshop/42/bar.json"))
        XCTAssertEqual(bar.json["id"], .number(9))
        XCTAssertEqual(bar.description.kind, .image)
        let sparks = try XCTUnwrap(describer.layer(.asset("particles/sparks.json"), id: 10, copying: nil))
        XCTAssertEqual(sparks.description.kind, .particle)
        XCTAssertNil(describer.layer(.asset("models/missing.json"), id: 11, copying: nil))

        let configured = try XCTUnwrap(describer.layer(.configuration(json: #"{"image": "models/x.json", "origin": "1 2 3"}"#),
                                                       id: 12, copying: nil))
        XCTAssertEqual(configured.description.values[.origin], [1, 2, 3])
        let copy = try XCTUnwrap(describer.layer(.copy(slot: 0), id: 13, copying: ["name": .string("Source"), "id": .number(1)]))
        XCTAssertEqual(copy.description.name, "Source")
        XCTAssertEqual(copy.description.id, 13)
    }

    func testTextureAnimationsComeFromTheTexture() throws {
        var bytes = Array("TEXV0005\u{0}".utf8)
        bytes += Array("TEXS0002\u{0}".utf8)
        func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { bytes += $0 } }
        u32(2)
        for duration: Float in [0.25, 0.75] {
            u32(0)
            u32(duration.bitPattern)
            for _ in 0..<6 { u32(0) }
        }
        XCTAssertEqual(TEXSpriteFrames.durations(bytes), [0.25, 0.75])
        XCTAssertNil(TEXSpriteFrames.durations(Array("TEXV0005\u{0}".utf8)))
    }
}
