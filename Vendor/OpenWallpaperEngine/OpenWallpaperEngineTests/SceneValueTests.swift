import XCTest
@testable import OpenWallpaperEngine

private struct MockValueContext: SceneValueContext {
    var properties: [String: String] = [:]
    var animations: [SceneAnimationSite: [Float]] = [:]

    func userProperty(_ name: String) -> String? { properties[name] }
    func animationValue(_ site: SceneAnimationSite) -> [Float]? { animations[site] }
}

final class SceneValueTests: XCTestCase {
    private func source(_ json: Any) throws -> SceneValueSource {
        try XCTUnwrap(SceneValueSource(json: json))
    }

    private func value(_ json: Any, _ context: MockValueContext = MockValueContext()) throws -> ShaderValue {
        SceneValueResolver.resolve(try source(json), in: context)
    }

    // MARK: ShaderValue

    func testParsesWEStrings() {
        XCTAssertEqual(ShaderValue(string: "1 0.5 0.25")?.components, [1, 0.5, 0.25])
        XCTAssertEqual(ShaderValue(string: "  1   2 ")?.components, [1, 2])
        XCTAssertEqual(ShaderValue(string: "1")?.components, [1])
        XCTAssertEqual(ShaderValue(string: "true")?.components, [1])
        XCTAssertNil(ShaderValue(string: "abc"))
        XCTAssertNil(ShaderValue(string: ""))
    }

    func testPaddingAndTruncation() {
        let value = ShaderValue(components: [1, 2, 3])
        XCTAssertEqual(value.padded(to: 4), [1, 2, 3, 0])
        XCTAssertEqual(value.padded(to: 2), [1, 2])
        XCTAssertEqual(value.vec4, SIMD4(1, 2, 3, 0))
        XCTAssertEqual(value.float, 1)
        XCTAssertEqual(ShaderValue(components: [1.4, 1.6, -0.6]).roundedToIntegers().components, [1, 2, -1])
    }

    // MARK: Value forms

    func testLiterals() throws {
        XCTAssertEqual(try value(NSNumber(value: 0.86)).float, 0.86, accuracy: 1e-6)
        XCTAssertEqual(try value(true).components, [1])
        XCTAssertEqual(try value(false).components, [0])
        XCTAssertEqual(try value("1 0.5 0").components, [1, 0.5, 0])
        XCTAssertNil(SceneValueSource(json: "not a number"))
        XCTAssertNil(SceneValueSource(json: ["unrelated": 1]))
    }

    func testUserBindingUsesPropertyOrFallback() throws {
        let json: [String: Any] = ["user": "tint", "value": "1 1 1"]
        XCTAssertEqual(try value(json).components, [1, 1, 1])
        XCTAssertEqual(try value(json, MockValueContext(properties: ["tint": "0.2 0.4 0.6"])).components, [0.2, 0.4, 0.6])
        XCTAssertEqual(try value(["user": "on", "value": 0], MockValueContext(properties: ["on": "true"])).components, [1])
        XCTAssertEqual(try value(["user": "on", "value": 1], MockValueContext(properties: ["on": "false"])).components, [0])
        XCTAssertEqual(try value(["user": "combo", "value": 1], MockValueContext(properties: ["combo": "3"])).components, [3])
    }

    /// `"script": null` and `"animation": null` mean no script or timeline (2048761036 writes them
    /// beside a user binding), as `"user": null` means no binding.
    func testNullScriptAndAnimationAreUnbound() throws {
        let json: [String: Any] = ["script": NSNull(), "animation": NSNull(), "user": "size", "value": 0.2]
        let parsed = try source(json)
        guard case .user(let name, _, _) = parsed else { return XCTFail("expected a user binding, got \(parsed)") }
        XCTAssertEqual(name, "size")
        XCTAssertEqual(try value(json, MockValueContext(properties: ["size": "0.5"])).components, [0.5])
        XCTAssertEqual(try value(["script": NSNull(), "value": 1]).components, [1])
    }

