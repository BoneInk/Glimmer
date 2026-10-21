import CoreGraphics

/// One split of a display, or of a region of a split display, into two regions that each show
/// their own wallpaper: WE's `profile.splits[<location>] = {direction, position}`. A display's
/// regions are named as WE names them, its location then `/L` (left or top) and `/R` (right or
/// bottom), nested: `<display>/L/R` is the right half of the left half.
struct DisplaySplit: Codable, Hashable {
    /// WE's values: 0 is its "Vertical" (a vertical divider, side by side), 1 its "Horizontal"
    /// (a horizontal divider, one above the other).
    enum Direction: Int, Codable, CaseIterable, Hashable {
        case vertical = 0
        case horizontal = 1
    }

    var direction: Direction
    /// Where the divider sits, 0…1 of the width (vertical) or the height (horizontal), from the
    /// left or the top.
    var position: Double

    init(direction: Direction = .vertical, position: Double = 0.5) {
        self.direction = direction
        self.position = position
    }

    /// The suffix of a split's first region (left or top) and second (right or bottom).
    static let first = "/L"
    static let second = "/R"

    /// WE's limit, the only one it puts on splits (there is no depth limit): the divider stays at
    /// least one whole point inside the region, `1…extent - 1`, so each side keeps a point.
    /// Nil when the region is under two points along the split, too small to split.
    static func clampedPosition(_ position: Double, extent: CGFloat) -> Double? {
        let extent = Double(extent.rounded(.down))
        guard extent >= 2 else { return nil }
        let points = (position.isFinite ? position : 0.5) * extent
        return min(max(points.rounded(), 1), extent - 1) / extent
    }
}

/// The regions a display's splits divide it into (WE's `monitorSplits`).
enum DisplaySplitLayout {
    /// A region that shows its own wallpaper: its path below the display (`/L/R`) and its rect in
    /// global desktop points (AppKit's, origin bottom-left).
    struct Region: Equatable {
        let path: String
        let rect: CGRect
    }

    /// The leaf regions of a display of `frame`, split as `splits` (keyed by path below the
    /// display, `""` the display itself) says, first regions first. One region, the display, when
    /// it isn't split. Each side is whole points, so regions meet without a seam.
    static func regions(of frame: CGRect, splits: [String: DisplaySplit]) -> [Region] {
        var regions: [Region] = []
        func visit(_ path: String, _ rect: CGRect) {
            guard let split = splits[path] else {
                regions.append(Region(path: path, rect: rect))
                return
            }
            let (first, second) = divide(rect, by: split)
            visit(path + DisplaySplit.first, first)
            visit(path + DisplaySplit.second, second)
        }
        visit("", frame)
        return regions
    }

    /// `rect` divided by `split` into its first (left or top) and second region.
    static func divide(_ rect: CGRect, by split: DisplaySplit) -> (CGRect, CGRect) {
        let position = CGFloat(min(max(split.position, 0), 1))
        switch split.direction {
        case .vertical:
            let width = (rect.width * position).rounded()
            return (CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height),
                    CGRect(x: rect.minX + width, y: rect.minY, width: rect.width - width, height: rect.height))
        case .horizontal:
            // AppKit's y runs up: the top region is the upper one.
            let height = (rect.height * position).rounded()
            return (CGRect(x: rect.minX, y: rect.maxY - height, width: rect.width, height: height),
                    CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - height))
        }
    }

    /// The rect of the region at `path` (a leaf or a split one) of a display of `frame`; nil when
    /// the splits have no such region.
    static func rect(of path: String, in frame: CGRect, splits: [String: DisplaySplit]) -> CGRect? {
        var rect = frame
        var current = ""
        var rest = Substring(path)
        while !rest.isEmpty {
            guard let split = splits[current] else { return nil }
            let (first, second) = divide(rect, by: split)
            if rest.hasPrefix(DisplaySplit.first) {
                rect = first
                current += DisplaySplit.first
            } else if rest.hasPrefix(DisplaySplit.second) {
                rect = second
                current += DisplaySplit.second
            } else {
                return nil
            }
            rest = rest.dropFirst(DisplaySplit.first.count)
        }
        return rect
    }
}
