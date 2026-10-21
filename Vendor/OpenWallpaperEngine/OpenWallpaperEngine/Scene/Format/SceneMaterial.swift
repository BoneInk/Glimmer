import Foundation
import OWESceneEditing

struct WEModel: Codable {
    var autosize: Bool?
    /// Util models (fullscreenlayer): the layer covers the whole scene.
    var fullscreen: Bool?
    /// Util models (composelayer, projectlayer): the layer's image is the scene beneath it.
    var passthrough: Bool?
    /// Util models (solidlayer): the material has no texture; the layer is a flat `color` quad.
    var solidlayer: Bool?
    var material: String?    // path to material JSON
    var puppet: String?      // path to a Puppet Warp rig (.mdl): its mesh draws the image (`ScenePuppetPlan`)
    /// The image's size, in scene units, in models without `autosize` (WE's templates: `width` and
    /// `height` beside the material). An object without a `size` takes it rather than its first
    /// texture's, which a material such as `flowimage` fills with a small flow mask.
    var width: Double?
    var height: Double?

    /// `width` × `height` when both are positive.
    var declaredSize: SIMD2<Float>? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return SIMD2(Float(width), Float(height))
    }
}

/// The first pass of an image layer's or particle system's own material, as the layer builder
/// reads it. Decoded as leniently as WE's loader and `MaterialDocument`: a pass, constant or field
/// that doesn't parse is logged and left unset instead of dropping the whole material (and with it
/// the layer).
struct WEMaterial: Decodable {
    var passes: [WEMaterialPass]?

    enum CodingKeys: String, CodingKey { case passes }

    init(passes: [WEMaterialPass]? = nil) { self.passes = passes }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        passes = c.decodeElements(WEMaterialPass.self, forKey: .passes, userInfo: decoder.userInfo)
    }
}

struct WEMaterialPass: Decodable {
    var blending: String?    // "translucent", "additive"
    var shader: String?
    /// Texture slots in order; a `null` slot is unset (the shader's default), kept so indices stay
    /// aligned with the shader's samplers.
    var textures: [String?]?
    var cullmode: String?
    var depthtest: String?
    var depthwrite: String?
    /// Scalar view of the constants: numbers, numeric strings, a vector string's first component,
    /// bools as 1/0, and `{"value", "script"}` objects.
    var constants: [String: WEScriptValue]?
    /// Run-time textures bound to slots (`SceneSystemTexture`), kept raw.
    var usertextures: SceneJSON?

    enum CodingKeys: String, CodingKey {
        case blending, shader, textures, cullmode, depthtest, depthwrite, constants, constantshadervalues, usertextures
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let info = decoder.userInfo
        blending = c.decodeLogged(String.self, forKey: .blending, userInfo: info)
        shader = c.decodeLogged(String.self, forKey: .shader, userInfo: info)
        textures = c.decodeElements(String?.self, forKey: .textures, userInfo: info)
        cullmode = c.decodeLogged(String.self, forKey: .cullmode, userInfo: info)
        depthtest = c.decodeLogged(String.self, forKey: .depthtest, userInfo: info)
        depthwrite = c.decodeLogged(String.self, forKey: .depthwrite, userInfo: info)
        let raw = c.decodeEntries(SceneRawValue.self, forKey: .constants, userInfo: info)
            ?? c.decodeEntries(SceneRawValue.self, forKey: .constantshadervalues, userInfo: info)
        constants = raw?.mapValues(Self.scalar)
        usertextures = c.decodeLogged(SceneJSON.self, forKey: .usertextures, userInfo: info)
    }

    /// `raw` as a scalar constant: a vector string gives its first component, as a float uniform
    /// reads one.
    static func scalar(_ raw: SceneRawValue) -> WEScriptValue {
        switch raw {
        case .number(let number): return WEScriptValue(script: nil, value: number)
        case .bool(let flag): return WEScriptValue(script: nil, value: flag ? 1 : 0)
        case .string(let text): return WEScriptValue(script: nil, value: firstNumber(text))
        case .object(let object):
            let value = object.value.map(scalar)?.value
            return WEScriptValue(script: object.script, value: value)
        }
    }

    private static func firstNumber(_ text: String) -> Double? {
        SceneVector.tokens(text, separatedBy: .whitespaceAndCommas).first.flatMap { Double($0) }
    }
}

// MARK: - Particle System
