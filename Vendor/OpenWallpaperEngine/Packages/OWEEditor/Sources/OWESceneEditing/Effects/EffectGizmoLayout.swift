import Foundation

/// An effect gizmo as the canvas shows it on its layer: its current values per role, where its
/// handles are, and what dragging one sets. Values are in the layer's UV as the effect's shader
/// reads them (0…1, y down); the canvas maps UV to its points through `EffectGizmoLayout.Mapping`.
public struct EffectGizmoLayout: Hashable, Sendable {
    /// The gizmo's type; nil for a lone `"position": true` constant, a point handle of its own.
    public var kind: EffectGizmo.Kind?
    /// The gizmo's role (`center`, `p0`…) to its current value.
    public var values: [String: [Double]]
    /// A role's declared range (a size's `[0, 1]`), which a drag stays within.
    public var ranges: [String: ClosedRange<Double>]

    public init(kind: EffectGizmo.Kind?, values: [String: [Double]], ranges: [String: ClosedRange<Double>] = [:]) {
        self.kind = kind
        self.values = values
        self.ranges = ranges
    }

    /// UV on the layer to canvas points and back (`LayerGeometry` through the viewport).
    public struct Mapping: Sendable {
        public var toCanvas: @Sendable (SIMD2<Double>) -> SIMD2<Double>
        public var toUV: @Sendable (SIMD2<Double>) -> SIMD2<Double>?
        /// The layer's width over its height, which aspect-corrected shaders (Spin, Swing) scale x by.
        public var aspect: Double

        public init(toCanvas: @escaping @Sendable (SIMD2<Double>) -> SIMD2<Double>,
                    toUV: @escaping @Sendable (SIMD2<Double>) -> SIMD2<Double>?, aspect: Double) {
            self.toCanvas = toCanvas
            self.toUV = toUV
            self.aspect = aspect
        }

        /// The layer's UV through its rectangle on the scene: (0, 0) its top-left corner, (1, 1)
        /// its bottom-right, as a layer's texture coordinates run.
        public init(geometry: LayerGeometry, viewport: CanvasViewport) {
            let size = geometry.size, anchor = geometry.anchorOffset, world = geometry.world
            let inverse = world.inverted
            toCanvas = { uv in
                viewport.canvasPoint(world.apply(SIMD2((uv.x - 0.5) * size.x, (0.5 - uv.y) * size.y) + anchor))
            }
            toUV = { point in
                guard let inverse, size.x > 0, size.y > 0 else { return nil }
                let local = inverse.apply(viewport.scenePoint(point)) - anchor
                return SIMD2(local.x / size.x + 0.5, 0.5 - local.y / size.y)
            }
            aspect = size.y > 0 ? size.x / size.y : 1
        }
    }

    /// Canvas points from an emitter's circle to its direction arrow's tip.
    public static let arrowLength: Double = 36

    func value(_ role: String, default fallback: [Double]) -> [Double] {
        let value = values[role] ?? fallback
        return value.count >= fallback.count ? value : fallback
    }

    func point(_ role: String, default fallback: SIMD2<Double> = SIMD2(0.5, 0.5)) -> SIMD2<Double> {
        let value = value(role, default: [fallback.x, fallback.y])
        return SIMD2(value[0], value[1])
    }

    func scalar(_ role: String, default fallback: Double) -> Double { value(role, default: [fallback])[0] }

    // MARK: Shapes

    /// WE's emitter direction for `angle`: 0 points up the layer, turning clockwise
    /// (`vec2(sin(angle), -cos(angle))` in UV, fluidsimulation's EmitterVelocity).
    static func emitterDirection(_ angle: Double) -> SIMD2<Double> { SIMD2(sin(angle), -cos(angle)) }

    /// A point of Spin's ellipse: `length(rotate(A·(uv − centre), angle) · (ratio, 1)) = size` at
    /// parameter `t`, with A the aspect's x scale (spin.vert).
    func spinPoint(_ t: Double, aspect: Double) -> SIMD2<Double> {
        let centre = point("center"), size = scalar("size", default: 0.1)
        let ratio = max(scalar("ratio", default: 1), 1e-6), angle = scalar("angle", default: 0)
        let v = SIMD2(size * cos(t) / ratio, size * sin(t))
        // rotate by −angle (rotateVec2's inverse), then undo the aspect.
        let w = SIMD2(v.x * cos(-angle) - v.y * sin(-angle), v.x * sin(-angle) + v.y * cos(-angle))
        return centre + SIMD2(w.x / max(aspect, 1e-6), w.y)
    }

