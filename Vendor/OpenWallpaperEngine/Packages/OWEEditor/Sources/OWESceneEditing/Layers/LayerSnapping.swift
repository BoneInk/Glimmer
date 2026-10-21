import Foundation

/// An axis-aligned rectangle in scene space (y up).
public struct SceneRect: Hashable, Sendable {
    public var minimum: SIMD2<Double>
    public var maximum: SIMD2<Double>

    public init(minimum: SIMD2<Double>, maximum: SIMD2<Double>) {
        self.minimum = minimum
        self.maximum = maximum
    }

    /// The smallest rectangle around `points`.
    public init(around points: [SIMD2<Double>]) {
        var low = SIMD2(Double.infinity, .infinity), high = SIMD2(-Double.infinity, -.infinity)
        for point in points {
            low = SIMD2(min(low.x, point.x), min(low.y, point.y))
            high = SIMD2(max(high.x, point.x), max(high.y, point.y))
        }
        self.init(minimum: low, maximum: high)
    }

    public var centre: SIMD2<Double> { (minimum + maximum) / 2 }
    public var size: SIMD2<Double> { maximum - minimum }

    /// Left, centre and right (axis 0) or bottom, centre and top (axis 1).
    public func lines(_ axis: Int) -> [Double] { [minimum[axis], centre[axis], maximum[axis]] }

    public func offset(by delta: SIMD2<Double>) -> SceneRect {
        SceneRect(minimum: minimum + delta, maximum: maximum + delta)
    }
}

/// Snapping a moved layer to the scene's edges and centre and to the other layers' edges and
/// centres, as WE's editor and Figma snap: each axis on its own, to the nearest line within the
/// threshold, with the guide drawn where it snapped.
public enum LayerSnapping {
    /// A line something snapped to: vertical (`axis` 0, at x = `position`) or horizontal (axis 1),
    /// spanning `from`…`to` along the other axis.
    public struct Guide: Hashable, Sendable {
        public var axis: Int
        public var position: Double
        public var from: Double
        public var to: Double
    }

    public struct Result: Hashable, Sendable {
        /// The move after snapping.
        public var delta: SIMD2<Double>
        public var guides: [Guide]
    }

    /// Snap targets: the scene's edges and centre lines, then each other rectangle's.
    public static func targets(scene: SIMD2<Double>, others: [SceneRect]) -> [SceneRect] {
        [SceneRect(minimum: .zero, maximum: scene)] + others
    }

    /// `moving` dragged by `delta`, snapped to `targets` within `threshold` scene units per axis.
    public static func snap(_ moving: SceneRect, delta: SIMD2<Double>, to targets: [SceneRect],
                            threshold: Double) -> Result {
        var snapped = delta
        var guides: [Guide] = []
        let moved = moving.offset(by: delta)
        for axis in 0..<2 {
            var best: (distance: Double, correction: Double, line: Double)?
            for target in targets {
                for line in target.lines(axis) {
                    for edge in moved.lines(axis) {
                        let correction = line - edge
                        let distance = abs(correction)
                        guard distance <= threshold else { continue }
                        if best == nil || distance < best!.distance - 1e-9 { best = (distance, correction, line) }
                    }
                }
            }
            guard let best else { continue }
            snapped[axis] += best.correction
            let other = 1 - axis
            let final = moving.offset(by: snapped)
            // The guide spans every target touching the line, and the moved rectangle.
            var low = final.minimum[other], high = final.maximum[other]
            for target in targets where target.lines(axis).contains(where: { abs($0 - best.line) < 1e-6 }) {
                low = min(low, target.minimum[other])
                high = max(high, target.maximum[other])
            }
            guides.append(Guide(axis: axis, position: best.line, from: low, to: high))
        }
        // Guides for the axis snapped first were measured before the other axis moved; measure again.
        let final = moving.offset(by: snapped)
        guides = guides.map { guide in
            var guide = guide
            let other = 1 - guide.axis
            guide.from = min(guide.from, final.minimum[other])
            guide.to = max(guide.to, final.maximum[other])
            return guide
        }
        return Result(delta: snapped, guides: guides)
    }

    /// Where to put `rect` so its edge or centre lines up with `within`'s, per axis: 0 is the
    /// minimum (left, bottom), 1 the centre, 2 the maximum (right, top); nil leaves the axis.
    public static func alignment(_ rect: SceneRect, within bounds: SceneRect, horizontal: Int?, vertical: Int?) -> SIMD2<Double> {
        var delta = SIMD2<Double>.zero
        if let horizontal { delta.x = bounds.lines(0)[horizontal] - rect.lines(0)[horizontal] }
        if let vertical { delta.y = bounds.lines(1)[vertical] - rect.lines(1)[vertical] }
        return delta
    }

    /// Even gaps between rectangles along `axis`: the move each one needs, keeping the first and last.
    public static func distribution(_ rects: [SceneRect], axis: Int) -> [SIMD2<Double>] {
        guard rects.count > 2 else { return rects.map { _ in .zero } }
        let order = rects.indices.sorted { rects[$0].minimum[axis] < rects[$1].minimum[axis] }
        let first = rects[order.first!], last = rects[order.last!]
        let total = last.maximum[axis] - first.minimum[axis]
        let occupied = rects.reduce(0) { $0 + $1.size[axis] }
        let gap = (total - occupied) / Double(rects.count - 1)
        var deltas = Array(repeating: SIMD2<Double>.zero, count: rects.count)
        var cursor = first.minimum[axis]
        for index in order {
            deltas[index][axis] = cursor - rects[index].minimum[axis]
            cursor += rects[index].size[axis] + gap
        }
        return deltas
    }
}
