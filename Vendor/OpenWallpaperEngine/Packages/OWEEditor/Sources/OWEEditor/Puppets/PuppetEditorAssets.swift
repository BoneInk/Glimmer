import CoreGraphics
import Foundation
import OWEInspectorKit
import OWESceneEditing

/// The puppet editor's text, from its own table (`Resources/Puppets.xcstrings`), in every
/// language the app ships.
let PL = EditorText(table: "Puppets")

/// What the puppet editor reads of the wallpaper, from the app: its files (from its package or
/// folder) and an image layer's picture, decoded as the renderer decodes it.
public struct PuppetEditorAssets {
    /// A file of the wallpaper by its path (`models/foo.json`); nil when it has none.
    public var readFile: (String) -> Data?
    /// The picture an image layer's model draws (its material's first texture), by the model's path.
    public var image: (String) -> CGImage?
    /// Saves a painted clipping mask (a PNG) with the edits; returns its texture path (`masks/…`).
    public var saveMask: ((Data) throws -> String)?
    /// A texture's picture by its path (`masks/…`), for painting over a clipping mask.
    public var texture: ((String) -> CGImage?)?

    public init(readFile: @escaping (String) -> Data?, image: @escaping (String) -> CGImage?,
                saveMask: ((Data) throws -> String)? = nil, texture: ((String) -> CGImage?)? = nil) {
        self.readFile = readFile
        self.image = image
        self.saveMask = saveMask
        self.texture = texture
    }
}

extension WallpaperEditorServices {
    /// `puppetAssets` with the edit's asset store for painted clipping masks.
    var puppetEditorAssets: PuppetEditorAssets? {
        guard var assets = puppetAssets else { return nil }
        if assets.saveMask == nil, let store = assetStore {
            assets.saveMask = { try store.saveMask($0, title: "clipping_mask") }
        }
        if assets.texture == nil { assets.texture = texture }
        return assets
    }
}

extension PuppetImage {
    /// The picture as 8-bit premultiplied RGBA, top row first.
    init?(_ image: CGImage) {
        let width = image.width, height = image.height
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = [UInt8](repeating: 0, count: 4 * width * height)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: 4 * width, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.init(width: width, height: height, pixels: pixels)
    }

    /// The image as a `CGImage`.
    var cgImage: CGImage? {
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4 * width,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// An image layer's puppet as the wallpaper has it: its model, the rig the model names, the
/// picture and the layer's animation layers.
public struct PuppetSource {
    /// The layer's `image`: its model JSON.
    public var modelPath: String
    /// The model's `material`.
    public var material: String
    /// The model's `puppet`, when it has one.
    public var rigPath: String?
    public var image: CGImage?
    public var texture: PuppetImage?
    /// The picture's size in pixels (the layer's `size` when the picture can't be read).
    public var imageSize: SIMD2<Float>
    /// The rig as the wallpaper has it, with the layer's animation layers.
    public var document: PuppetDocument?
    /// Why the rig couldn't be read.
    public var error: String?

    public static func load(layer: SceneLayer, assets: PuppetEditorAssets) -> PuppetSource? {
        guard let modelPath = layer.fields["image"]?.stringValue else { return nil }
        let model = assets.readFile(modelPath).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let image = assets.image(modelPath)
        let size = SceneVector.components(layer.fields["size"].flatMap { SceneFieldBinding.literal(of: $0) })
        var imageSize = SIMD2<Float>(Float(size.first ?? 512), Float(size.count > 1 ? size[1] : 512))
        if let image { imageSize = SIMD2(Float(image.width), Float(image.height)) }
        var source = PuppetSource(modelPath: modelPath, material: model["material"] as? String ?? "",
                                  rigPath: model["puppet"] as? String, image: image, texture: image.flatMap(PuppetImage.init),
                                  imageSize: imageSize)
        if let rigPath = source.rigPath {
            do {
                guard let data = assets.readFile(rigPath) else {
                    throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: rigPath])
                }
                var document = try PuppetMDLReader.read(data, imageSize: imageSize, sourcePath: rigPath)
                applyEditorJSON(to: &document, rigPath: rigPath, assets: assets)
                if case .array(let layers)? = layer.fields["animationlayers"] {
                    document.layers = layers.enumerated().compactMap { PuppetAnimationLayer(json: $0.element, fallbackID: $0.offset + 1) }
                }
                source.document = document
            } catch {
                source.error = error.localizedDescription
            }
        }
        return source
    }

    /// The mask names WE's editor keeps in the rig's JSON beside the `.mdl` (`puppet.clippingmasks`).
    static func applyEditorJSON(to document: inout PuppetDocument, rigPath: String, assets: PuppetEditorAssets) {
        guard var clipping = document.clipping,
              let data = assets.readFile((rigPath as NSString).deletingPathExtension + ".json"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], // optional editor file
              let masks = (json["puppet"] as? [String: Any])?["clippingmasks"] as? [[String: Any]] else { return }
        for entry in masks {
            guard let id = (entry["id"] as? NSNumber)?.uint64Value, let name = entry["name"] as? String, !name.isEmpty,
                  let index = clipping.masks.firstIndex(where: { $0.id == id }) else { continue }
            clipping.masks[index].name = name
        }
        document.clipping = clipping
    }
}
