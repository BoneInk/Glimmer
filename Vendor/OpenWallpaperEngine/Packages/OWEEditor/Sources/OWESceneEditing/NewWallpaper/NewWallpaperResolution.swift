import Foundation

/// A size a new scene wallpaper can be made at: Wallpaper Engine's Workshop resolution tags
/// (`ui_workshop_tags_*`), in its groups, which its New Scene Wallpaper page offers to resize an
/// image to (`getResizeRecommendationsFromFile`, "Resize resolution").
public struct NewWallpaperResolution: Hashable, Sendable, Identifiable {
    public enum Group: String, CaseIterable, Sendable {
        case widescreen, ultrawide, dual, triple, portrait
    }

    public var width: Int
    public var height: Int
    public var group: Group

    public var id: String { "\(width)x\(height)" }
    public var aspect: Double { Double(width) / Double(height) }

    public init(width: Int, height: Int, group: Group) {
        self.width = width
        self.height = height
        self.group = group
    }

    /// WE's tags, by group, smallest first.
    public static let all: [NewWallpaperResolution] = [
        .init(width: 1280, height: 720, group: .widescreen), .init(width: 1366, height: 768, group: .widescreen),
        .init(width: 1920, height: 1080, group: .widescreen), .init(width: 2560, height: 1440, group: .widescreen),
        .init(width: 3840, height: 2160, group: .widescreen), .init(width: 7680, height: 4320, group: .widescreen),
        .init(width: 2560, height: 1080, group: .ultrawide), .init(width: 3440, height: 1440, group: .ultrawide),
        .init(width: 3840, height: 1080, group: .dual), .init(width: 5120, height: 1440, group: .dual),
        .init(width: 7680, height: 2160, group: .dual),
        .init(width: 4096, height: 768, group: .triple), .init(width: 5760, height: 1080, group: .triple),
        .init(width: 7680, height: 1440, group: .triple), .init(width: 11520, height: 2160, group: .triple),
        .init(width: 720, height: 1280, group: .portrait), .init(width: 1080, height: 1920, group: .portrait),
        .init(width: 1440, height: 2560, group: .portrait), .init(width: 2160, height: 3840, group: .portrait),
    ]

    /// What the page suggests for an image of `width` × `height`.
    public struct Recommendation: Equatable, Sendable {
        /// The sizes of the image's group, the recommended one first.
        public var options: [NewWallpaperResolution]
        /// The image isn't one of the tags' sizes: resizing is suggested (WE's resize alert).
        public var suggestsResize: Bool
        /// The image is taller than wide: most of it is cut off on a landscape display.
        public var isPortrait: Bool
    }

    /// The group whose shape is nearest the image's, its sizes with the largest one the image
    /// fills without being enlarged first (else the smallest), and whether to suggest a resize.
    public static func recommendation(width: Int, height: Int) -> Recommendation {
        guard width > 0, height > 0 else { return Recommendation(options: [], suggestsResize: false, isPortrait: false) }
        let aspect = Double(width) / Double(height)
        let groups = Dictionary(grouping: all, by: \.group)
        let nearest = Group.allCases.min { first, second in
            func distance(_ group: Group) -> Double {
                groups[group]!.map { abs(log($0.aspect / aspect)) }.min()!
            }
            return distance(first) < distance(second)
        }!
        let sizes = groups[nearest]!
        let fitting = sizes.filter { $0.width <= width && $0.height <= height }
        let recommended = fitting.max { $0.width * $0.height < $1.width * $1.height } ?? sizes[0]
        let options = [recommended] + sizes.filter { $0 != recommended }
        let isTag = all.contains { $0.width == width && $0.height == height }
        return Recommendation(options: options, suggestsResize: !isTag, isPortrait: height > width)
    }
}
