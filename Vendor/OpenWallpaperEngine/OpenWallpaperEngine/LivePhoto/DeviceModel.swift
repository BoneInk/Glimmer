import Foundation

/// The kinds of device a Live Photo lock screen is made for.
enum DeviceFamily: String, CaseIterable, Identifiable {
    case iPhone, iPad

    var id: String { rawValue }

    /// Product names stay as Apple writes them, in every language.
    var name: String { rawValue }

    var systemImage: String {
        switch self {
        case .iPhone: return "iphone"
        case .iPad: return "ipad"
        }
    }
}

/// An iPhone or iPad a Live Photo lock-screen wallpaper is made for: its name as Apple writes
/// it, its family, its screen's native pixels in portrait and the year it came out.
///
/// `all` lists every model whose system shows a Live Photo on the lock screen (iOS 17 and later
/// on iPhone, iPadOS 17 and later on iPad), newest first. The sizes are Apple's published native
/// resolutions. An iPad's lock screen also turns to landscape; the wallpaper is the same picture,
/// which the iPad crops to fill the wider screen.
struct DeviceModel: Identifiable, Hashable {
    let name: String
    let family: DeviceFamily
    /// The screen in pixels, portrait.
    let pixelSize: SIMD2<Int>
    let year: Int

    var id: String { name }

    /// The screen in pixels, landscape: iPads only, whose lock screen rotates.
    var landscapePixelSize: SIMD2<Int>? {
        family == .iPad ? SIMD2(pixelSize.y, pixelSize.x) : nil
    }

    /// The model `id` names, else the default.
    static func model(id: String?) -> DeviceModel {
        all.first { $0.id == id } ?? defaultModel
    }

    /// The newest iPhone with the most pixels.
    static var defaultModel: DeviceModel {
        let newest = all.filter { $0.family == .iPhone }
        let year = newest.map(\.year).max() ?? 0
        return newest.filter { $0.year == year }.max { $0.pixelSize.x * $0.pixelSize.y < $1.pixelSize.x * $1.pixelSize.y }!
    }

    // MARK: The table

    private static func iPhone(_ name: String, _ width: Int, _ height: Int, _ year: Int) -> DeviceModel {
        DeviceModel(name: name, family: .iPhone, pixelSize: SIMD2(width, height), year: year)
    }

    private static func iPad(_ name: String, _ width: Int, _ height: Int, _ year: Int) -> DeviceModel {
        DeviceModel(name: name, family: .iPad, pixelSize: SIMD2(width, height), year: year)
    }

    /// Every model, newest first (within a year, as Apple lists them).
    static let all: [DeviceModel] = (iPhones + iPads).enumerated()
        .sorted { ($0.element.year, -$0.offset) > ($1.element.year, -$1.offset) }
        .map(\.element)

    /// iOS 17 and later: iPhone XS, XR and SE (2nd generation) onwards.
    private static let iPhones: [DeviceModel] = [
        iPhone("iPhone 17 Pro Max", 1320, 2868, 2025),
        iPhone("iPhone 17 Pro", 1206, 2622, 2025),
        iPhone("iPhone Air", 1260, 2736, 2025),
        iPhone("iPhone 17", 1206, 2622, 2025),
        iPhone("iPhone 16e", 1170, 2532, 2025),
        iPhone("iPhone 16 Pro Max", 1320, 2868, 2024),
        iPhone("iPhone 16 Pro", 1206, 2622, 2024),
        iPhone("iPhone 16 Plus", 1290, 2796, 2024),
        iPhone("iPhone 16", 1179, 2556, 2024),
        iPhone("iPhone 15 Pro Max", 1290, 2796, 2023),
        iPhone("iPhone 15 Pro", 1179, 2556, 2023),
        iPhone("iPhone 15 Plus", 1290, 2796, 2023),
        iPhone("iPhone 15", 1179, 2556, 2023),
        iPhone("iPhone 14 Pro Max", 1290, 2796, 2022),
        iPhone("iPhone 14 Pro", 1179, 2556, 2022),
        iPhone("iPhone 14 Plus", 1284, 2778, 2022),
        iPhone("iPhone 14", 1170, 2532, 2022),
        iPhone("iPhone SE (3rd generation)", 750, 1334, 2022),
        iPhone("iPhone 13 Pro Max", 1284, 2778, 2021),
        iPhone("iPhone 13 Pro", 1170, 2532, 2021),
        iPhone("iPhone 13", 1170, 2532, 2021),
        iPhone("iPhone 13 mini", 1080, 2340, 2021),
        iPhone("iPhone 12 Pro Max", 1284, 2778, 2020),
        iPhone("iPhone 12 Pro", 1170, 2532, 2020),
        iPhone("iPhone 12", 1170, 2532, 2020),
        iPhone("iPhone 12 mini", 1080, 2340, 2020),
        iPhone("iPhone SE (2nd generation)", 750, 1334, 2020),
        iPhone("iPhone 11 Pro Max", 1242, 2688, 2019),
        iPhone("iPhone 11 Pro", 1125, 2436, 2019),
        iPhone("iPhone 11", 828, 1792, 2019),
        iPhone("iPhone XS Max", 1242, 2688, 2018),
        iPhone("iPhone XS", 1125, 2436, 2018),
        iPhone("iPhone XR", 828, 1792, 2018),
    ]