    /// Swing's hinge axis and its perpendicular in aspect-corrected UV (swing.frag).
    func swingAxes(aspect: Double) -> (axis: SIMD2<Double>, ortho: SIMD2<Double>) {
        let p0 = point("p0", default: SIMD2(0.25, 0.5)), p1 = point("p1", default: SIMD2(0.75, 0.5))
        var axis = SIMD2((p1.x - p0.x) * aspect, p1.y - p0.y)
        let length = (axis * axis).sum().squareRoot()
        axis = length > 1e-9 ? axis / length : SIMD2(1, 0)
        return (axis, SIMD2(-axis.y, axis.x))
    }

    /// From aspect-corrected UV back to UV.
    static func unaspect(_ vector: SIMD2<Double>, _ aspect: Double) -> SIMD2<Double> {
        SIMD2(vector.x / max(aspect, 1e-6), vector.y)
    }

    /// The outline the canvas draws for the gizmo, as polylines in UV (closed where `closed`).
    public func outlines(aspect: Double) -> [(points: [SIMD2<Double>], closed: Bool)] {
        let samples = (0..<48).map { Double($0) / 48 * 2 * .pi }
        switch kind {
        case nil:
            return []
        case .perspectiveUV:
            return [([point("p0", default: SIMD2(0, 0)), point("p1", default: SIMD2(1, 0)),
                      point("p2", default: SIMD2(1, 1)), point("p3", default: SIMD2(0, 1))], true)]
        case .spinUV:
            return [(samples.map { spinPoint($0, aspect: aspect) }, true)]
        case .swingUV:
            let p0 = point("p0", default: SIMD2(0.25, 0.5)), p1 = point("p1", default: SIMD2(0.75, 0.5))
            let offset = Self.unaspect(swingAxes(aspect: aspect).ortho * scalar("size", default: 0.4), aspect)
            return [([p0, p1], false), ([p0, p1, p1 + offset, p0 + offset], true)]
        case .pointEmitter:
            let centre = point("center"), size = scalar("size", default: 0.05)
            return [(samples.map { centre + SIMD2(cos($0), sin($0)) * size }, true)]
        case .lineEmitter:
            let p0 = point("p0", default: SIMD2(0.1, 0.1)), p1 = point("p1", default: SIMD2(0.4, 0.1))
            let size = scalar("size", default: 0.02)
            var line = p1 - p0
            let length = (line * line).sum().squareRoot()
            line = length > 1e-9 ? line / length : SIMD2(1, 0)
            let side = SIMD2(-line.y, line.x) * size
            return [([p0, p1], false), ([p0 + side, p1 + side, p1 - side, p0 - side], true)]
        }
    }

    // MARK: Handles

    /// Each draggable handle's role and canvas point.
    public func handles(_ mapping: Mapping) -> [(role: String, point: SIMD2<Double>)] {
        switch kind {
        case nil:
            return [("position", mapping.toCanvas(point("position")))]
        case .perspectiveUV:
            return [("p0", SIMD2(0, 0)), ("p1", SIMD2(1, 0)), ("p2", SIMD2(1, 1)), ("p3", SIMD2(0, 1))].map { role, fallback in
                (role, mapping.toCanvas(point(role, default: fallback)))
            }
        case .spinUV:
            return [("center", mapping.toCanvas(point("center"))),
                    ("size", mapping.toCanvas(spinPoint(.pi / 2, aspect: mapping.aspect))),
                    ("ratio", mapping.toCanvas(spinPoint(0, aspect: mapping.aspect)))]
        case .swingUV:
            let p0 = point("p0", default: SIMD2(0.25, 0.5)), p1 = point("p1", default: SIMD2(0.75, 0.5))
            let centre = p0 + (p1 - p0) * scalar("center", default: 0.5)
            let offset = Self.unaspect(swingAxes(aspect: mapping.aspect).ortho * scalar("size", default: 0.4), mapping.aspect)
            return [("p0", mapping.toCanvas(p0)), ("p1", mapping.toCanvas(p1)), ("center", mapping.toCanvas(centre)),
                    ("size", mapping.toCanvas(centre + offset))]
        case .pointEmitter:
            let centre = point("center"), size = scalar("size", default: 0.05)
            return [("center", mapping.toCanvas(centre)), ("size", mapping.toCanvas(centre + SIMD2(size, 0))),
                    ("angle", arrowTip(from: centre, radius: size, mapping))]
        case .lineEmitter:
            let p0 = point("p0", default: SIMD2(0.1, 0.1)), p1 = point("p1", default: SIMD2(0.4, 0.1))
            let middle = (p0 + p1) / 2, size = scalar("size", default: 0.02)
            var line = p1 - p0
            let length = (line * line).sum().squareRoot()
            line = length > 1e-9 ? line / length : SIMD2(1, 0)
            return [("p0", mapping.toCanvas(p0)), ("p1", mapping.toCanvas(p1)),
                    ("size", mapping.toCanvas(middle + SIMD2(-line.y, line.x) * size)),
                    ("angle", arrowTip(from: middle, radius: size, mapping))]
        }
    }

