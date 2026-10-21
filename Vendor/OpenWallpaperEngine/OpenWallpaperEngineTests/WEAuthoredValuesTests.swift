import XCTest
import JavaScriptCore
@testable import OpenWallpaperEngine

/// Every default, range, step and option the app shows or uses comes from WE's own data: shader
/// annotations, project.json properties, the scene's `general` block and `createScriptProperties`.
/// See we-values-audit notes.
final class WEAuthoredValuesTests: XCTestCase {
    private static let libraryRoot = LibrarySweepTests.libraryRoot

    // MARK: - Shader annotations (inspector parameter model)

    /// Walks every bundled effect and every effect shipped inside a library wallpaper: each
    /// parameter's default, range, label and flags equal its uniform's annotation, and its
    /// default equals the value the renderer resolves for that uniform.
    func testEveryEffectParameterIsItsAnnotation() throws {
        _ = try Fixtures.assets()
        var effects: [(file: String, roots: [URL])] = []
        let assets = ShaderVariantTests.weAssets
        for name in try FileManager.default.contentsOfDirectory(atPath: assets.appending(path: "effects").path).sorted() {
            effects.append(("effects/\(name)/effect.json", [assets]))
        }
        if FileManager.default.fileExists(atPath: Self.libraryRoot.path) {
            for id in try FileManager.default.contentsOfDirectory(atPath: Self.libraryRoot.path).sorted() {
                let wallpaper = Self.libraryRoot.appending(path: id)
                let effectsDirectory = wallpaper.appending(path: "effects")
                guard let enumerator = FileManager.default.enumerator(atPath: effectsDirectory.path) else { continue }
                for case let path as String in enumerator where path.hasSuffix("effect.json") {
                    effects.append(("effects/\(path)", [wallpaper, assets]))
                }
            }
        }
        var checkedParameters = 0, checkedCombos = 0
        for (file, roots) in effects {
            let readFile: (String) -> Data? = { path in
                roots.lazy.compactMap { FileManager.default.contents(atPath: $0.appending(path: path).path) }.first
            }
            let expected = try Self.annotatedUniforms(effectFile: file, readFile: readFile)
            let parameters = SceneEffectParameters.parameters(for: file, readFile: readFile)
            XCTAssertEqual(parameters.map(\.materialKey), expected.map(\.key), "\(file): parameter keys")
            for (parameter, uniform) in zip(parameters, expected) {
                let context = "\(file) \(parameter.materialKey)"
                let annotation = uniform.declaration.annotation
                XCTAssertEqual(parameter.label, annotation["label"] as? String ?? uniform.key, context)
                let range = (annotation["range"] as? [NSNumber])?.map(\.doubleValue) ?? [0, 1]
                XCTAssertEqual(parameter.minimum, range[0], context)
                XCTAssertEqual(parameter.maximum, range[1], context)
                XCTAssertEqual(parameter.isColor, (annotation["type"] as? String) == "color", context)
                XCTAssertEqual(parameter.isLinked, (annotation["linked"] as? Bool) == true, context)
                XCTAssertEqual(parameter.isInteger, (annotation["int"] as? Bool) == true || uniform.declaration.type == "int", context)
                let rendered = ShaderConstantResolver.resolve(
                    uniforms: [.init(name: uniform.declaration.name, glslType: uniform.declaration.type, annotation: annotation)],
                    material: [:], instance: [:]).staticValues[uniform.declaration.name]
                XCTAssertEqual(parameter.defaultValue, rendered?.components.map(Double.init), "\(context): default as rendered")
                checkedParameters += 1
            }
            let combos = SceneEffectParameters.combos(for: file, readFile: readFile)
            let expectedCombos = try Self.annotatedCombos(effectFile: file, readFile: readFile)
            XCTAssertEqual(combos.map(\.combo), expectedCombos.map { ($0["combo"] as? String ?? "").uppercased() }, file)
            for (combo, annotation) in zip(combos, expectedCombos) {
                XCTAssertEqual(combo.label, annotation["material"] as? String, "\(file) \(combo.combo)")
                XCTAssertEqual(combo.defaultValue, (annotation["default"] as? NSNumber)?.intValue ?? 0, "\(file) \(combo.combo)")
                var options = (annotation["options"] as? [String: NSNumber] ?? [:]).mapValues(\.intValue)
                if options.isEmpty, (annotation["type"] as? String)?.lowercased() == "imageblending" {
                    options = Dictionary(uniqueKeysWithValues: WEImageBlendModes.all.map { ($0.label, $0.value) })
                }
                XCTAssertEqual(Dictionary(uniqueKeysWithValues: combo.options.map { ($0.label, $0.value) }),
                               options, "\(file) \(combo.combo): options")
                checkedCombos += 1
            }
        }
        XCTAssertGreaterThan(checkedParameters, 50, "the corpus was walked")
        XCTAssertGreaterThan(checkedCombos, 0)
    }

