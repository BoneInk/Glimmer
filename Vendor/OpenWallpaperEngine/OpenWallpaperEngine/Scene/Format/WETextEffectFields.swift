import Foundation
import OWESceneEditing

/// A text object's font-effect fields as scene.json authors them: the `outline`, `blur` and
/// `dropshadow` switches with their sizes and colours (and `msdf`, which only chooses WE's
/// glyph atlas). A field left out takes WE's constructor value (`WETextDefaults`).
struct WETextEffectFields: Decodable, Equatable {
    var msdf: Bool?
    var outline: Bool?
    var outlineThickness: Double?
    var outlineColor: String?
    var blur: Bool?
    var blurSize: Double?
    var dropShadow: Bool?
    var dropShadowSize: Double?
    var dropShadowOpacity: Double?
    var dropShadowOffset: String?
    var dropShadowColor: String?

    enum CodingKeys: String, CodingKey {
        case msdf, outline, blur
        case outlineThickness = "outlinethickness", outlineColor = "outlinecolor", blurSize = "blursize"
        case dropShadow = "dropshadow", dropShadowSize = "dropshadowsize", dropShadowOpacity = "dropshadowopacity"
        case dropShadowOffset = "dropshadowoffset", dropShadowColor = "dropshadowcolor"
    }

    init() {}

    /// Each field on its own: one that is missing or not a literal of its type is left out.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Optional: a field another type of value (a user binding) keeps WE's default.
        msdf = try? c.decodeIfPresent(Bool.self, forKey: .msdf)
        outline = try? c.decodeIfPresent(Bool.self, forKey: .outline)
        outlineThickness = try? c.decodeIfPresent(Double.self, forKey: .outlineThickness)
        outlineColor = try? c.decodeIfPresent(String.self, forKey: .outlineColor)
        blur = try? c.decodeIfPresent(Bool.self, forKey: .blur)
        blurSize = try? c.decodeIfPresent(Double.self, forKey: .blurSize)
        dropShadow = try? c.decodeIfPresent(Bool.self, forKey: .dropShadow)
        dropShadowSize = try? c.decodeIfPresent(Double.self, forKey: .dropShadowSize)
        dropShadowOpacity = try? c.decodeIfPresent(Double.self, forKey: .dropShadowOpacity)
        dropShadowOffset = try? c.decodeIfPresent(String.self, forKey: .dropShadowOffset)
        dropShadowColor = try? c.decodeIfPresent(String.self, forKey: .dropShadowColor)
    }

    /// The effects that are switched on, with WE's defaults for their absent values; nil for none.
    var effects: SceneTextEffects? {
        var effects = SceneTextEffects()
        if outline == true {
            effects.outline = .init(thickness: outlineThickness.map(Float.init) ?? WETextDefaults.outlineThickness,
                                    color: Self.vector3(outlineColor) ?? WETextDefaults.outlineColor)
        }
        if blur == true { effects.blur = blurSize.map(Float.init) ?? WETextDefaults.blurSize }
        if dropShadow == true {
            effects.dropShadow = .init(size: dropShadowSize.map(Float.init) ?? WETextDefaults.dropShadowSize,
                                       opacity: dropShadowOpacity.map(Float.init) ?? WETextDefaults.dropShadowOpacity,
                                       offset: Self.vector2(dropShadowOffset) ?? WETextDefaults.dropShadowOffset,
                                       color: Self.vector3(dropShadowColor) ?? WETextDefaults.dropShadowColor)
        }
        return effects.isEmpty ? nil : effects
    }

    private static func numbers(_ text: String?) -> [Float]? {
        guard let text else { return nil }
        let values = SceneVector.floats(text)
        return values.isEmpty ? nil : values
    }

    private static func vector3(_ text: String?) -> SIMD3<Float>? {
        guard let values = numbers(text) else { return nil }
        return values.count >= 3 ? SIMD3(values[0], values[1], values[2]) : SIMD3(repeating: values[0])
    }

    private static func vector2(_ text: String?) -> SIMD2<Float>? {
        guard let values = numbers(text) else { return nil }
        return values.count >= 2 ? SIMD2(values[0], values[1]) : SIMD2(repeating: values[0])
    }
}
