import Foundation

/// The kinds of Android device the Android Export mode frames the wallpaper for.
enum AndroidDeviceKind: String, CaseIterable, Identifiable {
    case phone, foldable, tablet

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .phone: return LocalizedStringResource("Phones", comment: "Android Export: the device list's group of phones")
        case .foldable: return LocalizedStringResource("Foldables", comment: "Android Export: the device list's group of foldable phones")
        case .tablet: return LocalizedStringResource("Tablets", comment: "Android Export: the device list's group of tablets")
        }
    }

    var systemImage: String {
        switch self {
        case .phone: return "smartphone"
        case .foldable: return "rectangle.portrait.split.2x1"
        case .tablet: return "ipad"
        }
    }
}

/// Which screen of a foldable an entry is.
enum AndroidDeviceScreen: String, Equatable {
    /// The inner, unfolded screen.
    case main
    /// The outer screen.
    case cover

    var title: LocalizedStringResource {
        switch self {
        case .main: return LocalizedStringResource("Main Screen", comment: "Android Export: a foldable phone's inner, unfolded screen")
        case .cover: return LocalizedStringResource("Cover Screen", comment: "Android Export: a foldable phone's outer screen")
        }
    }
}

/// A popular Android phone, foldable or tablet the Android Export mode makes its loop for: its
/// maker and name as the maker writes them, its kind, its screen's native pixels in portrait,
/// the year it came out and where the resolution comes from (`source`, the spec page). A
/// foldable has an entry per notable screen. A tablet's home screen also turns to landscape.
struct AndroidDevice: Identifiable, Hashable {
    let brand: String
    let name: String
    let kind: AndroidDeviceKind
    let screen: AndroidDeviceScreen?
    /// The screen in pixels, portrait (width ≤ height, except a foldable's near-square main
    /// screen as its maker lists it).
    let pixelSize: SIMD2<Int>
    let year: Int
    /// The spec page the resolution is taken from.
    let source: String

    var id: String { screen.map { "\(brand) \(name) (\($0.rawValue))" } ?? "\(brand) \(name)" }

    /// The name shown in the list: product names stay as their makers write them, in every language.
    var displayName: String {
        guard let screen else { return "\(brand) \(name)" }
        return "\(brand) \(name) – \(String(localized: screen.title))"
    }

    /// A tablet's screen in landscape.
    var landscapePixelSize: SIMD2<Int>? {
        kind == .tablet ? SIMD2(pixelSize.y, pixelSize.x) : nil
    }

    static func phone(_ brand: String, _ name: String, _ width: Int, _ height: Int, _ year: Int, source: String) -> AndroidDevice {
        AndroidDevice(brand: brand, name: name, kind: .phone, screen: nil, pixelSize: SIMD2(width, height), year: year, source: source)
    }

    static func tablet(_ brand: String, _ name: String, _ width: Int, _ height: Int, _ year: Int, source: String) -> AndroidDevice {
        AndroidDevice(brand: brand, name: name, kind: .tablet, screen: nil, pixelSize: SIMD2(width, height), year: year, source: source)
    }

    static func foldable(_ brand: String, _ name: String, _ screen: AndroidDeviceScreen, _ width: Int, _ height: Int, _ year: Int,
                         source: String) -> AndroidDevice {
        AndroidDevice(brand: brand, name: name, kind: .foldable, screen: screen, pixelSize: SIMD2(width, height), year: year,
                      source: source)
    }

    /// Every device, by kind (phones, foldables, tablets), then newest first, then by maker in
    /// the table's order.
    static let all: [AndroidDevice] = {
        let order = Dictionary(table.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let kinds = Dictionary(uniqueKeysWithValues: AndroidDeviceKind.allCases.enumerated().map { ($0.element, $0.offset) })
        return table.sorted { lhs, rhs in
            let left = (kinds[lhs.kind] ?? 0, -lhs.year, order[lhs.id] ?? 0)
            let right = (kinds[rhs.kind] ?? 0, -rhs.year, order[rhs.id] ?? 0)
            return left < right
        }
    }()

    /// The device `id` names, else the default.
    static func device(id: String?) -> AndroidDevice? {
        all.first { $0.id == id }
    }

    /// The newest phone with the most pixels.
    static var defaultDevice: AndroidDevice {
        let phones = all.filter { $0.kind == .phone }
        let year = phones.map(\.year).max() ?? 0
        return phones.filter { $0.year == year }.max { $0.pixelSize.x * $0.pixelSize.y < $1.pixelSize.x * $1.pixelSize.y }!
    }
}