    func testUserConditionBinding() throws {
        let json: [String: Any] = ["user": ["name": "mode", "condition": "2"], "value": 0.5]
        XCTAssertEqual(try value(json, MockValueContext(properties: ["mode": "2"])).components, [1])
        XCTAssertEqual(try value(json, MockValueContext(properties: ["mode": "2.0"])).components, [1])
        XCTAssertEqual(try value(json, MockValueContext(properties: ["mode": "3"])).components, [0])
        XCTAssertEqual(try value(json).components, [0.5], "missing property uses the fallback")
        let stringCondition: [String: Any] = ["user": ["name": "style", "condition": "neon"], "value": 0]
        XCTAssertEqual(try value(stringCondition, MockValueContext(properties: ["style": "neon"])).components, [1])
    }

    /// A scripted value resolves to what its script starts from: the wallpaper's SceneScript
    /// runtime runs the script, and the renderer draws what it wrote (docs/scenescript-plan.md WP11).
    func testScriptedValueResolvesToItsStartingValue() throws {
        let json: [String: Any] = ["script": "export function update(v) { return v * 2; }", "value": "1 2",
                                   "scriptproperties": ["speed": 3]]
        guard case let .script(_, properties, _) = try source(json) else { return XCTFail("expected script") }
        XCTAssertEqual(properties.dictionary["speed"] as? Int, 3)
        XCTAssertEqual(try value(json).components, [1, 2])
    }

    /// An animated value is its timeline's value this frame, over `user` and the literal (WE's
    /// setter runs every frame, docs/timeline-plan.md §2.6); the timeline itself lives in the
    /// instance's `SceneAnimationSet`, found by the site the loader binds.
    func testAnimationBeatsUserAndLiteral() throws {
        let json: [String: Any] = ["value": 0.3, "user": "fade", "animation": [
            "c0": [["frame": 0, "value": 0], ["frame": 30, "value": 1]], "options": ["fps": 30, "length": 60]
        ]]
        let site = SceneAnimationSite(owner: .material(object: 1, effect: 0, pass: 0), key: "alpha")
        let parsed = try source(json)
        XCTAssertTrue(parsed.isDynamic)
        guard case .animation(nil, .user("fade", nil, .literal)) = parsed else { return XCTFail("\(parsed)") }
        let bound = parsed.bindingAnimation(to: site)
        let context = MockValueContext(properties: ["fade": "0.8"], animations: [site: [0.25]])
        XCTAssertEqual(SceneValueResolver.resolve(bound, in: context).components, [0.25], "the timeline wins")
        XCTAssertEqual(SceneValueResolver.resolve(parsed, in: context).components, [0.8], "unbound: user, then literal")
        XCTAssertEqual(SceneValueResolver.resolve(bound, in: MockValueContext()).components, [0.3],
                       "no timeline at the site (it didn't load): the other sources")

        let scripted = try source(["value": 1, "script": "export function update(v) { return v; }",
                                   "animation": ["c0": [], "options": ["fps": 30, "length": 60]]])
        guard case .script(_, _, .animation(site, _)) = scripted.bindingAnimation(to: site) else {
            return XCTFail("a script wraps the animation, whose return wins for its frame")
        }

        // The app's inspector edit is a user value: it replaces the literal, under the timeline.
        let alpha = [ShaderUniformDeclaration(type: "float", name: "g_Alpha", arrayCount: nil, annotation: ["material": "alpha"])]
        let animated = try source(["value": 0.3, "animation": [
            "c0": [["frame": 0, "value": 0], ["frame": 30, "value": 1]], "options": ["fps": 30, "length": 60]
        ]]).bindingAnimation(to: site)
        let edited = SceneEffectPlanBuilder.applyingOverrides(
            { _ in SceneEffectOverride(property: "edit", value: "0.9") }, to: ["Alpha": animated], uniforms: alpha)
        guard case .animation(site, .literal(let value)) = try XCTUnwrap(edited["alpha"]) else {
            return XCTFail("\(edited)")
        }
        XCTAssertEqual(value.components, [0.9])

        // A value bound to a user property keeps it: WE's editor shows no value control for it.
        let userBound = SceneEffectPlanBuilder.applyingOverrides(
            { _ in SceneEffectOverride(property: "edit", value: "0.9", isMusicSynced: true) }, to: ["Alpha": bound],
            uniforms: alpha)
        XCTAssertEqual(userBound["Alpha"], bound, "the binding and its timeline are kept, the edit ignored")
    }

