import CoreGraphics
import Foundation

/// What WE's image importer lets the author choose for a texture (its import dialog,
/// `material.config`; the texture-format page of WE's docs, `en_scene_performance_texture`):
/// the format, Pixel Art Optimization (`nointerpolation`), No Mip Maps (`nomip`), Clamp UVs
/// (`clampuvs`), Crop transparent area (`croptransparent` with `croppadding`), a normal map, and
/// an image sequence's frame duration (`imageListDuration`). WE's defaults: RGBA 8888, mipmapped,
/// bilinear, clamped, uncropped.
public struct TextureImportOptions: Hashable, Sendable {
    /// WE's import formats, in its dialog's order.
    public enum Format: String, CaseIterable, Sendable {
        /// "High Quality - Uncompressed (RGBA 8888)", WE's default.
        case rgba8888
        /// "Good Performance - Minor Compression (DXT5)".
        case dxt5
        /// "High Performance - Medium Compression (DXT1)": no alpha beyond one bit.
        case dxt1
        /// "High Quality - Uncompressed Dual Channel (RG 88)".
        case rg88
        /// "High Quality - Uncompressed Single Channel (R 8)".
        case r8

        /// The `.tex` header's format word (the shaders' `FORMAT_*`).
        public var texFormat: UInt32 {
            switch self {
            case .rgba8888: return 0
            case .dxt5: return 4
            case .dxt1: return 7
            case .rg88: return 8
            case .r8: return 9
            }
        }
    }

    public var format: Format = .rgba8888
    /// Nearest filtering (`TEXFlags` bit 0).
    public var pixelArt = false
    /// Only the full-size image, no smaller copies.
    public var noMipmaps = false
    /// Clamp to the edge instead of repeating (`TEXFlags` bit 1).
    public var clampUVs = true
    /// Crop the image to its non-transparent pixels, `cropPadding` pixels around them kept.
    public var cropTransparency = false
    public var cropPadding = 0
    /// A normal map for the image, imported beside it (WE's `rg88n`) as its material's second texture.
    public var normalMap: URL?
    /// Seconds each image of an imported sequence shows.
    public var frameDuration = 0.1

    public init() {}

    /// The texture is what a PNG or JPEG gives the renderer as it is: WE's RGBA 8888 picture,
    /// bilinear, mipmapped and clamped, so the file is kept rather than rewritten as a `.tex`.
    public var keepsPicture: Bool { format == .rgba8888 && !pixelArt && !noMipmaps && clampUVs }

    /// The `.tex` flags these options give (`TEXFlags`): point filtering, clamping, a sprite sheet.
    public func texFlags(spriteSheet: Bool = false) -> UInt32 {
        (pixelArt ? 1 : 0) | (clampUVs ? 2 : 0) | (spriteSheet ? 4 : 0)
    }
}

/// One image of an animated texture and how long it shows.
public struct TextureImportFrame: @unchecked Sendable {
    public var image: CGImage
    public var duration: Double

    public init(image: CGImage, duration: Double) {
        self.image = image
        self.duration = duration
    }
}

/// Writes WE's `.tex` files for the importer; the app's `.tex` writer (`EditorTEXEncoder`).
public protocol EditorTextureEncoding: Sendable {
    /// A still image in the options' format, flags and mipmaps.
    func texture(_ image: CGImage, options: TextureImportOptions) throws -> Data
    /// A normal map as WE imports one (`rg88n`: its red and green, clamped, mipmapped).
    func normalMap(_ image: CGImage) throws -> Data
    /// The frames as one sprite sheet with its frame table (`TEXS0003`); returns the sheet's size.
    func spriteSheet(_ frames: [TextureImportFrame], options: TextureImportOptions) throws -> (data: Data, size: SIMD2<Double>)
    /// An MP4 as a video texture (WE 2.2's video image layer); returns the video's size.
    func video(_ url: URL) throws -> (data: Data, size: SIMD2<Double>)
    /// `base` (a `.tex`, or a PNG or JPEG) with texture variants compiled in (`TextureVariantDocument`).
    func texture(_ base: Data, withVariants options: [TextureVariantInput]) throws -> Data
    /// What the texture `data` lets its variants be.
    func variantBase(_ data: Data) -> TextureVariantBase?
}

/// One option of a texture's variants as the `.tex` writer takes it (`TextureVariantDocument.compiledOptions`).
public struct TextureVariantInput: Sendable {
    public var group: UInt32
    public var id: UInt32
    public var alphaBlend: Bool
    /// The option record's condition JSON (`TextureVariantDocument.Condition.compiledJSON`); `{}`
    /// for an option without one, which is never on.
    public var condition: String
    /// The option's image or video file.
    public var file: Data

    public init(group: UInt32, id: UInt32, alphaBlend: Bool, condition: String, file: Data) {
        self.group = group
        self.id = id
        self.alphaBlend = alphaBlend
        self.condition = condition
        self.file = file
    }
}

/// What a texture lets its variants be: its picture's size, whether it is a video, whether an
/// option can be alpha-blended (WE's `variantallowcomplexblend`: RGBA8888), whether the `.tex`
/// already has variants compiled in.
public struct TextureVariantBase: Hashable, Sendable {
    public var width: Int
    public var height: Int
    public var isVideo: Bool
    public var allowsAlphaBlend: Bool
    public var hasCompiledVariants: Bool

    public init(width: Int, height: Int, isVideo: Bool, allowsAlphaBlend: Bool, hasCompiledVariants: Bool) {
        self.width = width
        self.height = height
        self.isVideo = isVideo
        self.allowsAlphaBlend = allowsAlphaBlend
        self.hasCompiledVariants = hasCompiledVariants
    }
}

/// Why a texture's variants can't be written.
public enum TextureVariantError: Error, Equatable, LocalizedError {
    /// An option's file isn't of the texture's size and kind (WE's "Incompatible Variant Option").
    case incompatible(optionID: UInt32)
    /// Alpha blending in a texture that isn't RGBA8888.
    case alphaBlendUnsupported(optionID: UInt32)
    /// The texture's format or kind can't take variants written here.
    case unsupportedTexture
    /// An option's file or the base texture can't be read.
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .incompatible:
            return "The image or video you selected is not compatible with this texture. It must have the same resolution and needs to be the same type, you cannot mix images and videos in a texture."
        case .alphaBlendUnsupported: return "Only uncompressed RGBA 8888 textures can be alpha blended."
        case .unsupportedTexture: return "This texture’s format can’t have variants."
        case .unreadable(let name): return "“\(name)” can’t be read."
        }
    }
}

extension EditorTextureEncoding {
    /// `base` (a `.tex`, or a PNG or JPEG) with the options compiled in as WE's loader reads them.
    public func texture(_ base: Data, withVariants options: [TextureVariantInput]) throws -> Data {
        throw TextureVariantError.unsupportedTexture
    }

    /// What the texture `data` lets its variants be; nil when it can't be read.
    public func variantBase(_ data: Data) -> TextureVariantBase? { nil }
}
