import Foundation

/// What the author draws in WE's Foreground Separation (its `draw-canvas`): with the **brush**, a
/// map of pixels marked foreground, background or neither (WE's white, black and erased paint);
/// with the **polygon** tool, outlines whose inside is the foreground (overlapping ones cancel,
/// as WE fills them with "xor"). One of the two drives a separation, as in WE, where switching
/// tools keeps the other's drawing for later.
public struct SeparationMarks: Equatable, Sendable {
    public enum Mark: UInt8, Sendable {
        case none = 0, foreground = 1, background = 2
    }

    public enum Mode: String, Sendable, CaseIterable {
        case polygon, brush
    }

    public let width: Int
    public let height: Int
    public var mode: Mode = .polygon
    /// The brush's marks, one per pixel.
    public var marks: [Mark]
    /// The outlines, in pixels (y down); an outline is closed when its last point is its first.
    public var polygons: [[SIMD2<Double>]] = []

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
        marks = [Mark](repeating: .none, count: width * height)
    }

    public var hasMarks: Bool { marks.contains { $0 != .none } }

    /// WE's brush diameter in pixels for a Brush size of `percent` (1…100): up to 200 pixels per
    /// 400 of the picture's long side (at least 200), `(percent − 1) / 99` to the power 1.5.
    public static func brushDiameter(percent: Double, width: Int, height: Int) -> Double {
        let unit = max(1, Double(max(width, height)) / 400)
        let t = min(max((percent - 1) / 99, 0), 1)
        return 200 * unit * pow(t, 1.5) + 1
    }

    /// Paints a stroke from `start` to `end` with a round brush of `diameter` pixels.
    public mutating func paint(from start: SIMD2<Double>, to end: SIMD2<Double>, diameter: Double, mark: Mark) {
        let radius = max(diameter / 2, 0.5)
        let minX = max(Int(floor(min(start.x, end.x) - radius)), 0), maxX = min(Int(ceil(max(start.x, end.x) + radius)), width - 1)
        let minY = max(Int(floor(min(start.y, end.y) - radius)), 0), maxY = min(Int(ceil(max(start.y, end.y) + radius)), height - 1)
        guard minX <= maxX, minY <= maxY else { return }
        let segment = end - start
        let lengthSquared = (segment * segment).sum()
        for y in minY...maxY {
            for x in minX...maxX {
                let p = SIMD2(Double(x) + 0.5, Double(y) + 0.5)
                var t = lengthSquared > 0 ? ((p - start) * segment).sum() / lengthSquared : 0
                t = min(max(t, 0), 1)
                let d = p - (start + segment * t)
                if (d * d).sum() <= radius * radius { marks[y * width + x] = mark }
            }
        }
    }

    // MARK: Polygons

    static func isClosed(_ polygon: [SIMD2<Double>]) -> Bool { polygon.count > 1 && polygon.first == polygon.last }

    /// The outlines as filled, smoothed as WE draws them at Smoothing `smoothing` (cubic curves
    /// through the points, tension `0.3 × smoothing`, below 0.1 straight lines): each a list of
    /// points.
    public func outlines(smoothing: Double) -> [[SIMD2<Double>]] {
        polygons.compactMap { (polygon: [SIMD2<Double>]) -> [SIMD2<Double>]? in
            guard polygon.count > 2 else { return nil }
            var points = polygon
            if Self.isClosed(points) { points.removeLast() }
            guard points.count > 2, smoothing >= 0.1 else { return points }
            let tension = 0.3 * smoothing
            var curve: [SIMD2<Double>] = []
            let count = points.count
            for index in 0..<count {
                let previous = points[(index + count - 1) % count], current = points[index]
                let following = points[(index + 1) % count], after = points[(index + 2) % count]
                let control1 = current + (following - previous) / 6 * tension
                let control2 = following - (after - current) / 6 * tension
                for step in 0..<8 {
                    let t = Double(step) / 8, u = 1 - t
                    curve.append(current * (u * u * u) + control1 * (3 * u * u * t) + control2 * (3 * u * t * t) + following * (t * t * t))
                }
            }
            return curve
        }
    }

    /// The outlines' inside (1) at the picture's size, even-odd across outlines, as WE's "xor".
    public func polygonMask(smoothing: Double) -> ImagePlane {
        var mask = ImagePlane(width: width, height: height)
        let outlines = outlines(smoothing: smoothing)
        guard !outlines.isEmpty else { return mask }
        for y in 0..<height {
            let scanY = Double(y) + 0.5
            var crossings: [Double] = []
            for outline in outlines {
                for index in outline.indices {
                    let a = outline[index], b = outline[(index + 1) % outline.count]
                    if (a.y <= scanY) != (b.y <= scanY) {
                        crossings.append(a.x + (scanY - a.y) / (b.y - a.y) * (b.x - a.x))
                    }
                }
            }
            crossings.sort()
            var pair = 0
            while pair + 1 < crossings.count {
                let from = max(Int(ceil(crossings[pair] - 0.5)), 0), to = min(Int(floor(crossings[pair + 1] - 0.5)), width - 1)
                if from <= to { for x in from...to { mask.pixels[y * width + x] = 1 - mask.pixels[y * width + x] } }
                pair += 2
            }
        }
        return mask.map { $0 > 0.5 ? 1 : 0 }
    }

    /// The marks as GrabCut's labels, at the picture's size: marked pixels sure, the rest probable,
    /// probably foreground where `prior` (0…1, the automatic guess) is above one half.
    public func grabCutLabels(prior: ImagePlane?) -> [GrabCut.Label] {
        marks.indices.map { (index: Int) -> GrabCut.Label in
            switch marks[index] {
            case .foreground: return .foreground
            case .background: return .background
            case .none:
                guard let prior, prior.pixels.indices.contains(index) else { return .probableBackground }
                return prior.pixels[index] > 0.5 ? .probableForeground : .probableBackground
            }
        }
    }
}

extension SeparationMarks {
    /// The automatic guess from the objects found in the picture (each a 0…1 mask at its size):
    /// the ones the foreground strokes touch, or all of them before there are any.
    public func prior(from instances: [ImagePlane]) -> ImagePlane? {
        guard let first = instances.first else { return nil }
        let marked = marks.indices.filter { marks[$0] == .foreground }
        var chosen = instances.filter { instance in marked.contains { instance.pixels[$0] > 0.5 } }
        if chosen.isEmpty { chosen = instances }
        var combined = ImagePlane(width: first.width, height: first.height)
        for instance in chosen where instance.width == first.width && instance.height == first.height {
            for index in combined.pixels.indices { combined.pixels[index] = max(combined.pixels[index], instance.pixels[index]) }
        }
        return combined
    }
}