    /// Every way an effect parameter's value is bound keeps its binding under an inspector edit
    /// (roadmap notes 8.11): a timeline, a script, and a user property (whose edit WE's editor doesn't offer).
    func testInspectorEditsKeepBindings() throws {
        let uniform = [ShaderUniformDeclaration(type: "float", name: "g_Speed", arrayCount: nil, annotation: ["material": "speed"])]
        let edit: (String) -> SceneEffectOverride? = { _ in SceneEffectOverride(property: "edit", value: "2") }
        let scripted = try source(["value": 1, "script": "export function update(v) { return v * 2; }"])
        guard case .script(_, _, .literal(let base)) = try XCTUnwrap(
            SceneEffectPlanBuilder.applyingOverrides(edit, to: ["speed": scripted], uniforms: uniform)["speed"]) else {
            return XCTFail("the script stays over the edited value")
        }
        XCTAssertEqual(base.components, [2])
        let user = try source(["value": 1, "user": "speed"])
        XCTAssertEqual(user.boundUserProperty, "speed")
        XCTAssertEqual(SceneEffectPlanBuilder.applyingOverrides(edit, to: ["speed": user], uniforms: uniform)["speed"], user)
        let scriptOverUser = try source(["value": 1, "user": "speed", "script": "export function update(v) { return v; }"])
        XCTAssertEqual(scriptOverUser.boundUserProperty, "speed")
        XCTAssertEqual(SceneEffectPlanBuilder.applyingOverrides(edit, to: ["speed": scriptOverUser], uniforms: uniform)["speed"],
                       scriptOverUser)
        XCTAssertNil(try source(["value": 1]).boundUserProperty)
    }

    // MARK: Constants

    private typealias Uniform = ShaderConstantResolver.Uniform

    func testPrecedenceDefaultMaterialInstance() {
        let uniform = Uniform(name: "g_Strength", glslType: "float", annotation: ["material": "strength", "default": 1])
        let resolve = { (material: [String: SceneValueSource], instance: [String: SceneValueSource]) in
            ShaderConstantResolver.resolve(uniforms: [uniform], material: material, instance: instance)
                .values(in: MockValueContext())["g_Strength"]
        }
        XCTAssertEqual(resolve([:], [:]), ShaderValue(1))
        XCTAssertEqual(resolve(["strength": .literal(ShaderValue(2))], [:]), ShaderValue(2))
        XCTAssertEqual(resolve(["strength": .literal(ShaderValue(2))], ["strength": .literal(ShaderValue(3))]), ShaderValue(3))
    }

    func testKeyMatching() {
        let uniform = Uniform(name: "g_Speed", glslType: "float", annotation: ["material": "Speed"])
        func match(_ key: String) -> ShaderValue? {
            ShaderConstantResolver.resolve(uniforms: [uniform], material: [key: .literal(ShaderValue(5))], instance: [:])
                .staticValues["g_Speed"]
        }
        XCTAssertEqual(match("Speed"), ShaderValue(5))
        XCTAssertEqual(match("speed"), ShaderValue(5))
        let bare = Uniform(name: "g_ScrollSpeed", glslType: "float", annotation: ["material": "scroll"])
        let resolved = ShaderConstantResolver.resolve(uniforms: [bare], material: ["scrollspeed": .literal(ShaderValue(7))], instance: [:])
        XCTAssertEqual(resolved.staticValues["g_ScrollSpeed"], ShaderValue(7))
        // Exact beats case-insensitive.
        let both = ShaderConstantResolver.resolve(uniforms: [uniform],
                                                  material: ["speed": .literal(ShaderValue(1)), "Speed": .literal(ShaderValue(2))],
                                                  instance: [:])
        XCTAssertEqual(both.staticValues["g_Speed"], ShaderValue(2))
    }