    /// iPadOS 17 and later: iPad (6th generation), iPad mini (5th generation), iPad Air (3rd
    /// generation), iPad Pro 10.5-inch and 12.9-inch (2nd generation) onwards.
    private static let iPads: [DeviceModel] = [
        iPad("iPad Pro 13-inch (M5)", 2064, 2752, 2025),
        iPad("iPad Pro 11-inch (M5)", 1668, 2420, 2025),
        iPad("iPad Air 13-inch (M3)", 2048, 2732, 2025),
        iPad("iPad Air 11-inch (M3)", 1640, 2360, 2025),
        iPad("iPad (A16)", 1640, 2360, 2025),
        iPad("iPad Pro 13-inch (M4)", 2064, 2752, 2024),
        iPad("iPad Pro 11-inch (M4)", 1668, 2420, 2024),
        iPad("iPad Air 13-inch (M2)", 2048, 2732, 2024),
        iPad("iPad Air 11-inch (M2)", 1640, 2360, 2024),
        iPad("iPad mini (A17 Pro)", 1488, 2266, 2024),
        iPad("iPad Pro 12.9-inch (6th generation)", 2048, 2732, 2022),
        iPad("iPad Pro 11-inch (4th generation)", 1668, 2388, 2022),
        iPad("iPad Air (5th generation)", 1640, 2360, 2022),
        iPad("iPad (10th generation)", 1640, 2360, 2022),
        iPad("iPad Pro 12.9-inch (5th generation)", 2048, 2732, 2021),
        iPad("iPad Pro 11-inch (3rd generation)", 1668, 2388, 2021),
        iPad("iPad mini (6th generation)", 1488, 2266, 2021),
        iPad("iPad (9th generation)", 1620, 2160, 2021),
        iPad("iPad Pro 12.9-inch (4th generation)", 2048, 2732, 2020),
        iPad("iPad Pro 11-inch (2nd generation)", 1668, 2388, 2020),
        iPad("iPad Air (4th generation)", 1640, 2360, 2020),
        iPad("iPad (8th generation)", 1620, 2160, 2020),
        iPad("iPad Air (3rd generation)", 1668, 2224, 2019),
        iPad("iPad mini (5th generation)", 1536, 2048, 2019),
        iPad("iPad (7th generation)", 1620, 2160, 2019),
        iPad("iPad Pro 12.9-inch (3rd generation)", 2048, 2732, 2018),
        iPad("iPad Pro 11-inch (1st generation)", 1668, 2388, 2018),
        iPad("iPad (6th generation)", 1536, 2048, 2018),
        iPad("iPad Pro 12.9-inch (2nd generation)", 2048, 2732, 2017),
        iPad("iPad Pro 10.5-inch", 1668, 2224, 2017),
    ]
}

/// The device combo box's search: what the user types narrows the table, and the matches are
/// listed by family.
enum DeviceModelSearch {
    /// The models `query` matches, in table order. Every word of the query has to match the
    /// name, the family, the year or the resolution ("1320", "1320x2868", "1320 × 2868"); an
    /// empty query matches everything.
    static func filter(_ models: [DeviceModel], query: String) -> [DeviceModel] {
        let words = Self.words(in: query)
        guard !words.isEmpty else { return models }
        return models.filter { model in words.allSatisfy { matches(model, word: $0) } }
    }

    /// `models` by family (iPhone first), each family keeping its order; empty families left out.
    static func groups(_ models: [DeviceModel]) -> [DeviceModelGroup] {
        DeviceFamily.allCases.compactMap { family -> DeviceModelGroup? in
            let members = models.filter { $0.family == family }
            return members.isEmpty ? nil : DeviceModelGroup(family: family, models: members)
        }
    }

    /// Lowercased words, a resolution's "×" or "x" between two numbers kept as one word.
    static func words(in query: String) -> [String] {
        let normalized = query.lowercased()
            .replacingOccurrences(of: "×", with: "x")
            .replacingOccurrences(of: #"(\d)\s*x\s*(\d)"#, with: "$1x$2", options: .regularExpression)
        return normalized.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
    }

    private static func matches(_ model: DeviceModel, word: String) -> Bool {
        let portrait = "\(model.pixelSize.x)x\(model.pixelSize.y)"
        let landscape = "\(model.pixelSize.y)x\(model.pixelSize.x)"
        let fields = [model.name.lowercased(), model.family.name.lowercased(), String(model.year), portrait, landscape]
        return fields.contains { $0.contains(word) }
    }
}

/// One family's models in the combo box's list.
struct DeviceModelGroup: Identifiable, Equatable {
    let family: DeviceFamily
    let models: [DeviceModel]

    var id: DeviceFamily { family }
}
