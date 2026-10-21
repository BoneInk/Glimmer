import Foundation

/// The Android Export mode's custom screen: width × height in pixels, each side 320…8192.
enum AndroidCustomSize {
    static let sides = 320...8192
    static let defaultSize = SIMD2(1080, 2400)

    enum Issue: Error, Equatable {
        case notANumber, tooSmall, tooLarge

        var message: String {
            switch self {
            case .notANumber: return String(localized: "Enter the width and height in pixels.")
            case .tooSmall: return String(localized: "Each side needs at least \(AndroidCustomSize.sides.lowerBound.formatted(.number.grouping(.never))) pixels.")
            case .tooLarge: return String(localized: "Each side can have at most \(AndroidCustomSize.sides.upperBound.formatted(.number.grouping(.never))) pixels.")
            }
        }
    }

    /// The size the two fields give, or why they don't give one.
    static func validate(width: String, height: String) -> Result<SIMD2<Int>, Issue> {
        let numbers = [width, height].map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard let w = numbers[0], let h = numbers[1] else { return .failure(.notANumber) }
        if w < sides.lowerBound || h < sides.lowerBound { return .failure(.tooSmall) }
        if w > sides.upperBound || h > sides.upperBound { return .failure(.tooLarge) }
        return .success(SIMD2(w, h))
    }

    /// The aspect as a ratio: "9:20" when it reduces to small whole numbers, else the long side
    /// over the short one ("1:2.17", "2.17:1").
    static func aspectText(_ size: SIMD2<Int>) -> String {
        guard size.x > 0, size.y > 0 else { return "" }
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
        let divisor = gcd(size.x, size.y)
        let (w, h) = (size.x / divisor, size.y / divisor)
        if max(w, h) <= 64 { return "\(w):\(h)" }
        let ratio = (Double(max(size.x, size.y)) / Double(min(size.x, size.y))).formatted(.number.precision(.fractionLength(0...2)))
        return size.x <= size.y ? "1:\(ratio)" : "\(ratio):1"
    }
}

/// The video's size: the screen's own pixels, or WE's Full HD or 4K UHD presets (the short side
/// 1080 or 2160) at the screen's aspect. Even sides, as H.264's 4:2:0 needs.
enum AndroidVideoSize: String, CaseIterable, Identifiable {
    case screen
    case fullHD = "full_hd"
    case uhd4K = "uhd_4k"

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .screen: return LocalizedStringResource("Screen Resolution", comment: "Android Export: the video is made at the device's own pixels")
        case .fullHD: return LocalizedStringResource("Full HD")
        case .uhd4K: return LocalizedStringResource("4K UHD")
        }
    }

    /// The video's pixels for a screen of `screen` pixels.
    func pixels(for screen: SIMD2<Int>) -> SIMD2<Int> {
        let short = Double(max(min(screen.x, screen.y), 1))
        let scale: Double
        switch self {
        case .screen: scale = 1
        case .fullHD: scale = 1080 / short
        case .uhd4K: scale = 2160 / short
        }
        func even(_ value: Int) -> Int { max(2, Int((Double(value) * scale / 2).rounded()) * 2) }
        return SIMD2(even(screen.x), even(screen.y))
    }
}
