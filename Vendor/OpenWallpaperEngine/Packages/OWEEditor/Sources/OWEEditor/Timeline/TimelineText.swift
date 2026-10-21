import Foundation
import OWEInspectorKit
import OWESceneEditing

/// The timeline's text, from its own catalog (`Resources/Timeline.xcstrings`), in every language
/// the app ships. Whole numbers in it are interpolated as `number`.
let T = EditorText(table: "Timeline")

extension TimelineEase {
    var title: String {
        switch self {
        case .linear: return T("Linear")
        case .easeInOut: return T("Ease In and Out")
        case .easeIn: return T("Ease In")
        case .easeOut: return T("Ease Out")
        case .hold: return T("Hold")
        }
    }
}

extension TimelineClip.Mode {
    var title: String {
        switch self {
        case .loop: return T("Loop")
        case .mirror: return T("Mirror")
        case .single: return T("Single")
        }
    }
}

enum TimelineNames {
    /// A layer field as the inspector names it; other keys as scene.json spells them.
    static func field(_ key: String) -> String {
        switch key {
        case "origin": return T("Position")
        case "scale": return T("Scale")
        case "angles": return T("Rotation")
        case "size": return T("Size")
        case "alpha": return T("Opacity")
        case "color": return T("Color")
        case "brightness": return T("Brightness")
        case "parallaxDepth": return T("Parallax Depth")
        case "volume": return T("Volume")
        default: return key
        }
    }

    /// A channel's short name: R G B for a colour, else X Y Z W.
    static func channel(_ channel: Int, of target: TimelineTarget) -> String {
        let colour = target.key == "color" || target.key.lowercased().contains("color") || target.key.lowercased().contains("colour")
        let names = colour ? ["R", "G", "B", "A"] : ["X", "Y", "Z", "W"]
        return channel < names.count ? names[channel] : String(channel)
    }

    /// The property's name: an effect constant with its effect's.
    static func property(_ target: TimelineTarget, outline: SceneOutline) -> String {
        guard let effect = target.effect else { return field(target.key) }
        let title = outline.layer(target.layer)?.effects.first { $0.id == effect }?.title ?? ""
        return title.isEmpty ? target.key : "\(title) · \(target.key)"
    }

    /// The property with its layer's name, for a list of every layer's tracks.
    static func track(_ target: TimelineTarget, outline: SceneOutline, withLayer: Bool) -> String {
        let property = property(target, outline: outline)
        guard withLayer, let layer = outline.layer(target.layer) else { return property }
        return "\(layer.title) · \(property)"
    }

    /// `m:ss.cc`, the playhead's time.
    static func time(_ seconds: Double) -> String {
        let clamped = max(seconds, 0)
        let minutes = Int(clamped / 60)
        return String(format: "%d:%05.2f", minutes, clamped - Double(minutes) * 60)
    }
}
