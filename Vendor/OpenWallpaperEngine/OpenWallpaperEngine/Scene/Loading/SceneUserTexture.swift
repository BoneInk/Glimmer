import AppKit
import Metal

/// WE's texture user property (`scenetexture`, "Bind User Property" on a texture): a
/// `usertextures` entry that is a plain string names the property, whose value is the path of
/// an image or video the user picked. With a file picked, it replaces the slot's texture, scaled
/// to the layer as the authored image was; with none (the property's empty default) the slot
/// keeps its texture. A `{"name", "type": "system"}` entry is a `SceneSystemTexture` instead.
enum SceneUserTexture {
    enum Kind: Equatable {
        case image, video
    }

    /// The property a `usertextures` array binds to `slot`; nil for none, `null` or a system texture.
    static func property(in userTextures: SceneJSON?, slot: Int) -> String? {
        guard case .array(let entries)? = userTextures, slot < entries.count,
              case .string(let name) = entries[slot], !name.isEmpty else { return nil }
        return name
    }

    /// The property bound to `slot` by the first of `userTextures` (most specific first: an
    /// object's `instance`, then its material's pass) whose slot names one.
    static func property(in userTextures: [SceneJSON?], slot: Int) -> String? {
        userTextures.lazy.compactMap { property(in: $0, slot: slot) }.first
    }

    /// The binding recorded for the slot (`UserPropertyBindingTable`): a structural one, so a
    /// newly picked file rebuilds the object.
    static func bindingDocument(property: String) -> SceneJSON {
        .object(["texture": .object(["user": .string(property), "value": .string("")])])
    }

    /// The document name the binding of `slot` of object `owner` is recorded under; it is no file.
    static func documentPath(owner: Int, slot: Int) -> String { "usertextures:\(owner):\(slot)" }

    /// What a picked file is, by its extension (WE's picker offers images and videos); nil for
    /// anything else.
    static func kind(of path: String) -> Kind? {
        switch (path as NSString).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "bmp", "tga", "tif", "tiff", "webp", "heic": return .image
        case "mp4", "m4v", "mov": return .video
        default: return nil
        }
    }
}

extension SceneUserTexture {
    /// The texture of the file at `path` (absolute, or inside the wallpaper's folder): a picture,
    /// or a video that plays (`VideoTextureStream`). Nil, logged, when it can't be read; the slot
    /// then keeps its texture.
    static func source(path: String, wallpaperDir: URL, device: MTLDevice?) -> SceneMetalTextureSource? {
        let url: URL
        if SceneBackendRuntimeContext.isActive {
            guard let contained = AssetPathResolver.fileURL(path, in: wallpaperDir) else {
                SceneBackendRuntimeContext.current?.recordError("user_texture_outside_project")
                return nil
            }
            url = contained
        } else { url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : wallpaperDir.appendingPathComponent(path) }
        switch kind(of: path) {
        case .image?:
            guard let image = NSImage(contentsOf: url), image.isValid else {
                OWELog.error(.scene, "The texture property's picture \(url.path) can't be read; the layer keeps its image")
                return nil
            }
            return .image(image)
        case .video?:
            guard let device, let stream = VideoTextureStream(url: url, device: device) else {
                OWELog.error(.scene, "The texture property's video \(url.path) can't be played; the layer keeps its image")
                return nil
            }
            return .video(stream)
        case nil:
            OWELog.error(.scene, "The texture property names \(url.lastPathComponent), which is neither a picture nor a video")
            return nil
        }
    }
}
