import Foundation

extension SceneLayer {
    /// What an image object draws, by the model WE's editor gives each kind of layer
    /// (`models/util/*.json` in WE's assets).
    public enum ImageRole: String, Sendable {
        /// An image from a texture.
        case picture
        /// `models/util/solidlayer.json`: a fill of its `color`.
        case solid
        /// `models/util/composelayer.json`: the scene under its rectangle, for its effects.
        case composition
        /// `models/util/fullscreenlayer.json`: the whole scene so far, for its effects.
        case fullscreen
        /// `models/util/projectlayer.json`.
        case project
    }

    /// Nil for a layer that isn't an image.
    public var imageRole: ImageRole? {
        guard kind == .image, let image = fields["image"]?.stringValue?.lowercased() else { return nil }
        if image.hasPrefix("models/util/solidlayer") { return .solid }
        if image.hasPrefix("models/util/composelayer") { return .composition }
        if image.hasPrefix("models/util/fullscreenlayer") { return .fullscreen }
        if image.hasPrefix("models/util/projectlayer") { return .project }
        return .picture
    }

    /// The layer covers the scene whatever its transform: the canvas has no rectangle to grab.
    public var fillsScene: Bool { imageRole == .fullscreen }

    /// Its own text, when it is a text layer: the `value` (a script's starting value).
    public var textValue: String? {
        guard kind == .text, let text = fields["text"] else { return nil }
        return text.stringValue ?? text["value"]?.stringValue
    }

    /// The SceneScript that writes its text each frame (a clock), if any.
    public var textScript: String? { fields["text"]?["script"]?.stringValue }
}

extension SceneLayer {
    /// The SF Symbol the layer lists show: the kind's, or a solid, composition or fullscreen
    /// layer's own.
    public var listSymbol: String {
        switch imageRole {
        case .solid?: return "square.fill"
        case .composition?: return "square.on.square.dashed"
        case .fullscreen?: return "rectangle.inset.filled"
        default: return kind.symbol
        }
    }
}
