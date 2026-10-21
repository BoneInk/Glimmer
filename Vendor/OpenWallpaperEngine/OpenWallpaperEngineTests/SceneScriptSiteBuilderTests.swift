import XCTest
@testable import OpenWallpaperEngine

/// `SceneScriptSiteBuilder` (docs/scenescript-plan.md WP8): every scene.json binding site WE
/// supports, in load order, with its binding, type, initial value and script properties.
final class SceneScriptSiteBuilderTests: XCTestCase {
    private static let scene = """
        {
          "general": {
            "camerashake": {"script": "s-shake", "user": "shake", "value": false},
            "bloomstrength": {"script": "s-bloom", "value": 1.5},
            "clearcolor": "0 0 0"
          },
          "objects": [
            {"id": 7, "name": "Logo",
             "scale": {"script": "s-scale", "value": "1 1 1"},
             "brightness": {"script": "s-brightness", "value": 2},
             "visible": {"script": "s-visible", "user": {"name": "mode", "condition": "2"}, "value": true},
             "origin": "1 2 3",
             "angles": {"script": "s-angles", "value": "0 0 45"},
             "effects": [
               {"file": "effects/tint/effect.json", "visible": {"script": "s-effect", "value": true},
                "passes": [{"constantshadervalues": {
                  "multiply": {"script": "s-multiply", "value": 0.5},
                  "Bar Color": {"script": "s-bar", "value": "1 0.5 0"},
                  "plain": 3}}]}
             ],
             "text": {"script": "", "value": "no script"}},
            {"name": "Sparks",
             "instanceoverride": {
               "rate": {"script": "s-rate", "value": 2},
               "colorn": {"script": "s-colorn", "value": "1 1 1"},
               "count": 5}},
            {"id": 9, "name": "Clock",
             "text": {"script": "s-text", "value": "00:00",
                      "scriptproperties": {"delimiter": ":", "showSeconds": {"user": "seconds", "value": true},
                                           "hour": {"user": "missing", "value": {"user": "alsoMissing", "value": 12}},
                                           "size": {"user": {"name": "mode", "condition": "2"}, "value": false}}}}
          ]
        }
        """

    private func build(userProperties: SceneScriptUserProperties = SceneScriptUserProperties()) throws -> [SceneScriptSite] {
        let document = try SceneScriptSiteBuilder.document(from: Data(Self.scene.utf8))
        let slots = [7: 3, 9: 4]
        let builder = SceneScriptSiteBuilder(wallpaperID: "123", userProperties: userProperties,
                                             slot: { slots[$0] })
        return builder.sites(in: document)
    }

    private func site(_ sites: [SceneScriptSite], _ source: String, file: StaticString = #filePath,
                      line: UInt = #line) throws -> SceneScriptSite {
        try XCTUnwrap(sites.first { $0.instance.source == source }, source, file: file, line: line)
    }

    func testFindsEverySiteInLoadOrder() throws {
        let sites = try build()
        XCTAssertEqual(sites.map(\.instance.source), [
            "s-bloom", "s-shake",
            "s-visible", "s-scale", "s-angles", "s-brightness", "s-effect", "s-bar", "s-multiply",
            "s-colorn", "s-rate",
            "s-text",
        ])
        XCTAssertEqual(sites.map(\.property.path), [
            "general.bloomstrength", "general.camerashake",
            "visible", "scale", "angles", "brightness", "effects.0.visible",
            "effects.0.passes.0.constantshadervalues.Bar Color", "effects.0.passes.0.constantshadervalues.multiply",
            "instanceoverride.colorn", "instanceoverride.rate", "text",
        ])
        XCTAssertEqual(Set(sites.map(\.instance.id)).count, sites.count)
        XCTAssertEqual(try site(sites, "s-scale").instance.id, "123/Logo#7/scale")
        XCTAssertEqual(try site(sites, "s-rate").instance.id, "123/Sparks#i1/instanceoverride.rate")
        XCTAssertEqual(try site(sites, "s-bloom").instance.id, "123/scene/general.bloomstrength")
    }

    func testBindingsAndSlots() throws {
        let sites = try build()
        XCTAssertEqual(try site(sites, "s-scale").instance.binding, .layer(slot: 3, property: "scale"))
        XCTAssertEqual(try site(sites, "s-effect").instance.binding, .effect(slot: 3, effect: 0, property: "visible"))
        XCTAssertEqual(try site(sites, "s-bar").instance.binding,
                       .material(slot: 3, effect: 0, material: 0, constant: "Bar Color"))
        XCTAssertEqual(try site(sites, "s-bloom").instance.binding, .scene(property: "bloomstrength"))
        XCTAssertEqual(try site(sites, "s-scale").instance.objectSlot, 3)
        XCTAssertEqual(try site(sites, "s-text").objectID, 9)
        // An object without an id has no slot, so no thisLayer.
        XCTAssertNil(try site(sites, "s-rate").instance.objectSlot)
        XCTAssertNil(try site(sites, "s-rate").instance.binding)
    }

