import Foundation

extension SceneMetalText {
    /// The configuration with what scripts set on the layer this frame (`ITextLayer`,
    /// lib.sceneScript.d.ts): `font`, `anchor`, `padding` (pixels, both axes), the alignments, and
    /// `maxwidth` / `limitwidth`, `maxrows` / `limitrows`, `opaquebackground` and `backgroundcolor`. WE keeps these as the text object's
    /// own fields (the property table at wallpaper64.exe 0x140258d80…0x14025a1a0) and lays the text
    /// out again when any of them changes (0x140256fe0…0x1402570e2 compares each with its last
    /// value), so a script's write reaches the drawn text the frame it lands. A field scripts left
    /// alone keeps its authored value.
    func scripted(by object: SceneScriptObjectState) -> SceneMetalText {
        var text = self
        if let alignment = object.strings[.horizontalalign] { text.horizontalAlignment = alignment }
        if let alignment = object.strings[.verticalalign] { text.verticalAlignment = alignment }
        // An empty path is no font: Arial, as WE's fallback is.
        if let font = object.strings[.font] { text.font = font.isEmpty ? nil : font }
        if let anchor = object.strings[.anchor] { text.anchor = anchor }
        if let padding = object.scalar(.padding), padding.isFinite { text.padding = SIMD2(repeating: padding) }
        if let width = object.scalar(.maxwidth), width.isFinite { text.maxWidthValue = width }
        if let rows = object.scalar(.maxrows), rows.isFinite {
            text.maxRowsValue = Int(SceneTimelineDocument.asInt(Double(rows)))
        }
        let limitsWidth = object.scalar(.limitwidth).map { $0 != 0 } ?? (maxWidth != nil)
        let limitsRows = object.scalar(.limitrows).map { $0 != 0 } ?? (maxRows != nil)
        text.maxWidth = limitsWidth ? text.maxWidthValue : nil
        text.maxRows = limitsRows ? text.maxRowsValue : nil
        if let opaque = object.scalar(.opaquebackground) { text.opaqueBackground = opaque != 0 }
        if let color = object.vector3(.backgroundcolor), all(color .== color) { text.backgroundColor = color }
        return text
    }
}
