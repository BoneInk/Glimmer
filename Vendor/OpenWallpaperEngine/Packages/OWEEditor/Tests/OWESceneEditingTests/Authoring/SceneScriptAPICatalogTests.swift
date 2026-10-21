import XCTest
@testable import OWESceneEditing

/// The script editor's autocomplete, built from the SceneScript typings: every member of WE's
/// object model, the globals, the callbacks, and what is offered at a position of a script.
final class SceneScriptAPICatalogTests: XCTestCase {
    private let catalog = SceneScriptAPICatalog.standard

    /// The repository's member list of WE's typings (lib.sceneScript.d.ts 2.8).
    private func typingsMembers() throws -> [String: [String]] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Tests/Fixtures/SceneScript/object-model-members.json")
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return try XCTUnwrap(root["interfaces"] as? [String: [String]])
    }

    func testEveryMemberOfWEsTypingsIsOffered() throws {
        let typings = try typingsMembers()
        XCTAssertFalse(typings.isEmpty)
        var missing: [String] = []
        for (interface, members) in typings {
            XCTAssertNotNil(catalog.interfaces[interface], "no \(interface)")
            let offered = Set(catalog.members(of: interface).map(\.name))
            missing += members.filter { !offered.contains($0) }.map { "\(interface).\($0)" }
        }
        XCTAssertTrue(missing.isEmpty, "not offered: \(missing.sorted())")
    }

    func testTheGlobalsAndTheirTypes() {
        let names = Set(catalog.globals.map(\.name))
        for name in ["engine", "thisLayer", "thisScene", "thisObject", "input", "console", "localStorage", "shared",
                     "createScriptProperties", "Vec2", "Vec3", "Vec4", "Mat3", "Mat4", "MediaPlaybackEvent",
                     "WEMath", "WEVector", "WEColor"] {
            XCTAssertTrue(names.contains(name), name)
        }
        XCTAssertEqual(catalog.global("engine")?.type, "IEngine")
        XCTAssertEqual(catalog.global("WEMath")?.kind, .module)
        XCTAssertEqual(catalog.member("registerAudioBuffers", of: "IEngine")?.type, "AudioBuffers")
        XCTAssertEqual(catalog.member("frametime", of: "IEngine")?.isReadOnly, true)
        XCTAssertEqual(catalog.member("getAnimation", of: "ILayer")?.type, "IAnimation", "inherited from IObject")
        // The media and audio APIs.
        XCTAssertEqual(Set(catalog.members(of: "AudioBuffers").map(\.name)), ["left", "right", "average"])
        XCTAssertTrue(catalog.members(of: SceneScriptAPICatalog.callbackInterface).map(\.name)
            .contains("mediaThumbnailChanged"))
        XCTAssertEqual(Set(catalog.members(of: "MediaPlaybackEventClass").map(\.name)),
                       ["PLAYBACK_STOPPED", "PLAYBACK_PLAYING", "PLAYBACK_PAUSED"])
    }

    private func labels(_ text: String) -> [String] {
        catalog.completions(in: text, at: (text as NSString).length).items.map(\.label)
    }

    func testMembersOfAGlobal() {
        let members = labels("export function update(value) {\n\treturn thisLayer.")
        for name in ["origin", "alpha", "text", "getEffect", "getTextureAnimation", "play", "instance"] {
            XCTAssertTrue(members.contains(name), name)
        }
        XCTAssertFalse(members.contains("registerAudioBuffers"))
        XCTAssertEqual(labels("engine.reg"), ["registerAsset", "registerAudioBuffers"])
        XCTAssertEqual(labels("input.cursorW"), ["cursorWorldPosition"])
    }

    func testChainsResolveThroughCallsAndProperties() {
        XCTAssertTrue(labels("thisScene.getLayer('Logo').getEffect(0).").contains("setMaterialProperty"))
        XCTAssertTrue(labels("thisLayer.origin.").contains("normalize"))
        XCTAssertEqual(Set(labels("thisLayer.instance.controlpoint")).count, 8)
        XCTAssertTrue(labels("thisScene.enumerateLayers()[0].").contains("origin"))
        XCTAssertTrue(labels("createScriptProperties().addSlider({ name: 'a' }).").contains("finish"))
        XCTAssertTrue(labels("const v = new Vec3(1, 2, 3);\nv.").contains("cross"))
        XCTAssertTrue(labels("new Vec2(1, 2).").contains("perpendicular"))
    }

    func testLocalsAndImportsResolve() {
        XCTAssertTrue(labels("const audio = engine.registerAudioBuffers(16);\naudio.").contains("average"))
        XCTAssertTrue(labels("let layer = thisScene.getLayer('a');\nlayer.get").contains("getEffect"))
        XCTAssertEqual(labels("import * as M from 'WEMath';\nM.sm"), ["smoothStep"])
        XCTAssertEqual(labels("import * as WEColor from 'WEColor';\nWEColor.hsv"), ["hsv2rgb"])
    }

    func testAnUnknownReceiverOffersEveryMember() {
        let members = labels("export function cursorClick(event) { event.")
        XCTAssertTrue(members.contains("worldPosition"))
        XCTAssertTrue(members.contains("origin"))
    }

    func testGlobalsCallbacksAndModules() {
        let top = labels("thi")
        XCTAssertEqual(Array(top.prefix(4)), ["this", "thisLayer", "thisObject", "thisScene"])
        XCTAssertTrue(labels("export function ").contains("applyUserProperties"))
        XCTAssertEqual(labels("export function curs").first, "cursorClick")
        XCTAssertEqual(Set(labels("import * as m from '")), ["WEMath", "WEVector", "WEColor"])
        XCTAssertTrue(labels("Ma").contains("Math"))
        XCTAssertTrue(labels("Ma").contains("Mat3"))
    }

    func testNothingInsideCommentsAndStrings() {
        XCTAssertTrue(labels("// thisLayer.").isEmpty)
        XCTAssertTrue(labels("const s = 'thisLayer.").isEmpty)
        XCTAssertTrue(labels("/* engine.").isEmpty)
        XCTAssertFalse(labels("/* note */ engine.").isEmpty)
        XCTAssertFalse(labels("const s = 'x'; engine.").isEmpty)
    }

    func testTheRangeIsThePartialWord() {
        let text = "thisLayer.ori"
        let result = catalog.completions(in: text, at: (text as NSString).length)
        XCTAssertEqual(result.range, NSRange(location: 10, length: 3))
        XCTAssertEqual(result.items.first?.label, "origin")
        XCTAssertEqual(result.items.first?.detail, "origin: Vec3")
        XCTAssertEqual(result.items.first?.kind, .property)
        XCTAssertEqual(catalog.completions(in: "thisLayer.getEff", at: 16).items.first?.detail,
                       "getEffect(nameOrIndex: String | Number): IEffect")
    }
}