    func testTypesAndInitialValues() throws {
        let sites = try build()
        func check(_ source: String, _ type: SceneScriptPropertyType, _ initial: NSObject,
                   file: StaticString = #filePath, line: UInt = #line) throws {
            let found = try site(sites, source, file: file, line: line)
            XCTAssertEqual(found.property.type, type, source, file: file, line: line)
            XCTAssertEqual(found.instance.initialValue as? NSObject, initial, source, file: file, line: line)
        }
        try check("s-scale", .vec3, ["x": 1.0, "y": 1.0, "z": 1.0] as NSDictionary)
        try check("s-angles", .degrees, ["x": 0.0, "y": 0.0, "z": 45.0] as NSDictionary)
        try check("s-brightness", .number, 2.0 as NSNumber)
        try check("s-visible", .bool, true as NSNumber)
        try check("s-effect", .bool, true as NSNumber)
        try check("s-multiply", .number, 0.5 as NSNumber)
        try check("s-bar", .vec3, ["x": 1.0, "y": 0.5, "z": 0.0] as NSDictionary)
        try check("s-rate", .number, 2.0 as NSNumber)
        // lib.sceneScript.d.ts types `colorn` a Number although scene.json writes a colour.
        try check("s-colorn", .number, 1.0 as NSNumber)
        try check("s-bloom", .number, 1.5 as NSNumber)
        try check("s-shake", .bool, false as NSNumber)
        try check("s-text", .string, "00:00" as NSString)
    }

    func testUserBindingsResolveToTheUsersValues() throws {
        let properties = try SceneScriptUserProperties.parsing("""
            {"shake": {"type": "bool", "value": true}, "mode": {"type": "combo", "value": "2"},
             "seconds": {"type": "bool", "value": false}}
            """)
        let sites = try build(userProperties: properties)
        XCTAssertEqual(try site(sites, "s-shake").instance.initialValue as? Bool, true)
        XCTAssertEqual(try site(sites, "s-shake").property.user, SceneScriptUserReference(name: "shake"))
        XCTAssertEqual(try site(sites, "s-visible").instance.initialValue as? Bool, true, "condition '2' holds")

        let text = try site(sites, "s-text")
        let json = try XCTUnwrap(text.instance.scriptPropertiesJSON)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(decoded["delimiter"] as? String, ":")
        XCTAssertEqual(decoded["showSeconds"] as? Bool, false, "the user's value")
        XCTAssertEqual(decoded["hour"] as? Int, 12, "missing properties fall back to the innermost literal")
        XCTAssertEqual(decoded["size"] as? Bool, true, "a condition becomes a flag")
        XCTAssertEqual(text.property.scriptPropertyUsers["showSeconds"], SceneScriptUserReference(name: "seconds"))
        XCTAssertEqual(text.property.scriptPropertyUsers["hour"], SceneScriptUserReference(name: "missing"))
        XCTAssertEqual(text.property.scriptPropertyUsers["size"], SceneScriptUserReference(name: "mode", condition: "2"))
        XCTAssertNil(text.property.scriptPropertyUsers["delimiter"])

        let unresolved = try build()
        XCTAssertEqual(try site(unresolved, "s-visible").instance.initialValue as? Bool, true,
                       "without the property the authored value stands")
    }

    func testValuesLeftOutGetTheObjectModelsDefaults() throws {
        let document = try SceneScriptSiteBuilder.document(from: Data("""
            {"objects": [{"id": 1, "name": "A",
              "scale": {"script": "a"}, "alpha": {"script": "b"}, "text": {"script": "c"},
              "effects": [{"visible": {"script": "d"}}]}]}
            """.utf8))
        let sites = SceneScriptSiteBuilder(wallpaperID: "w").sites(in: document)
        let initial = Dictionary(uniqueKeysWithValues: sites.map { ($0.instance.source, $0.instance.initialValue as? NSObject) })
        XCTAssertEqual(initial["a"], ["x": 1.0, "y": 1.0, "z": 1.0] as NSDictionary)
        XCTAssertEqual(initial["b"], 1.0 as NSNumber)
        XCTAssertEqual(initial["c"], "" as NSString)
        XCTAssertEqual(initial["d"], true as NSNumber)
    }

