import Foundation

/// A colour in Björn Ottosson's OKLab space, where straight-line distance follows perceived
/// difference, so the nearest palette entry is the one that looks closest.
public struct OKLab: Equatable, Sendable {
    public var lightness: Double
    public var a: Double
    public var b: Double

    public init(lightness: Double, a: Double, b: Double) {
        self.lightness = lightness
        self.a = a
        self.b = b
    }

    /// `color` (sRGB, gamma encoded) in OKLab.
    public init(_ color: ThemeColor) {
        let r = Self.linear(color.red), g = Self.linear(color.green), bl = Self.linear(color.blue)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * bl)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * bl)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * bl)
        lightness = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        b = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
    }

    /// Chroma: how far from grey.
    public var chroma: Double { (a * a + b * b).squareRoot() }

    /// The hue angle in radians.
    public var hue: Double { atan2(b, a) }

    /// The colour of `lightness`, `chroma` and `hue` (OKLCH).
    public init(lightness: Double, chroma: Double, hue: Double) {
        self.init(lightness: lightness, a: chroma * cos(hue), b: chroma * sin(hue))
    }

    /// The sRGB components (gamma encoded), unclamped: outside 0…1 when out of gamut.
    public var rgb: (red: Double, green: Double, blue: Double) {
        let l = pow(lightness + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(lightness - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(lightness - 0.0894841775 * a - 1.2914855480 * b, 3)
        let r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
        let g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
        let bl = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        return (Self.encoded(r), Self.encoded(g), Self.encoded(bl))
    }

    /// Whether the colour is inside sRGB.
    public var isInSRGBGamut: Bool {
        let tolerance = 1e-6
        let (r, g, b) = rgb
        return [r, g, b].allSatisfy { $0 >= -tolerance && $0 <= 1 + tolerance }
    }

    /// The sRGB colour, clamped to the gamut.
    public var themeColor: ThemeColor {
        let (r, g, b) = rgb
        return ThemeColor(red: r, green: g, blue: b)
    }

    public func distance(to other: OKLab) -> Double {
        let dl = lightness - other.lightness, da = a - other.a, db = b - other.b
        return (dl * dl + da * da + db * db).squareRoot()
    }

    private static func encoded(_ value: Double) -> Double {
        let magnitude = abs(value)
        let encoded = magnitude <= 0.0031308 ? magnitude * 12.92 : 1.055 * pow(magnitude, 1 / 2.4) - 0.055
        return value < 0 ? -encoded : encoded
    }

    private static func linear(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
}