    func testMissingRangeIsWEsEditorDefault() throws {
        let uniform = ShaderUniformDeclaration(type: "float", name: "g_A", arrayCount: nil,
                                               annotation: ["material": "a", "default": 3])
        let parameter = try XCTUnwrap(SceneEffectParameters.parameter(uniform, key: "a"))
        XCTAssertEqual(parameter.minimum, 0)
        XCTAssertEqual(parameter.maximum, 1, "WE's editor slider without `range` is 0...1; the value may sit outside it")
        XCTAssertEqual(parameter.defaultValue, [3])
    }

    func testVectorDefaultsParseAsTheRendererDoes() throws {
        let color = ShaderUniformDeclaration(type: "vec3", name: "g_C", arrayCount: nil,
                                             annotation: ["material": "c", "default": "1 0.5", "type": "color"])
        let parameter = try XCTUnwrap(SceneEffectParameters.parameter(color, key: "c"))
        XCTAssertEqual(parameter.defaultValue, [1, 0.5, 0], "missing components are 0, as ShaderConstantResolver pads them")
        XCTAssertTrue(parameter.isColor)
        let linked = ShaderUniformDeclaration(type: "vec2", name: "g_O", arrayCount: nil,
                                              annotation: ["material": "o", "default": "0 0", "linked": true, "range": [-10, 10]])
        let offset = try XCTUnwrap(SceneEffectParameters.parameter(linked, key: "o"))
        XCTAssertTrue(offset.isLinked)
        XCTAssertEqual(offset.minimum, -10)
        XCTAssertEqual(offset.maximum, 10)
    }

