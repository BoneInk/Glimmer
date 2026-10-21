import AppKit

/// The face a text layer is set in when its font can't be found: Arial, as WE falls back to
/// `arial.ttf` when a face fails to load (0x1401ad549, `SceneFontResolver`). macOS ships Arial; a
/// system without it gets the system font, logged once.
enum SceneTextFallbackFont {
    static let postScriptName = "ArialMT"

    /// Read once: whether Arial is installed (logged when it isn't).
    private static let arialInstalled: Bool = {
        let installed = NSFont(name: postScriptName, size: 12) != nil
        if !installed { OWELog.error(.scene, "Text: Arial (WE's fallback font) isn't installed; missing fonts use the system font") }
        return installed
    }()

    static func font(size: CGFloat) -> NSFont {
        (arialInstalled ? NSFont(name: postScriptName, size: size) : nil) ?? NSFont.systemFont(ofSize: size)
    }
}
