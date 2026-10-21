import XCTest
@testable import OpenWallpaperEngine

/// WE's blend modes: the list, order and labels of WE 2.8.0.42's editor, and the values its shaders
/// branch on (`common_blending.h`).
final class WEImageBlendModesTests: XCTestCase {
    /// The editor's menu, top to bottom (Normal is the default).
    func testTheEditorListsWEsThirtyThreeModesInItsOrder() {
        XCTAssertEqual(WEImageBlendModes.all.map(\.english), [
            "Normal", "Add",
            "Tint", "Darken", "Multiply", "Color burn", "Linear burn", "Darker color", "Lighten", "Screen",
            "Color dodge", "Linear dodge", "Lighter color", "Overlay", "Soft light", "Hard light", "Vivid light",
            "Linear light", "Pin light", "Diffuse light", "Hard mix", "Difference", "Exclusion", "Subtract",
            "Reflect", "Glow", "Phoenix", "Average", "Negation", "Hue", "Saturation", "Color", "Luminosity",
        ])
        XCTAssertEqual(WEImageBlendModes.all.filter(\.isNative).map(\.english), ["Normal", "Add"])
        XCTAssertEqual(WEImageBlendModes.all.first?.value, 0, "Normal, the default, is BLENDMODE 0")
        XCTAssertEqual(Set(WEImageBlendModes.all.map(\.value)), Set(0...32), "every BLENDMODE value once")
    }

    /// Each mode's value selects the `ApplyBlending` branch that computes that mode.
    func testValuesSelectTheirBranchInCommonBlending() throws {
        _ = try Fixtures.assets()
        let source = try String(contentsOf: ShaderVariantTests.weAssets.appending(path: "shaders/common_blending.h"), encoding: .utf8)
        let expected: [String: String] = [
            "Darken": "BlendDarken", "Multiply": "BlendMultiply", "Color burn": "BlendColorBurn",
            "Linear burn": "BlendSubstract", "Darker color": "min(A, B)", "Lighten": "BlendLighten",
            "Screen": "BlendScreen", "Color dodge": "BlendColorDodge", "Linear dodge": "BlendAdd",
            "Lighter color": "max(A, B)", "Overlay": "BlendOverlay", "Soft light": "BlendSoftLight",
            "Hard light": "BlendHardLight", "Vivid light": "BlendVividLight", "Linear light": "BlendLinearLight",
            "Pin light": "BlendPinLight", "Hard mix": "BlendHardMix", "Difference": "BlendDifference",
            "Exclusion": "BlendExclusion", "Subtract": "BlendSubstract", "Reflect": "BlendReflect",
            "Glow": "BlendGlow", "Phoenix": "BlendPhoenix", "Average": "BlendAverage", "Negation": "BlendNegation",
            "Hue": "BlendHue", "Saturation": "BlendSaturation", "Color": "BlendColor", "Luminosity": "BlendLuminosity",
            "Tint": "BlendTint", "Add": "A+B*opacity", "Diffuse light": "A+A*B",
        ]
        for mode in WEImageBlendModes.all where mode.value != 0 {
            let branch = try XCTUnwrap(source.range(of: "#if BLENDMODE == \(mode.value)\\s", options: .regularExpression),
                                       mode.english)
            let body = source[branch.upperBound...].prefix { $0 != "#" }
            let function = try XCTUnwrap(expected[mode.english], mode.english)
            XCTAssertTrue(body.contains(function + (function.hasPrefix("Blend") ? "(" : "")),
                          "\(mode.english) = \(mode.value): \(body)")
        }
    }

    /// The labels are WE's own keys, and the English text is WE's (`locale/ui_en-us.json`, `OWE_ASSETS`).
    func testLabelsAreWEsLocalisationKeysAndText() throws {
        let labels = WallpaperEngineLabels.load(assets: try Fixtures.assets(), languages: ["en"])
        for mode in WEImageBlendModes.all {
            XCTAssertEqual(labels.translation(mode.label), mode.english, mode.label)
        }
        XCTAssertEqual(labels.translation(WEImageBlendModes.nativeGroup.label), WEImageBlendModes.nativeGroup.english)
        XCTAssertEqual(labels.translation(WEImageBlendModes.emulatedGroup.label), WEImageBlendModes.emulatedGroup.english)
    }

    /// A `"type":"imageblending"` combo offers the modes, grouped as the editor groups them.
    func testImageBlendingComboOffersWEsModes() {
        let combo = SceneEffectParameters.combos(in: #"// [COMBO] {"material":"ui_editor_properties_blend_mode","combo":"BLENDMODE","type":"imageblending","default":30}"#).first
        XCTAssertEqual(combo?.defaultValue, 30)
        XCTAssertEqual(combo?.options.map(\.label), WEImageBlendModes.all.map(\.label))
        XCTAssertEqual(combo?.options.first?.group, WEImageBlendModes.nativeGroup.label)
        XCTAssertEqual(combo?.options.last?.group, WEImageBlendModes.emulatedGroup.label)
        XCTAssertEqual(combo?.options.first { $0.value == 30 }?.english, "Tint")
    }
}
