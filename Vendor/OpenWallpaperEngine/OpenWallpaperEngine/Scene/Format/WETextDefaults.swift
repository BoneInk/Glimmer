import Foundation

/// What `wallpaper64.exe` assumes for a text object's fields that scene.json leaves out: its text
/// object constructor (0x140256ae0…0x140256d15), matched to the fields by the property table at
/// 0x140259190…0x14025a1a0 (each name's offset). These are the parser's values, not the editor's
/// new-layer template (which writes "Text Layer", Arial, `msdf` and so on into the object).
enum WETextDefaults {
    /// `pointsize` (+0x4e0).
    static let pointSize: Double = 32
    /// `padding` (+0x4e8), both axes.
    static let padding: Float = 32
    /// `spacing` (+0x4f8).
    static let spacing = SIMD2<Float>(0, 0)
    /// `maxwidth` (+0x508) and `maxrows` (+0x510), used once `limitwidth` / `limitrows` are on.
    static let maxWidth: Double = 500
    static let maxRows = 1
    /// `outlinethickness` (+0x520), `outlinecolor` (+0x524): black.
    static let outlineThickness: Float = 4
    static let outlineColor = SIMD3<Float>(0, 0, 0)
    /// `blursize` (+0x530).
    static let blurSize: Float = 6
    /// `dropshadowsize` (+0x534), `dropshadowopacity` (+0x538), `dropshadowoffset` (+0x53c),
    /// `dropshadowcolor` (+0x544): black.
    static let dropShadowSize: Float = 6
    static let dropShadowOpacity: Float = 1
    static let dropShadowOffset = SIMD2<Float>(4, 4)
    static let dropShadowColor = SIMD3<Float>(0, 0, 0)
    /// `horizontalalign` and `verticalalign` (+0x59c, +0x59e): centre.
    static let alignment = "center"
}