    func testDefaultsShapesAndOmission() {
        let uniforms = [
            Uniform(name: "g_Ratio", glslType: "float", annotation: ["material": "ratio", "default": "0.75"]),
            Uniform(name: "g_Color", glslType: "vec3", annotation: ["material": "color", "default": "1 0.5"]),
            Uniform(name: "g_Point", glslType: "vec2", annotation: ["material": "point", "default": "1 2 3 4"]),
            Uniform(name: "g_Count", glslType: "float", annotation: ["material": "count", "default": 2.6, "int": true]),
            Uniform(name: "g_Unset", glslType: "vec4", annotation: ["material": "unset"]),
            Uniform(name: "g_Builtin", glslType: "float"),
            Uniform(name: "g_Texture0", glslType: "sampler2D", annotation: ["material": "tex"])
        ]
        let values = ShaderConstantResolver.resolve(uniforms: uniforms, material: [:], instance: [:]).staticValues
        XCTAssertEqual(values["g_Ratio"], ShaderValue(0.75), "string default on float is not truncated")
        XCTAssertEqual(values["g_Color"]?.components, [1, 0.5, 0])
        XCTAssertEqual(values["g_Point"]?.components, [1, 2])
        XCTAssertEqual(values["g_Count"]?.components, [3])
        XCTAssertEqual(values["g_Unset"]?.components, [0, 0, 0, 0])
        XCTAssertNil(values["g_Builtin"])
        XCTAssertNil(values["g_Texture0"])
    }

    func testDynamicSourcesAreSplitOut() throws {
        let uniforms = [Uniform(name: "g_A", glslType: "float", annotation: ["material": "a"]),
                        Uniform(name: "g_B", glslType: "vec2", annotation: ["material": "b", "default": "1 1"])]
        let resolved = ShaderConstantResolver.resolve(
            uniforms: uniforms,
            material: ["a": try source(["user": "level", "value": 0.2])],
            instance: [:])
        XCTAssertEqual(resolved.staticValues.keys.sorted(), ["g_B"])
        XCTAssertEqual(resolved.dynamic.map(\.uniform), ["g_A"])
        XCTAssertEqual(resolved.values(in: MockValueContext(properties: ["level": "0.9"]))["g_A"], ShaderValue(0.9))
        XCTAssertEqual(resolved.values(in: MockValueContext())["g_A"], ShaderValue(0.2))
    }

    // MARK: Data

    func testEveryStoredConstantParses() throws {
        let root = URL(fileURLWithPath: "/Volumes/980Pro/OpenWallpaperStorage")
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw XCTSkip("no local wallpaper storage at \(root.path)")
        }
        var counts: [String: Int] = [:]
        var failures: [String] = []
        func walk(_ node: Any, file: String) {
            if let dictionary = node as? [String: Any] {
                for (key, child) in dictionary {
                    if key == "constantshadervalues", let constants = child as? [String: Any] {
                        for (name, raw) in constants {
                            guard let parsed = SceneValueSource(json: raw) else {
                                failures.append("\(file): \(name) = \(raw)")
                                continue
                            }
                            let kind: String
                            switch parsed {
                            case .literal: kind = "literal"
                            case .user: kind = "user"
                            case .script: kind = "script"
                            case .animation: kind = "animation"
                            }
                            counts[kind, default: 0] += 1
                        }
                    } else {
                        walk(child, file: file)
                    }
                }
            } else if let array = node as? [Any] {
                array.forEach { walk($0, file: file) }
            }
        }
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        var scenes = 0
        for folder in folders {
            let url = folder.appendingPathComponent("scene.json")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let data = try Data(contentsOf: url)
            walk(try JSONSerialization.jsonObject(with: data), file: folder.lastPathComponent)
            scenes += 1
        }
        let summary = counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        print("SceneValueTests: \(scenes) scenes, \(summary), failures=\(failures.count)")
        XCTAssertEqual(failures, [])
        XCTAssertGreaterThan(counts.values.reduce(0, +), 0)
    }
}
