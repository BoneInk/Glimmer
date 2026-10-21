import Foundation

/// How a playlist's wallpaper duration (stored in seconds) is stepped and shown.
enum PlaylistDurationFormat {
    static let range: ClosedRange<Double> = 5...3600

    /// 5 s steps below a minute, 15 s steps from a minute on, clamped to `range`.
    static func snapped(_ seconds: Double) -> Double {
        let step: Double = seconds < 60 ? 5 : 15
        let value = (seconds / step).rounded() * step
        return min(max(value, range.lowerBound), range.upperBound)
    }

    /// The duration in the locale's narrow units, with a zero part dropped: "45s", "1m", "1m 15s",
    /// "1h" in English; "45秒", "1分15秒" in Japanese.
    static func label(_ seconds: Double, locale: Locale = .current) -> String {
        let total = Int64(seconds.rounded())
        return Duration.seconds(total)
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow).locale(locale))
    }
}
