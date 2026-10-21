import Foundation

/// WE's Character Sheet Creation (`finishCharacterSheetCreation` in `wallpaperui.exe`): a cut-out
/// character split into limbs, each limb separated from the picture its parent leaves, and the
/// pieces laid out on one texture for Puppet Warp, named `<texture>_sheet`.
public enum CharacterSheet {
    /// A limb of the hierarchy (WE: the Body, which always exists, then its limbs, each possibly
    /// split further), in the hierarchy's order: a limb's children follow it.
    public struct Limb: Equatable, Sendable {
        public var depth: Int
        /// What the limb's separation gave: the limb (`fg`) and what's left without it (`bg`);
        /// nil for the Body.
        public var foreground: RGBAImage?
        public var background: RGBAImage?

        public init(depth: Int, foreground: RGBAImage? = nil, background: RGBAImage? = nil) {
            self.depth = depth
            self.foreground = foreground
            self.background = background
        }
    }

    /// The index of the picture a limb is cut from: nil for the Body's own picture; the previous
    /// sibling's index (cut from its background) or the parent's index (cut from its foreground).
    public enum Source: Equatable, Sendable {
        case picture
        case background(of: Int)
        case foreground(of: Int)
    }

    /// Where each limb is cut from, as WE's hierarchy works it out: the first child of a limb
    /// from the limb, a later one from what the sibling before it left.
    public static func sources(depths: [Int]) -> [Source] {
        var latest: [Int] = []
        var result: [Source] = []
        for (index, depth) in depths.enumerated() {
            if index == 0 || depth == 0 {
                result.append(.picture)
            } else if depth < latest.count {
                result.append(.background(of: latest[depth]))
            } else {
                result.append(.foreground(of: latest[depth - 1]))
            }
            if latest.count > depth { latest.removeSubrange(depth...) }
            latest.append(index)
        }
        return result
    }

    /// The parent of each limb (nil for the Body).
    public static func parents(depths: [Int]) -> [Int?] {
        var stack: [Int] = []
        return depths.enumerated().map { (index: Int, depth: Int) -> Int? in
            if stack.count > depth { stack.removeSubrange(depth...) }
            let parent = depth > 0 ? stack.last : nil
            stack.append(index)
            return parent
        }
    }

    /// The pictures on the sheet, as WE collects them: for each limb with children, what is left
    /// of it after its last child (its last child's background); for each limb without, the limb.
    /// A Body without limbs is the picture itself (`body`).
    public static func pieces(_ limbs: [Limb], body: RGBAImage) -> [RGBAImage] {
        let depths = limbs.map(\.depth)
        let parents = parents(depths: depths)
        var pieces: [RGBAImage] = []
        var seenParents = Set<Int>()
        for index in limbs.indices.dropFirst() {
            guard let parent = parents[index] else { continue }
            if !seenParents.contains(parent) {
                seenParents.insert(parent)
                let lastSibling = limbs.indices.last { parents[$0] == parent } ?? index
                if let remainder = limbs[lastSibling].background { pieces.append(remainder) }
            }
            let isLeaf = !limbs.indices.contains { parents[$0] == index }
            if isLeaf, let foreground = limbs[index].foreground { pieces.append(foreground) }
        }
        return limbs.count > 1 ? pieces : [body]
    }

    // MARK: Packing

    /// A piece cut to its opaque pixels, and where it lands.
    struct Placement {
        var image: RGBAImage
        var x: Int
        var y: Int
    }

    /// The space between pieces: an eighth of the pictures' mean side, 30…200 pixels (WE's).
    public static func spacing(for pieces: [RGBAImage]) -> Int {
        let largest = pieces.map { ($0.width + $0.height) / 2 }.max() ?? 0
        return min(max(Int(Float(largest) * 0.125), 30), 200)
    }

    /// The pieces cut to their opaque pixels and laid out on one transparent texture, the
    /// tallest first in rows, at the row width that gives the smallest, squarest sheet (WE's
    /// docs: "don't line up all limbs in a row, but rather place them into a square").
    public static func sheet(_ pieces: [RGBAImage]) -> RGBAImage {
        let gap = spacing(for: pieces)
        let cut = pieces.compactMap(croppedToContent)
        guard !cut.isEmpty else { return RGBAImage(width: 1, height: 1) }
        let sorted = cut.sorted { $0.height != $1.height ? $0.height > $1.height : $0.width > $1.width }
        let widest = sorted.map(\.width).max() ?? 1
        let total = sorted.reduce(0) { $0 + $1.width + gap }
        var best: (placements: [Placement], width: Int, height: Int)?
        var bestScore = Int.max
        var limit = widest
        while true {
            let layout = shelves(sorted, rowWidth: limit, gap: gap)
            let side = max(layout.width, layout.height)
            let score = side * side
            if score < bestScore { bestScore = score; best = layout }
            if limit >= total { break }
            limit = min(limit + max(widest / 8, 16), total)
        }
        guard let best else { return RGBAImage(width: 1, height: 1) }
        var sheet = RGBAImage(width: best.width, height: best.height)
        for placement in best.placements {
            for row in 0..<placement.image.height {
                let from = row * placement.image.width * 4
                let to = ((placement.y + row) * best.width + placement.x) * 4
                sheet.pixels.replaceSubrange(to..<to + placement.image.width * 4,
                                             with: placement.image.pixels[from..<from + placement.image.width * 4])
            }
        }
        return sheet
    }

    /// Rows of pieces no wider than `rowWidth`, `gap` between them and around the sheet.
    static func shelves(_ pieces: [RGBAImage], rowWidth: Int, gap: Int) -> (placements: [Placement], width: Int, height: Int) {
        var placements: [Placement] = []
        var x = gap, y = gap, rowHeight = 0, width = 0
        for piece in pieces {
            if x > gap && x + piece.width + gap > rowWidth + 2 * gap {
                y += rowHeight + gap
                x = gap
                rowHeight = 0
            }
            placements.append(Placement(image: piece, x: x, y: y))
            x += piece.width + gap
            rowHeight = max(rowHeight, piece.height)
            width = max(width, x)
        }
        return (placements, width, y + rowHeight + gap)
    }

    /// The image cut to the rectangle of its pixels with any alpha; nil when it has none.
    static func croppedToContent(_ image: RGBAImage) -> RGBAImage? {
        var minX = image.width, minY = image.height, maxX = -1, maxY = -1
        for y in 0..<image.height {
            for x in 0..<image.width where image.pixels[(y * image.width + x) * 4 + 3] != 0 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        let width = maxX - minX + 1, height = maxY - minY + 1
        var result = RGBAImage(width: width, height: height)
        for row in 0..<height {
            let from = ((minY + row) * image.width + minX) * 4
            result.pixels.replaceSubrange(row * width * 4..<(row + 1) * width * 4, with: image.pixels[from..<from + width * 4])
        }
        return result
    }
}