    func testTypesFromTheValuesShape() {
        XCTAssertEqual(SceneScriptPropertyType(fieldPath: ["effects", "0", "passes", "0", "constantshadervalues", "k"],
                                               value: .string("1 2")), .vec2)
        XCTAssertEqual(SceneScriptPropertyType(fieldPath: ["x"], value: .string("1 2 3 4")), .vec4)
        XCTAssertEqual(SceneScriptPropertyType(fieldPath: ["x"], value: .string("1 2 3 4 5")), .string)
        XCTAssertEqual(SceneScriptPropertyType(fieldPath: ["x"], value: .string("hello")), .string)
        XCTAssertEqual(SceneScriptPropertyType(fieldPath: ["x"], value: .bool(true)), .bool)
        XCTAssertEqual(SceneScriptPropertyType(fieldPath: ["parallaxDepth"], value: .string("1")), .vec2)
        XCTAssertEqual(SceneScriptPropertyType(fieldPath: ["general", "clearcolor"], value: nil), .vec3)
        XCTAssertEqual(SceneScriptPropertyType(fieldPath: ["instanceoverride", "count"], value: nil), .number)
        XCTAssertEqual(SceneScriptPropertyType(fieldPath: ["alignment"], value: .string("1 2")), .string)
    }

    func testDuplicateIdsGetASuffix() throws {
        let document = try SceneScriptSiteBuilder.document(from: Data("""
            {"objects": [{"id": 1, "name": "A", "alpha": {"script": "a"}}, {"id": 1, "name": "A", "alpha": {"script": "b"}}]}
            """.utf8))
        let ids = SceneScriptSiteBuilder(wallpaperID: "w").sites(in: document).map(\.instance.id)
        XCTAssertEqual(ids, ["w/A#1/alpha", "w/A#1/alpha~2"])
    }

    /// Every corpus wallpaper (skipped without the corpus): the builder finds the corpus index's
    /// sites, with the same sources and field paths, and every script id is unique. A wallpaper
    /// that changed since the corpus was extracted is checked for unique ids only; one that left
    /// the library is skipped (`SceneScriptCorpus.state`, listed in the attachment).
    func testFindsEveryCorpusSite() throws {
        let index = SceneScriptCorpus.directory.appending(path: "index.json")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: index.path), "SceneScript corpus not present")
        let corpus = try SceneScriptCorpus.wallpapers()
        XCTAssertGreaterThanOrEqual(corpus.count, 43)
        var compared = 0
        var changed: [String] = [], removed: [String] = []
        for entry in corpus {
            let label = entry.label
            guard let directory = entry.directory else { continue }
            let state = SceneScriptCorpus.state(of: entry)
            if state == .removed {
                removed.append(label)
                continue
            }
            let wallpaper = try SceneScriptReplayWallpaper(directory: directory, id: entry.id)
            let data = try XCTUnwrap(wallpaper.file(wallpaper.documentName), label)
            let project = try SceneScriptSiteBuilder.document(from: Data(contentsOf: wallpaper.directory.appending(path: "project.json")))
            let builder = SceneScriptSiteBuilder(wallpaperID: entry.id, userProperties: SceneScriptUserProperties(project: project))
            let found = builder.sites(in: try SceneScriptSiteBuilder.document(from: data))
            XCTAssertEqual(Set(found.map(\.instance.id)).count, found.count, label)
            guard state == .current else {
                changed.append(label)
                continue
            }
            // assets.json's fields keep the object's path; the builder's are relative to the object.
            let expected = entry.entries.map { site in
                "\(site.field.replacingOccurrences(of: #"^objects\.\d+\."#, with: "", options: .regularExpression)) \(site.hash)"
            }
            XCTAssertEqual(found.map { "\($0.property.path) \(SceneScriptReplayWallpaper.hash($0.instance.source))" }.sorted(),
                           expected.sorted(), label)
            compared += 1
        }
        XCTAssertGreaterThan(compared, 0, "no corpus wallpaper is as the corpus extracted it")
        LibraryReport.attach("SceneScript corpus: library changes since index.json", SceneScriptCorpus.notes(changed: changed, removed: removed))
    }

    func testAssetPacksUseTheSameWalk() throws {
        let document = try SceneScriptSiteBuilder.document(from: Data("""
            {"objects": [{"name": "Bar", "text": {"script": "t", "value": "x"}}], "category": "Asset"}
            """.utf8))
        let sites = SceneScriptSiteBuilder(wallpaperID: "pack").sites(in: document)
        XCTAssertEqual(sites.map(\.instance.id), ["pack/Bar#i0/text"])
    }
}
