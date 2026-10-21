import CoreGraphics
import Foundation
import OWEInspectorKit
import OWESceneEditing

/// The depth map section's text, from its own catalog (`Resources/DepthMaps.xcstrings`).
let DL = EditorText(table: "DepthMaps")

/// What a depth map is generated from: the picture of a layer or of the scene so far.
public struct DepthMapSourceRequest: Sendable {
    public enum Target: Hashable, Sendable {
        /// A layer's own picture: an image layer's texture when it is a still one, else the
        /// layer as drawn.
        case layer(Int)
        /// The scene as drawn up to and including the layer (a particle system), or the whole
        /// scene for nil.
        case scene(upTo: Int?)
    }

    public var target: Target
    /// The edits to draw the scene with (the editor's current overlay).
    public var overlay: SceneEditOverlay
    /// The layers drawn; nil draws every layer.
    public var drawnLayers: Set<Int>?
    /// Every layer of the scene (to hide the others).
    public var allLayers: [Int]
    /// The area to cut out, in scene units from the scene's bottom-left; nil keeps the whole frame.
    public var sceneRect: CGRect?
    /// The scene's size in scene units; nil for a 3D scene.
    public var sceneSize: SIMD2<Double>?
    /// An image layer.s model (`models/…json`) when it draws a picture: its texture may serve as
    /// it is.
    public var pictureModel: String?

    public init(target: Target, overlay: SceneEditOverlay, drawnLayers: Set<Int>?, allLayers: [Int],
                sceneRect: CGRect?, sceneSize: SIMD2<Double>?, pictureModel: String? = nil) {
        self.target = target
        self.overlay = overlay
        self.drawnLayers = drawnLayers
        self.allLayers = allLayers
        self.sceneRect = sceneRect
        self.sceneSize = sceneSize
        self.pictureModel = pictureModel
    }
}

/// The picture a depth map is made from.
public struct DepthMapSource {
    public var image: CGImage
    /// Rendered at one still moment (an animated or particle layer, the scene): the depth map
    /// follows that frame, not the animation.
    public var isOneFrame: Bool

    public init(image: CGImage, isOneFrame: Bool) {
        self.image = image
        self.isOneFrame = isOneFrame
    }
}

/// What the depth map sections need from the app, in either editor: the shared generator, the
/// pictures to generate from, where depth maps are kept, and WE's depth parallax effect.
public struct DepthMapEditorServices {
    /// The process's generator (one model, released when idle).
    public var generator: DepthMapGenerator
    /// Where depth maps go (the overlay's own files, `EditorAssetStore`).
    public var assetStore: EditorAssetStore
    /// Renders or reads the picture for a request, off the main thread where it can.
    public var source: @MainActor (DepthMapSourceRequest) async throws -> DepthMapSource
    /// Copies WE's depth parallax effect files into the project's edit files, as adding any
    /// built-in effect does; throws when WE's assets aren't there.
    public var prepareEffect: @MainActor () throws -> Void
    /// A texture as a picture (a depth map already bound), for the preview.
    public var texture: @MainActor (String) -> CGImage?
    /// Opens Settings › Plugins.
    public var openPlugins: @MainActor () -> Void
    /// An effect's texture slots (`effects/<name>/effect.json`), for the masks a depth map can fill.
    public var effectSchema: @MainActor (String) -> EffectSchema?
    /// Copies a built-in effect's files into the project's edit files, as adding it from the
    /// effect browser does (WE's Opacity effect, which Layer Opacity adds).
    public var prepareBuiltInEffect: @MainActor (EffectCatalogEntry) throws -> Void
    /// A mask's `.tex` file as WE's editor writes one: `width` × `height` grey values, rows top
    /// to bottom (the app's `TEXWriter.effectMask`).
    public var encodeMask: (_ pixels: [UInt8], _ width: Int, _ height: Int) -> Data

    public init(generator: DepthMapGenerator, assetStore: EditorAssetStore,
                source: @escaping @MainActor (DepthMapSourceRequest) async throws -> DepthMapSource,
                prepareEffect: @escaping @MainActor () throws -> Void,
                texture: @escaping @MainActor (String) -> CGImage?,
                openPlugins: @escaping @MainActor () -> Void,
                effectSchema: @escaping @MainActor (String) -> EffectSchema? = { _ in nil },
                prepareBuiltInEffect: @escaping @MainActor (EffectCatalogEntry) throws -> Void = { _ in },
                encodeMask: @escaping (_ pixels: [UInt8], _ width: Int, _ height: Int) -> Data) {
        self.generator = generator
        self.assetStore = assetStore
        self.source = source
        self.prepareEffect = prepareEffect
        self.texture = texture
        self.openPlugins = openPlugins
        self.effectSchema = effectSchema
        self.prepareBuiltInEffect = prepareBuiltInEffect
        self.encodeMask = encodeMask
    }
}

extension SceneEditSession {
    /// The request that generates the depth map for `layerID` (nil: the whole scene), with the
    /// layers drawn and the area cut out as the depth parallax will read it:
    /// - a still image layer's own texture;
    /// - an animated image, a solid or a text layer drawn alone (with its parents and children)
    ///   and cut to its rectangle;
    /// - a composition layer, which shows the scene under it, drawn with what is under it;
    /// - a fullscreen layer and a particle system's layer above it: the scene drawn so far;
    /// - the scene: everything.
    public func depthMapRequest(for layerID: Int?) -> DepthMapSourceRequest {
        let all = outline.layers.map(\.id)
        func upTo(_ id: Int) -> Set<Int> {
            let order = outline.layers.map(\.id)
            let last = subtree(of: id).compactMap { order.firstIndex(of: $0) }.max() ?? 0
            return Set(order.prefix(last + 1))
        }
        guard let layerID, let layer = outline.layer(layerID) else {
            return DepthMapSourceRequest(target: .scene(upTo: nil), overlay: overlay, drawnLayers: nil, allLayers: all,
                                         sceneRect: nil, sceneSize: outline.size)
        }
        if SceneDepthParallax.placement(for: layer) == .layerAbove || layer.fillsScene {
            return DepthMapSourceRequest(target: layer.fillsScene ? .layer(layerID) : .scene(upTo: layerID), overlay: overlay,
                                         drawnLayers: upTo(layerID), allLayers: all, sceneRect: nil, sceneSize: outline.size)
        }
        let drawn: Set<Int>
        if layer.imageRole == .composition {
            drawn = upTo(layerID)
        } else {
            drawn = Set(subtree(of: layerID) + outline.ancestors(of: layerID).map(\.id))
        }
        var rect: CGRect?
        if let corners = geometry(of: layerID)?.corners, !corners.isEmpty {
            let xs = corners.map(\.x), ys = corners.map(\.y)
            rect = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        }
        return DepthMapSourceRequest(target: .layer(layerID), overlay: overlay, drawnLayers: drawn, allLayers: all,
                                     sceneRect: rect, sceneSize: outline.size,
                                     pictureModel: layer.imageRole == .picture ? value("image", of: layerID)?.stringValue : nil)
    }
}
