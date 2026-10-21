import Foundation

/// An image layer's texture variants as the editor authors them: read from the `.tex-json`
/// beside the layer's texture (`TextureVariantDocument`), and written as WE's resource compiler
/// writes them: the `.tex` with the options compiled in (the encoder's
/// `texture(_:withVariants:)`) and its `.tex-json`, both in the edits' files and named by their
/// content, set as the layer's picture through a copy of its material and model, so the
/// wallpaper's own files never change and Undo puts the old `image` back.
public struct TextureVariantState: Equatable {
    /// The layer's material and model.
    public var material: ImageLayerMaterial
    /// The variants as authored; for a texture without any, an empty document over it.
    public var document: TextureVariantDocument
    /// The base texture's size and kind; nil when it can't be read.
    public var base: TextureVariantBase?
    /// The base is a texture the editor imported: its picture (PNG, JPEG) is in the wallpaper or
    /// the edits, or the editor wrote its `.tex`. WE's editor takes variants only on a texture it
    /// imported (capture 540: a `.tex` made elsewhere rejects every option as incompatible), as its
    /// compiler builds them from the picture.
    public var isImported: Bool

    public static func == (lhs: TextureVariantState, rhs: TextureVariantState) -> Bool {
        lhs.material.modelPath == rhs.material.modelPath && lhs.material.materialPath == rhs.material.materialPath
            && lhs.document == rhs.document && lhs.base == rhs.base && lhs.isImported == rhs.isImported
    }
}

extension SceneEditSession {
    /// The layer's variants; nil for a layer that isn't a picture with a texture of its own.
    public func textureVariants(of layerID: Int, store: EditorAssetStore?, readFile: (String) -> Data?) -> TextureVariantState? {
        guard let layer = outline.layer(layerID), let material = ImageLayerMaterial(layer: layer, readFile: readFile),
              let texture = material.texture else { return nil }
        let authored = readFile(TextureVariantDocument.sidecarPath(of: texture))
            .flatMap { TextureVariantDocument(json: $0, texture: texture) }
        let document = authored ?? TextureVariantDocument(source: texture)
        let baseData = Self.variantBaseFile(document.source, store: store, readFile: readFile)?.data
        let base = baseData.flatMap { store?.encoder?.variantBase($0) }
        return TextureVariantState(material: material, document: document, base: base, isImported: baseData != nil)
    }

    /// Writes `document` as the layer's variants; one undo step. An option's file that isn't of
    /// the texture's size and kind throws `TextureVariantError.incompatible`, and nothing changes.
    public func applyTextureVariants(_ document: TextureVariantDocument, to layerID: Int, store: EditorAssetStore,
                                     readFile: (String) -> Data?, actionName: String) throws {
        guard let model = try preparedTextureVariants(document, for: layerID, store: store, readFile: readFile) else { return }
        edit(actionName: actionName) { overlay in overlay.setField("image", to: .string(model), of: layerID) }
    }

    /// Writes the files of `document` for the layer and returns the model the layer's `image`
    /// becomes (nil when it stays), for an edit that changes more in the same undo step.
    public func preparedTextureVariants(_ document: TextureVariantDocument, for layerID: Int, store: EditorAssetStore,
                                        readFile: (String) -> Data?) throws -> String? {
        guard let layer = outline.layer(layerID), let material = ImageLayerMaterial(layer: layer, readFile: readFile),
              material.texture != nil else { throw ImageToolError.noPicture }
        let texture: String
        if document.groups.isEmpty {
            // No variants left: the base texture as it was.
            texture = document.source
        } else {
            guard let encoder = store.encoder else {
                throw EditorAssetStore.ImportError.needsEncoder(ImageLayerMaterial.baseName(of: document.source))
            }
            guard let base = Self.variantBaseFile(document.source, store: store, readFile: readFile) else {
                throw TextureVariantError.unreadable(ImageLayerMaterial.baseName(of: document.source))
            }
            var inputs: [TextureVariantInput] = []
            for (group, id, option) in document.compiledOptions {
                guard let file = readFile(option.file) else { throw TextureVariantError.unreadable(option.name) }
                inputs.append(TextureVariantInput(group: group, id: id, alphaBlend: option.blend == .alphaBlend,
                                                  condition: option.condition?.compiledJSON ?? "{}", file: file))
            }
            let compiled = try encoder.texture(base.data, withVariants: inputs)
            texture = try store.writeTextureVariants(compiled, document: document)
        }
        guard texture != material.texture else { return nil }
        return try store.writeLayerMaterial(material.materialWithTexture(texture), basedOn: material)
    }

    /// The file variants are compiled over: the texture's picture (`materials/<name>.png`, `.jpg`),
    /// as WE compiles a `.tex-json` from the picture beside it, else a `.tex` the editor imported
    /// (in the edits' files); nil for a texture only compiled elsewhere.
    public static func variantBaseFile(_ name: String, store: EditorAssetStore?,
                                       readFile: (String) -> Data?) -> (path: String, data: Data)? {
        for ext in ["png", "jpg", "jpeg"] {
            let path = "materials/\(name).\(ext)"
            if let data = readFile(path) { return (path, data) }
        }
        let path = "materials/\(name).tex"
        guard store?.url(for: path) != nil, let data = readFile(path) else { return nil }
        return (path, data)
    }
}

extension EditorAssetStore {
    /// Image files an option can be made from besides the kept ones (converted to PNG).
    public static let variantImageTypes: Set<String> = ["png", "jpg", "jpeg", "gif", "bmp", "tga", "tif", "tiff", "webp", "heic"]

    /// Keeps an option's image or video in the edits' files (`materials/editor/variants/<name>.<ext>`);
    /// returns its scene path, the option's `file`.
    public func importVariantFile(from url: URL) throws -> String {
        let title = url.deletingPathExtension().lastPathComponent
        let fileExtension = url.pathExtension.lowercased()
        let data: Data, kept: String
        if Self.videoTypes.contains(fileExtension) {
            guard let movie = try? Data(contentsOf: url) else { throw ImportError.unreadable(url.lastPathComponent) }
            data = movie
            kept = fileExtension
        } else {
            (data, kept, _) = try Self.textureData(from: url)
        }
        let path = "materials/editor/variants/\(Self.assetName(title, data: data)).\(kept)"
        try write(data, to: path)
        return path
    }

    /// Writes a compiled `.tex` and its `.tex-json` (`materials/editor/<name>.tex`, named by both);
    /// returns its texture path (`editor/<name>`).
    public func writeTextureVariants(_ texture: Data, document: TextureVariantDocument) throws -> String {
        let sidecar = document.json
        var named = texture
        named.append(sidecar)
        let name = Self.assetName(ImageLayerMaterial.baseName(of: document.source), data: named)
        try write(texture, to: "materials/editor/\(name).tex")
        try write(sidecar, to: TextureVariantDocument.sidecarPath(of: "editor/\(name)"))
        return "editor/\(name)"
    }
}
