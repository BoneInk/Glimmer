import Foundation

/// An sRGB colour with components in 0…1: a wallpaper's scheme colour, or the colour derived from
/// its snapshot.
public struct ThemeColor: Equatable, Hashable, Codable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = Self.clamped(red)
        self.green = Self.clamped(green)
        self.blue = Self.clamped(blue)
    }

    /// WE's colour string, `general.properties.schemecolor` and every `color` user property:
    /// three numbers separated by spaces, "0.69 0.27 0.33". WE writes 0…1; a string whose numbers
    /// go above 1 is read as 0…255, as some hand-written projects have it. Nil when it isn't three
    /// numbers.
    public init?(weString: String) {
        let parts = weString.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\t" })
        let numbers = parts.compactMap { Double($0) }
        guard numbers.count >= 3, numbers.count == parts.count, numbers.prefix(3).allSatisfy(\.isFinite) else {
            return nil
        }
        let scale: Double = numbers.prefix(3).contains { $0 > 1 } ? 255 : 1
        self.init(red: numbers[0] / scale, green: numbers[1] / scale, blue: numbers[2] / scale)
    }

    /// "r g b" with six decimals, as macOS stores colours in its preferences.
    public var componentString: String {
        String(format: "%f %f %f", locale: Locale(identifier: "en_US_POSIX"), red, green, blue)
    }

    /// The colour moved `amount` (0…1) of the way to `other`, in sRGB.
    public func mixed(with other: ThemeColor, amount: Double) -> ThemeColor {
        let t = Self.clamped(amount)
        return ThemeColor(red: red + (other.red - red) * t,
                          green: green + (other.green - green) * t,
                          blue: blue + (other.blue - blue) * t)
    }

    public static let white = ThemeColor(red: 1, green: 1, blue: 1)

    private static func clamped(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 0
    }
}