    func testComboOptionsKeepAuthoredOrder() {
        let text = #"// [COMBO] {"material":"ui_editor_properties_quality","combo":"q","default":9,"options":{"ui_high":13,"ui_low":5,"ui_medium":9}}"#
        let combos = SceneEffectParameters.combos(in: text)
        XCTAssertEqual(combos, [EffectShaderCombo(combo: "Q", label: "ui_editor_properties_quality", defaultValue: 9, options: [
            .init(label: "ui_high", value: 13), .init(label: "ui_low", value: 5), .init(label: "ui_medium", value: 9)
        ], type: nil)])
        XCTAssertEqual(SceneEffectParameters.combos(in: #"// [COMBO] {"combo":"MASK","default":0}"#), [],
                       "a combo without a material key isn't shown by WE's editor")
        let blend = SceneEffectParameters.combos(in: #"// [COMBO] {"material":"ui_editor_properties_blend_mode","combo":"BLENDMODE","type":"imageblending","default":9}"#)
        XCTAssertEqual(blend.first?.isEditable, true, "WE's editor supplies the blend modes")
        XCTAssertEqual(blend.first?.options.map(\.value), WEImageBlendModes.all.map(\.value))
        XCTAssertEqual(SceneEffectParameters.combos(in: #"// [COMBO] {"material":"ui_x","combo":"COPYBG","type":"options"}"#).first?.isEditable, true)
        let rim = SceneEffectParameters.combos(in: #"// [COMBO] {"material":"ui_rim","combo":"RIMLIGHTING","default":0,"require":{"LIGHTING":1}}"#)
        XCTAssertEqual(rim.first?.requirements, ["LIGHTING": 1])
    }

    func testInspectorComboChoiceReachesThePlan() {
        let declared = [ShaderComboDeclaration(name: "BLENDMODE", defaultValue: 0), ShaderComboDeclaration(name: "MASK", defaultValue: 0)]
        let chosen = SceneEffectPlanBuilder.comboOverrides({ key in
            key == SceneEffectParameters.comboOverrideKey("blendmode") ? SceneEffectOverride(property: "p", value: "5") : nil
        }, declared: declared)
        XCTAssertEqual(chosen, ["BLENDMODE": 5], "only the combo the user chose is overridden")
    }

    // MARK: - project.json properties (sidebar)

    func testSliderPropertyParsesWEFields() {
        let definition = UserPropertyDefinition(key: "snow", raw: [
            "type": "slider", "text": "ui_browse_properties_snow", "order": 104, "value": 0.1,
            "min": 0, "max": 1, "step": 0.010000000000000002, "precision": 3, "fraction": true,
            "condition": "enabled.value == true"
        ])
        XCTAssertEqual(definition.type, "slider")
        XCTAssertEqual(definition.order, 104)
        XCTAssertEqual(definition.defaultValue, "0.1")
        XCTAssertEqual(definition.minimum, 0)
        XCTAssertEqual(definition.maximum, 1)
        XCTAssertEqual(definition.step, 0.01, accuracy: 1e-12)
        XCTAssertEqual(definition.precision, 3)
        XCTAssertEqual(definition.condition, "enabled.value == true")
        XCTAssertEqual(definition.sliderFormat.fractionDigits, 2, "WE saves precision as decimals + 1")
        XCTAssertEqual(definition.sliderFormat.storedString(0.1234), "0.12")
    }

    func testSliderWithoutStepOrRangeUsesWEsDefaults() {
        let definition = UserPropertyDefinition(key: "scale", raw: ["type": "slider", "value": 120, "min": 20, "max": 300, "fraction": false])
        XCTAssertEqual(definition.step, 1, "WE's slider: step: property.step || 1")
        XCTAssertEqual(definition.precision, 1, "precision: property.precision || 1")
        XCTAssertEqual(definition.sliderFormat.fractionDigits, 0)
        XCTAssertEqual(definition.sliderFormat.storedString(120.6), "121")
        let bare = UserPropertyDefinition(key: "bare", raw: ["type": "slider"])
        XCTAssertEqual(bare.minimum, 0, "WE's editor creates sliders as min 0, max 1")
        XCTAssertEqual(bare.maximum, 1)
    }

    func testComboAndTextProperties() {
        let combo = UserPropertyDefinition(key: "mode", raw: [
            "type": "combo", "text": "Mode", "options": [["label": "ui_editor_properties_low", "value": 5], ["label": "High", "value": "13"]]
        ])
        XCTAssertEqual(combo.options, [.init(label: "ui_editor_properties_low", value: "5"), .init(label: "High", value: "13")])
        XCTAssertEqual(combo.defaultValue, "5", "a combo without a value starts at its first option")
        let notice = UserPropertyDefinition(key: "n", raw: ["text": "<b>hi</b>"])
        XCTAssertEqual(notice.type, "text")
        XCTAssertNil(notice.order)
        XCTAssertEqual(UserPropertyDefinition(key: "b", raw: ["type": "bool"]).defaultValue, "false")
    }

    /// Every property of every library wallpaper reads back exactly as authored.
    func testEveryLibraryPropertyIsAuthoredValue() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.libraryRoot.path), "wallpaper library not present")
        var checked = 0
        for id in try FileManager.default.contentsOfDirectory(atPath: Self.libraryRoot.path).sorted() {
            let url = Self.libraryRoot.appending(path: id).appending(path: "project.json")
            guard let data = FileManager.default.contents(atPath: url.path),
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let raw = (root["general"] as? [String: Any])?["properties"] as? [String: [String: Any]] ?? [:]
            for definition in UserPropertyDefinition.all(projectJSON: root) {
                let authored = try XCTUnwrap(raw[definition.key])
                let context = "\(id) \(definition.key)"
                if let min = authored["min"] as? NSNumber { XCTAssertEqual(definition.minimum, min.doubleValue, context) }
                if let max = authored["max"] as? NSNumber { XCTAssertEqual(definition.maximum, max.doubleValue, context) }
                if let step = authored["step"] as? NSNumber { XCTAssertEqual(definition.step, step.doubleValue, context) }
                if let precision = authored["precision"] as? NSNumber { XCTAssertEqual(definition.precision, precision.intValue, context) }
                if let value = authored["value"] { XCTAssertEqual(definition.value, sceneUserPropertyString(value), context) }
                let options = (authored["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
                XCTAssertEqual(definition.options.map(\.label), options, context)
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 0)
    }

    func testLabelsComeFromWEsTable() {
        let labels = WallpaperEngineLabels(strings: ["ui_editor_properties_speed": "Speed"])
        XCTAssertEqual(labels.translation("ui_editor_properties_speed"), "Speed")
        XCTAssertEqual(labels.translation("UI_Editor_Properties_Speed"), "Speed")
        XCTAssertNil(labels.translation("My own label"))
    }

    // MARK: - scene.json general block

    func testGeneralDefaultsAreWEs() throws {
        let scene = try JSONDecoder().decode(WEScene.self, from: Data(#"{"camera":{},"general":{"bloom":true,"cameraparallax":true,"orthogonalprojection":{"width":100,"height":100}},"objects":[]}"#.utf8))
        let context = NoValues()
        let bloom = SceneBloomSettings(scene.general, in: context)
        XCTAssertTrue(bloom.enabled)
        XCTAssertEqual(bloom.strength, 2, "wallpaper64.exe scene settings constructor")
        XCTAssertEqual(bloom.threshold, 0.65, accuracy: 1e-6)
        XCTAssertEqual(bloom.tint, SIMD3<Float>(repeating: 1))
        let camera = SceneCameraEffects(scene.general, in: context)
        XCTAssertTrue(camera.parallax)
        XCTAssertEqual(camera.parallaxAmount, 0.5)
        XCTAssertEqual(camera.parallaxDelay, 0.1, accuracy: 1e-6)
        XCTAssertEqual(camera.parallaxMouseInfluence, 0.5)
        XCTAssertEqual(camera.shakeSpeed, 3)
        XCTAssertEqual(camera.shakeAmplitude, 0.5)
        XCTAssertEqual(camera.shakeRoughness, 1)
        XCTAssertFalse(bloom.hdr.enabled)
        XCTAssertEqual(bloom.hdr.strength, 2, "wallpaper64.exe 0x1401870c2")
        XCTAssertEqual(bloom.hdr.threshold, 1)
        XCTAssertEqual(bloom.hdr.feather, 0.1, accuracy: 1e-6)
        XCTAssertEqual(bloom.hdr.scatter, 1.619, accuracy: 1e-6)
        XCTAssertEqual(bloom.hdr.iterations, 8)
        let lighting = SceneLightingSettings(scene.general, in: context)
        XCTAssertEqual(lighting.ambient, .zero, "the constructor zeroes the scene colours (0x140186f68)")
        XCTAssertEqual(lighting.skylight, .zero)
        XCTAssertNil(lighting.lightConfig)
    }

    /// A scene that leaves `bloom` out blooms (the constructor's flags 0x26 hold `bloom`'s bit 2):
    /// WE 2.8's captures of generated scenes without it glow, and their solid band (0.2 0.6 1.0)
    /// comes out (51, 255, 255), its bloom added (effect gallery EXTRAS.md item 3).
    func testBloomIsOnWhenTheSceneLeavesItOut() throws {
        let absent = try JSONDecoder().decode(WEScene.self, from: Data(#"{"camera":{},"general":{"orthogonalprojection":{"width":100,"height":100}},"objects":[]}"#.utf8))
        XCTAssertTrue(SceneBloomSettings(absent.general, in: NoValues()).enabled)
        XCTAssertFalse(SceneBloomSettings(absent.general, in: NoValues()).hdr.enabled, "hdr's bit 0x400 starts clear")
        let off = try JSONDecoder().decode(WEScene.self, from: Data(#"{"camera":{},"general":{"bloom":false},"objects":[]}"#.utf8))
        XCTAssertFalse(SceneBloomSettings(off.general, in: NoValues()).enabled)
    }

    func testAuthoredGeneralValuesWin() throws {
        let json = #"{"camera":{},"general":{"bloom":true,"bloomstrength":1.2,"bloomthreshold":0.3,"cameraparallaxamount":0.8,"orthogonalprojection":{"width":100,"height":100}},"objects":[]}"#
        let scene = try JSONDecoder().decode(WEScene.self, from: Data(json.utf8))
        let context = NoValues()
        XCTAssertEqual(SceneBloomSettings(scene.general, in: context).strength, 1.2, accuracy: 1e-6)
        XCTAssertEqual(SceneBloomSettings(scene.general, in: context).threshold, 0.3, accuracy: 1e-6)
        XCTAssertEqual(SceneCameraEffects(scene.general, in: context).parallaxAmount, 0.8, accuracy: 1e-6)
    }

    // MARK: - createScriptProperties

    /// WE's own builder and injection, as the runtime runs them: `createScriptProperties()` from
    /// baseclasses.js, then the scene's `scriptproperties` through `_Internal.updateScriptProperties`.
    private func scriptProperties(_ builder: String, authored: [String: Any]) throws -> JSValue {
        let context = try XCTUnwrap(JSContext())
        let base = try String(contentsOf: ShaderVariantTests.weAssets.appending(path: "scripts/jsclasses/baseclasses.js"), encoding: .utf8)
        context.evaluateScript(base)
        let json = String(decoding: try JSONSerialization.data(withJSONObject: authored), as: UTF8.self)
        context.setObject(json, forKeyedSubscript: "__authored" as NSString)
        let result = try XCTUnwrap(context.evaluateScript("""
            (function () {
                const script = { scriptProperties: createScriptProperties()\(builder).finish() };
                _Internal.updateScriptProperties(script, __authored);
                return script.scriptProperties;
            })()
            """))
        XCTAssertNil(context.exception, "\(String(describing: context.exception))")
        return result
    }

    func testScriptPropertyDefaultsAreWEs() throws {
        _ = try Fixtures.assets()
        let values = try scriptProperties("""
            .addCombo({name:'mode',label:'Mode',options:[{label:'A',value:2},{label:'B',value:3}]})
            .addSlider({name:'speed',label:'Speed',value:0.5,min:0.1,max:4,integer:false})
            .addCheckbox({name:'on',label:'On',value:true})
            .addColor({name:'tint',label:'Tint',value:new Vec3(1,0,0)})
            .addText({name:'text',label:'Text',value:'hi'})
            """, authored: [:])
        XCTAssertEqual(values.forProperty("mode").toInt32(), 2, "a combo starts at its first option, as WE's builder does")
        XCTAssertEqual(values.forProperty("speed").toDouble(), 0.5)
        XCTAssertEqual(values.forProperty("speed_config").forProperty("min").toDouble(), 0.1)
        XCTAssertEqual(values.forProperty("speed_config").forProperty("max").toDouble(), 4)
        XCTAssertTrue(values.forProperty("on").toBool())
        XCTAssertEqual(values.forProperty("text").toString(), "hi")
        XCTAssertEqual(values.forProperty("mode_config").forProperty("mode").toString(), "combo")
    }

    func testSceneScriptPropertiesOverrideDeclaredKeysOnly() throws {
        _ = try Fixtures.assets()
        let values = try scriptProperties("""
            .addCombo({name:'mode',options:[{label:'A',value:2},{label:'B',value:3}]})
            .addColor({name:'tint',value:new Vec3(1,1,1)})
            """, authored: ["mode": 3, "tint": "0 0.5 1", "undeclared": 7])
        XCTAssertEqual(values.forProperty("mode").toInt32(), 3)
        XCTAssertEqual(values.forProperty("tint").forProperty("y").toDouble(), 0.5, "a colour string becomes a Vec3")
        XCTAssertTrue(values.forProperty("undeclared").isUndefined, "WE applies only declared keys")
    }

    // MARK: - Oracle: the annotations read straight from the shader sources

    private struct AnnotatedUniform {
        let key: String
        let declaration: ShaderUniformDeclaration
    }

    /// The effect's shader stages in pass order, as WE's editor walks them.
    private static func sources(effectFile: String, readFile: @escaping (String) -> Data?) throws -> [ShaderSource] {
        let directory = (effectFile as NSString).deletingLastPathComponent
        let scoped: (String) -> Data? = { path in readFile("\(directory)/\(path)") ?? readFile(path) }
        guard let data = readFile(effectFile),
              let effect = try JSONSerialization.jsonObject(with: data, options: [.json5Allowed]) as? [String: Any] else { return [] }
        var result: [ShaderSource] = []
        for pass in effect["passes"] as? [[String: Any]] ?? [] {
            guard let materialPath = pass["material"] as? String, let materialData = scoped(materialPath),
                  let material = try JSONSerialization.jsonObject(with: materialData, options: [.json5Allowed]) as? [String: Any],
                  let shader = (material["passes"] as? [[String: Any]])?.first?["shader"] as? String else { continue }
            let loader = ShaderSourceLoader(readFile: scoped)
            for stage in ShaderStage.allCases {
                if let source = try? loader.load(shader, stage: stage) { result.append(source) } // a stage may be absent
            }
        }
        return result
    }

    /// Uniforms with a `material` key, not hidden, of a type WE's editor shows, first occurrence wins.
    private static func annotatedUniforms(effectFile: String, readFile: @escaping (String) -> Data?) throws -> [AnnotatedUniform] {
        var result: [AnnotatedUniform] = []
        for source in try sources(effectFile: effectFile, readFile: readFile) {
            for uniform in source.uniforms where ["float", "int", "vec2", "vec3", "vec4"].contains(uniform.type) {
                guard let key = uniform.annotation["material"] as? String, uniform.annotation["hidden"] as? Bool != true,
                      !result.contains(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }) else { continue }
                result.append(AnnotatedUniform(key: key, declaration: uniform))
            }
        }
        return result
    }

    /// `[COMBO]` annotations with a `material` key, first occurrence of each combo wins.
    private static func annotatedCombos(effectFile: String, readFile: @escaping (String) -> Data?) throws -> [[String: Any]] {
        var result: [[String: Any]] = []
        var seen = Set<String>()
        let pattern = try NSRegularExpression(pattern: #"//\s*\[COMBO\]\s*(\{[^\n]*\})"#)
        for source in try sources(effectFile: effectFile, readFile: readFile) {
            let text = source.text
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let raw = String(text[Range(match.range(at: 1), in: text)!])
                guard let json = try JSONSerialization.jsonObject(with: Data(raw.utf8), options: [.json5Allowed]) as? [String: Any],
                      json["material"] is String, let name = json["combo"] as? String,
                      seen.insert(name.uppercased()).inserted else { continue }
                result.append(json)
            }
        }
        return result
    }
}

private struct NoValues: SceneValueContext {
    func userProperty(_ name: String) -> String? { nil }
}
