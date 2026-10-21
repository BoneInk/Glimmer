import XCTest
@testable import OpenWallpaperEngine

final class EffectDocumentTests: XCTestCase {
    /// Local Wallpaper Engine install and library; CI has neither, so those tests skip.
    private static let assetsRoot = ShaderVariantTests.weAssets
    private static let libraryRoot = URL(fileURLWithPath: "/Volumes/980Pro/OpenWallpaperStorage", isDirectory: true)

    private func directories(in url: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [] // optional: absent dir = none
        return names.sorted().map { url.appending(path: $0, directoryHint: .isDirectory) }
            .filter { var isDir: ObjCBool = false
                return FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDir) && isDir.boolValue }
    }

    private func firstExisting(_ candidates: [URL]) -> URL? {
        candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Decodes an effect and every material it references; returns (effects, materials) decoded.
    @discardableResult
    private func decodeEffect(at effectDir: URL, searchRoots: [URL], failures: DecodeFailureLog,
                              requireMaterials: Bool) throws -> (EffectDocument, Int) {
        let effectURL = effectDir.appending(path: "effect.json")
        let effect = try decodeTolerant(EffectDocument.self, from: Data(contentsOf: effectURL), failures: failures)
        XCTAssertFalse(effect.passes.isEmpty, "\(effectURL.path) has no passes")
        var materials = 0
        for material in effect.passes.compactMap(\.material) {
            let candidates = ([effectDir] + searchRoots).map { $0.appending(path: material) }
            guard let url = firstExisting(candidates) else {
                if requireMaterials { XCTFail("\(effectURL.path): material \(material) not found") }
                continue
            }
            let document = try decodeTolerant(MaterialDocument.self, from: Data(contentsOf: url), failures: failures)
            XCTAssertFalse(document.passes.isEmpty, "\(url.path) has no passes")
            materials += 1
        }
        return (effect, materials)
    }

    func testDecodesEveryBuiltInEffectAndMaterial() throws {
        let effectsRoot = Self.assetsRoot.appending(path: "effects", directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: effectsRoot.path) else {
            throw XCTSkip("Wallpaper Engine assets not installed")
        }
        let failures = DecodeFailureLog()
        var effects = 0, materials = 0
        for dir in directories(in: effectsRoot) where FileManager.default.fileExists(atPath: dir.appending(path: "effect.json").path) {
            let (_, count) = try decodeEffect(at: dir, searchRoots: [Self.assetsRoot], failures: failures, requireMaterials: true)
            effects += 1
            materials += count
        }
        XCTAssertEqual(effects, 46)
        XCTAssertGreaterThan(materials, effects)
        XCTAssertEqual(failures.messages, [])
    }

    func testDecodesEveryWorkshopEffectInTheLibrary() throws {
        guard FileManager.default.fileExists(atPath: Self.libraryRoot.path) else {
            throw XCTSkip("wallpaper library not present")
        }
        let failures = DecodeFailureLog()
        var effects = 0
        for wallpaper in directories(in: Self.libraryRoot) {
            let workshop = wallpaper.appending(path: "effects/workshop", directoryHint: .isDirectory)
            for item in directories(in: workshop) {
                for dir in directories(in: item) where FileManager.default.fileExists(atPath: dir.appending(path: "effect.json").path) {
                    try decodeEffect(at: dir, searchRoots: [wallpaper, Self.assetsRoot], failures: failures, requireMaterials: false)
                    effects += 1
                }
            }
        }
        if effects == 0 { throw XCTSkip("no workshop effects in the library") }
        XCTAssertEqual(failures.messages, [])
    }

    func testEffectSkipsOnlyBadElements() throws {
        let failures = DecodeFailureLog()
        let effect = try decodeTolerant(EffectDocument.self,
                                        from: Fixtures.data("Effects/partly-broken-effect.json"), failures: failures)
        XCTAssertEqual(effect.version, 1)
        XCTAssertEqual(effect.dependencies, ["materials/effects/a.json"])
        XCTAssertEqual(effect.passes.count, 2)
        XCTAssertEqual(effect.passes[0].material, "materials/effects/a.json")
        XCTAssertEqual(effect.passes[0].bind.map(\.name), ["previous"])
        XCTAssertEqual(effect.passes[0].conditions, [["MODE": 1]])
        XCTAssertEqual(effect.passes[1].commandKind, .copy)
        XCTAssertEqual(effect.passes[1].source, "_rt_A")
        XCTAssertEqual(effect.fbos.map(\.name), ["_rt_A", "_rt_B"])
        XCTAssertEqual(effect.fbos.map(\.scale), [2, 1])
        XCTAssertEqual(effect.fbos[1].fit, 512)
        // dependency 5, pass "not a pass", bind without name, fbo without format
        XCTAssertEqual(failures.messages.count, 4, failures.messages.joined(separator: "\n"))
    }

    /// Conditions in both of WE's forms: `{COMBO: n}` and WE 2.x's `{COMBO: {"op": …, "value": n}}`,
    /// as a list or a single object, on passes, binds and FBOs. An unknown op never holds.
    func testDecodesOpConditions() throws {
        let failures = DecodeFailureLog()
        let json = #"""
            {"passes": [{"material": "materials/effects/a.json",
                         "conditions": [{"POINTEMITTER": {"op": "ge", "value": 2}, "MODE": 1}, {"LINEEMITTER": {"op": "lt", "value": 3}}],
                         "bind": [{"name": "_rt_A", "index": 1, "conditions": {"MODE": {"op": "gt", "value": 0.0}}},
                                  {"name": "_rt_B", "index": 2, "conditions": [{"MODE": {"value": 4}}]}]}],
             "fbos": [{"name": "_rt_A", "format": "rgba8888", "conditions": [{"COUNT": {"op": "le", "value": 1}}]},
                      {"name": "_rt_B", "format": "rgba8888", "conditions": [{"COUNT": {"op": "between", "value": 1}}]}]}
            """#
        let effect = try decodeTolerant(EffectDocument.self, from: Data(json.utf8), failures: failures)
        let pass = try XCTUnwrap(effect.passes.first)
        XCTAssertEqual(pass.conditions, [["POINTEMITTER": EffectComboCondition(.ge, 2), "MODE": 1],
                                         ["LINEEMITTER": EffectComboCondition(.lt, 3)]])
        XCTAssertEqual(pass.bind.map(\.conditions), [[["MODE": EffectComboCondition(.gt, 0)]], [["MODE": 4]]])
        XCTAssertEqual(effect.fbos[0].conditions, [["COUNT": EffectComboCondition(.le, 1)]])
        XCTAssertEqual(effect.fbos[1].conditions, [["COUNT": EffectComboCondition(nil, 1)]])
        XCTAssertEqual(failures.messages.count, 1, "the unknown op: \(failures.messages.joined(separator: "\n"))")
    }

    func testOpConditionsHold() {
        func holds(_ conditions: EffectConditions?, _ combos: [String: Int]) -> Bool {
            SceneEffectPlanBuilder.conditionsHold(conditions, combos: combos)
        }
        XCTAssertTrue(holds(nil, [:]))
        XCTAssertTrue(holds([], [:]))
        XCTAssertTrue(holds([[:]], [:]), "an empty requirement always holds")
        let ge2: EffectConditions = [["POINTEMITTER": EffectComboCondition(.ge, 2)]]
        XCTAssertEqual([1, 2, 3].map { holds(ge2, ["POINTEMITTER": $0]) }, [false, true, true])
        XCTAssertEqual([1, 2, 3].map { holds([["N": EffectComboCondition(.gt, 2)]], ["N": $0]) }, [false, false, true])
        XCTAssertEqual([1, 2, 3].map { holds([["N": EffectComboCondition(.le, 2)]], ["N": $0]) }, [true, true, false])
        XCTAssertEqual([1, 2, 3].map { holds([["N": EffectComboCondition(.lt, 2)]], ["N": $0]) }, [true, false, false])
        XCTAssertEqual([1, 2, 3].map { holds([["N": EffectComboCondition(.eq, 2)]], ["N": $0]) }, [false, true, false])
        XCTAssertFalse(holds([["N": EffectComboCondition(nil, 2)]], ["N": 2]), "an unknown op never holds")
        XCTAssertTrue(holds(ge2, ["pointemitter": 0, "POINTEMITTER": 4]))
        XCTAssertTrue(holds([["pointemitter": EffectComboCondition(.ge, 2)]], ["POINTEMITTER": 2]), "combo names are upper case")
        XCTAssertFalse(holds(ge2, [:]), "a combo the pass doesn't have")
        // Any one requirement, all of its combos.
        let either: EffectConditions = [["A": 1, "B": EffectComboCondition(.ge, 1)], ["C": EffectComboCondition(.lt, 1)]]
        XCTAssertTrue(holds(either, ["A": 1, "B": 2, "C": 5]))
        XCTAssertFalse(holds(either, ["A": 1, "B": 0, "C": 5]))
        XCTAssertTrue(holds(either, ["A": 0, "B": 0, "C": 0]))
    }

    /// effect.json `functions` (`IEffect.executeMaterialFunction`): one bad entry is skipped alone.
    func testDecodesFunctions() throws {
        let failures = DecodeFailureLog()
        let json = #"""
            {"passes": [{"material": "materials/effects/a.json"}],
             "functions": {"clearA": {"action": "clear", "fbos": ["_rt_A", "_rt_B"]},
                           "later": {"action": "Clear"},
                           "broken": {"fbos": ["_rt_A"]}}}
            """#
        let effect = try decodeTolerant(EffectDocument.self, from: Data(json.utf8), failures: failures)
        XCTAssertEqual(effect.functions["clearA"], EffectFunction(action: "clear", fbos: ["_rt_A", "_rt_B"]))
        XCTAssertEqual(effect.functions["later"]?.actionKind, .clear)
        XCTAssertEqual(effect.functions["later"]?.fbos, [])
        XCTAssertNil(effect.functions["broken"])
        XCTAssertEqual(failures.messages.count, 1, failures.messages.joined(separator: "\n"))
    }

    func testMaterialKeepsNullTexturesAndEveryValueForm() throws {
        let failures = DecodeFailureLog()
        let material = try decodeTolerant(MaterialDocument.self,
                                          from: Fixtures.data("Effects/partly-broken-material.json"), failures: failures)
        XCTAssertEqual(material.passes.count, 1)
        let pass = material.passes[0]
        XCTAssertEqual(pass.shader, "effects/a")
        XCTAssertEqual(pass.textures, [nil, "util/noise", nil])
        XCTAssertEqual(pass.combos, ["MODE": 1])
        XCTAssertEqual(pass.usershadervalues, ["tint": "schemecolor"])
        let values = pass.constantshadervalues
        XCTAssertEqual(values["strength"], .number(0.5))
        XCTAssertEqual(values["color"], .string("1 0 0"))
        XCTAssertEqual(values["bound"], .object(.init(value: .number(3), userName: "prop", userCondition: "2")))
        guard case .object(let scripted)? = values["scripted"] else { return XCTFail("scripted") }
        XCTAssertEqual(scripted.value, .string("0 0"))
        XCTAssertEqual(scripted.scriptProperties, ["speed": .number(2)])
        XCTAssertNotNil(scripted.script)
        guard case .object(let animated)? = values["animated"] else { return XCTFail("animated") }
        XCTAssertEqual(animated.value, .number(1))
        XCTAssertNotNil(animated.animation)
        XCTAssertNil(values["bad"])
        // combo BAD, constant bad, pass without shader
        XCTAssertEqual(failures.messages.count, 3, failures.messages.joined(separator: "\n"))
    }
}