    /// The direction arrow of an emitter at `centre`: `arrowLength` points past its circle along
    /// its angle as the canvas shows UV.
    public func arrowTip(from centre: SIMD2<Double>, radius: Double, _ mapping: Mapping) -> SIMD2<Double> {
        let direction = Self.emitterDirection(scalar("angle", default: 0))
        let start = mapping.toCanvas(centre)
        let rim = mapping.toCanvas(centre + direction * radius)
        var along = mapping.toCanvas(centre + direction * 0.01) - start
        let length = (along * along).sum().squareRoot()
        along = length > 1e-9 ? along / length : SIMD2(0, -1)
        return rim + along * Self.arrowLength
    }

    /// The new values (role to value) with handle `role` dragged to `canvasPoint`.
    public func dragged(_ role: String, to canvasPoint: SIMD2<Double>, _ mapping: Mapping) -> [String: [Double]] {
        guard let uv = mapping.toUV(canvasPoint) else { return [:] }
        let aspect = mapping.aspect
        func clamped(_ role: String, _ value: Double) -> Double {
            guard let range = ranges[role] else { return value }
            return min(max(value, range.lowerBound), range.upperBound)
        }
        switch (kind, role) {
        case (nil, _), (.perspectiveUV?, _), (.swingUV?, "p0"), (.swingUV?, "p1"), (.lineEmitter?, "p0"), (.lineEmitter?, "p1"),
             (.spinUV?, "center"), (.pointEmitter?, "center"):
            return [role: [uv.x, uv.y]]
        case (.spinUV?, "size"):
            let w = SIMD2((uv.x - point("center").x) * aspect, uv.y - point("center").y)
            return ["size": [clamped("size", (w * w).sum().squareRoot())]]
        case (.spinUV?, "ratio"):
            // w = (size / ratio)(cos angle, −sin angle): its length gives the ratio, its turn the angle.
            let w = SIMD2((uv.x - point("center").x) * aspect, uv.y - point("center").y)
            let length = (w * w).sum().squareRoot()
            guard length > 1e-9 else { return [:] }
            var angle = atan2(-w.y, w.x)
            // The ellipse is the same turned half a turn: keep the angle in the declared range.
            if let range = ranges["angle"], !range.contains(angle) {
                angle += angle < range.lowerBound ? .pi : -.pi
            }
            return ["ratio": [clamped("ratio", scalar("size", default: 0.1) / length)], "angle": [clamped("angle", angle)]]
        case (.swingUV?, "center"):
            let p0 = point("p0", default: SIMD2(0.25, 0.5)), p1 = point("p1", default: SIMD2(0.75, 0.5))
            let line = SIMD2((p1.x - p0.x) * aspect, p1.y - p0.y), to = SIMD2((uv.x - p0.x) * aspect, uv.y - p0.y)
            let length = (line * line).sum()
            guard length > 1e-12 else { return [:] }
            return ["center": [clamped("center", min(max((to * line).sum() / length, 0), 1))]]
        case (.swingUV?, "size"):
            let p0 = point("p0", default: SIMD2(0.25, 0.5)), p1 = point("p1", default: SIMD2(0.75, 0.5))
            let centre = p0 + (p1 - p0) * scalar("center", default: 0.5)
            let to = SIMD2((uv.x - centre.x) * aspect, uv.y - centre.y)
            return ["size": [clamped("size", max((to * swingAxes(aspect: aspect).ortho).sum(), 0))]]
        case (.pointEmitter?, "size"):
            let delta = uv - point("center")
            return ["size": [clamped("size", (delta * delta).sum().squareRoot())]]
        case (.lineEmitter?, "size"):
            let p0 = point("p0", default: SIMD2(0.1, 0.1)), p1 = point("p1", default: SIMD2(0.4, 0.1))
            var line = p1 - p0
            let length = (line * line).sum().squareRoot()
            line = length > 1e-9 ? line / length : SIMD2(1, 0)
            return ["size": [clamped("size", abs(((uv - (p0 + p1) / 2) * SIMD2(-line.y, line.x)).sum()))]]
        case (.pointEmitter?, "angle"), (.lineEmitter?, "angle"):
            let centre = kind == .pointEmitter ? point("center")
                : (point("p0", default: SIMD2(0.1, 0.1)) + point("p1", default: SIMD2(0.4, 0.1))) / 2
            let delta = uv - centre
            guard (delta * delta).sum() > 1e-12 else { return [:] }
            var angle = atan2(delta.x, -delta.y)
            if angle < 0 { angle += 2 * .pi }
            return ["angle": [angle]]
        default:
            return [:]
        }
    }
}
