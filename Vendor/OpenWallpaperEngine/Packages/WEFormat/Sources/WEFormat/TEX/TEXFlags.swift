import Foundation

/// The `flags` word of a `.tex` file's `TEXI` header: how WE samples the texture.
public struct TEXFlags: OptionSet, Equatable {
    public let rawValue: UInt32

    /// Nearest filtering instead of bilinear.
    public static let noInterpolation = TEXFlags(rawValue: 1)
    /// Clamp to the edge instead of repeating.
    public static let clampUVs = TEXFlags(rawValue: 2)
    /// The texture is a sprite sheet (a `.tex-json` describes its frames).
    public static let sprite = TEXFlags(rawValue: 4)
    /// The texture's one mipmap is an MP4 (library video textures such as 3802509485's
    /// `bg_2560x1600_nobars.tex` and 3315123651's: flags 34, FreeImage format -1).
    public static let video = TEXFlags(rawValue: 32)

    /// Reads the flags from a `.tex` file (`TEXV0005\0TEXI0001\0`, format, flags…). Nil when the
    /// data isn't a `.tex`.
    public init?(texData data: Data) {
        // The format word comes first, then the flags.
        guard let word = TEXHeader.texiWord(1, in: data) else { return nil }
        rawValue = word
    }

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }
}
