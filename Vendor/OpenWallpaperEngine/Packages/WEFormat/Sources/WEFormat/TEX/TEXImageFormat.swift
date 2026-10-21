import Foundation

/// The `format` word of a `.tex` file's `TEXI` header. Its values are the shaders' `FORMAT_*`
/// constants (`common_fragment.h`), which WE passes to a shader as `TEX<n>FORMAT`.
public struct TEXImageFormat: RawRepresentable, Equatable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// Reads the format from a `.tex` file. Nil when the data isn't a `.tex`.
    public init?(texData data: Data) {
        guard let word = TEXHeader.texiWord(0, in: data) else { return nil }
        rawValue = word
    }

    /// Two 8-bit channels (`FORMAT_RG88`), loaded as (r, g, 0, 1) like the GPU samples them.
    public static let rg88 = TEXImageFormat(rawValue: 8)

    /// One 8-bit channel (`FORMAT_R8`), loaded as (r, 0, 0, 1) like the GPU samples it.
    public static let r8 = TEXImageFormat(rawValue: 9)

    /// Loaded with fewer channels than RGBA, as the GPU samples them (`rg88`, `r8`): a shader
    /// that reads them as colour converts them by `TEX<n>FORMAT`.
    public var isChannelReduced: Bool { self == .rg88 || self == .r8 }

    /// Block-compressed formats (ETC, DXT, BC7): the GPU samples them exactly as stored, so a
    /// shader may rely on their channel layout. RG88 and R8 load as they sample too
    /// (`isChannelReduced`); the other formats are expanded to RGBA on load (`TEXParser`), and
    /// shaders must see them as `FORMAT_RGBA8888`.
    public var isBlockCompressed: Bool {
        (3...7).contains(rawValue) || rawValue == 12
    }

    /// The `TEX<n>FORMAT` a shader sees for a texture of this format: the format itself where the
    /// texture loads as stored (`isChannelReduced`, `isBlockCompressed`), else `FORMAT_RGBA8888`
    /// (0), the RGBA it is expanded to.
    public var formatComboValue: Int { isChannelReduced || isBlockCompressed ? Int(rawValue) : 0 }
}
