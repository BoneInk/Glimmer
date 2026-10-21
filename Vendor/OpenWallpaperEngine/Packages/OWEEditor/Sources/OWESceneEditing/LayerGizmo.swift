import Foundation

/// The 2D scene's move/scale/rotate gizmo: what a press on the canvas grabs, and what dragging it
/// does, for each `GizmoMode`. Multi has the corners, the rotation handle above the top edge and
/// the body; Translate arrows along x and y (the scene's in World Space, the layer's own in Local
/// Space) and a centre square; Rotate a ring about the pivot; Scale a handle along each of the
/// layer's own axes and a centre square that scales evenly, with the corners; none has no handles.
public enum LayerGizmo {
    public enum Handle: Hashable, Sendable {
        case body
        /// A corner, indexed as `LayerGeometry.corners`.
        case corner(Int)
        /// The rotation handle (Multi) or the ring (Rotate).
        case rotate
        /// Translate's arrow along x (0) or y (1) of its space.
        case axis(Int)
        /// Scale's handle along the layer's own x (0) or y (1).
        case scaleAxis(Int)
        /// Scale's centre square: both axes evenly.
        case scaleUniform
    }

    /// Canvas points from the pivot to an arrow's tip or a scale handle.
    public static let axisLength: Double = 70
    /// Rotate's ring radius in canvas points.
    public static let ringRadius: Double = 56
    /// Canvas points a centre drag scales by e (right and up enlarge).
    public static let uniformScaleDistance: Double = 120

    /// Canvas points from the rectangle's top edge to the rotation handle.
    public static let rotateHandleDistance: Double = 28
    /// How near (canvas points) a press must be to a handle to grab it.
    public static let handleRadius: Double = 7

    /// The rotation handle's position in canvas points: above the middle of the layer's top edge,
    /// on the side away from its centre.
    public static func rotateHandle(_ geometry: LayerGeometry, in viewport: CanvasViewport) -> SIMD2<Double> {
        let corners = geometry.corners.map(viewport.canvasPoint)
        let topMiddle = (corners[2] + corners[3]) / 2
        let centre = (corners[0] + corners[2]) / 2
        var direction = topMiddle - centre
        let length = (direction * direction).sum().squareRoot()
        direction = length > 1e-9 ? direction / length : SIMD2(0, -1)
        return topMiddle + direction * rotateHandleDistance
    }

    /// The unit canvas direction of the scene's x (0) or y (1): right, or up the screen.
    public static func sceneAxis(_ index: Int) -> SIMD2<Double> { index == 0 ? SIMD2(1, 0) : SIMD2(0, -1) }

    /// Translate's arrow `index` on the canvas: the scene's axis in World Space, the layer's own
    /// (its parents' turn included) in Local Space.
    public static func translateAxis(_ index: Int, geometry: LayerGeometry, space: GizmoSpace,
                                     in viewport: CanvasViewport) -> SIMD2<Double> {
        space == .world ? sceneAxis(index) : layerAxis(index, geometry: geometry, in: viewport)
    }

    /// The unit canvas direction of the layer's own x (0) or y (1), its parents' turn included.
    public static func layerAxis(_ index: Int, geometry: LayerGeometry, in viewport: CanvasViewport) -> SIMD2<Double> {
        let world = geometry.world.applyVector(index == 0 ? SIMD2(1, 0) : SIMD2(0, 1))
        let canvas = SIMD2(world.x, -world.y)
        let length = (canvas * canvas).sum().squareRoot()
        return length > 1e-12 ? canvas / length : sceneAxis(index)
    }

    /// The handle under `canvasPoint` in `mode`. Multi: the rotation handle, then a corner, then
    /// the body. Translate: the centre, an arrow, the body. Rotate: the ring. Scale: the centre,
    /// an axis handle, a corner.
    public static func handle(at canvasPoint: SIMD2<Double>, geometry: LayerGeometry,
                              viewport: CanvasViewport, mode: GizmoMode = .multi, space: GizmoSpace = .world) -> Handle? {
        func near(_ point: SIMD2<Double>) -> Bool {
            let delta = point - canvasPoint
            return (delta * delta).sum() <= handleRadius * handleRadius
        }
        let pivot = viewport.canvasPoint(geometry.pivot)
        let fromPivot = canvasPoint - pivot
        let distance = (fromPivot * fromPivot).sum().squareRoot()
        switch mode {
        case .multi:
            if near(rotateHandle(geometry, in: viewport)) { return .rotate }
            if let corner = geometry.corners.map(viewport.canvasPoint).firstIndex(where: near) { return .corner(corner) }
        case .translate:
            if distance <= handleRadius + 2 { return .body }
            for index in 0..<2 {
                let direction = translateAxis(index, geometry: geometry, space: space, in: viewport)
                let along = (fromPivot * direction).sum()
                let across = fromPivot - direction * along
                if along >= 12, along <= axisLength + handleRadius, (across * across).sum() <= handleRadius * handleRadius {
                    return .axis(index)
                }
            }
        case .rotate:
            return abs(distance - ringRadius) <= handleRadius ? .rotate : nil
        case .scale:
            if distance <= handleRadius + 2 { return .scaleUniform }
            for index in 0..<2 where near(pivot + layerAxis(index, geometry: geometry, in: viewport) * axisLength) {
                return .scaleAxis(index)
            }
            if let corner = geometry.corners.map(viewport.canvasPoint).firstIndex(where: near) { return .corner(corner) }
            return nil
        case .none:
            break
        }
        return geometry.contains(viewport.scenePoint(canvasPoint)) ? .body : nil
    }

    /// What a drag needs to remember from its start.
    public struct Drag: Hashable, Sendable {
        public var handle: Handle
        public var start: LayerGeometry
        /// Where the press was, in scene space.
        public var startPoint: SIMD2<Double>

        /// Scene units per canvas point when the drag started (Scale's centre measures in points).
        public var unitsPerPoint: Double
        /// Translate's space: which axes its arrows follow.
        public var space: GizmoSpace

        public init(handle: Handle, start: LayerGeometry, startPoint: SIMD2<Double>, unitsPerPoint: Double = 1,
                    space: GizmoSpace = .world) {
            self.handle = handle
            self.start = start
            self.startPoint = startPoint
            self.unitsPerPoint = unitsPerPoint
            self.space = space
        }

        /// The layer's transform with the pointer at `scenePoint`. `free` scales each axis on its
        /// own (Shift; proportional otherwise); `snap` turns in 15° steps (Shift).
        public func transform(at scenePoint: SIMD2<Double>, free: Bool = false, snap: Bool = false) -> LayerTransform {
            var result = start.transform
            // The drag works in the parent's space, where the layer's own values live.
            guard let toParent = start.parent.inverted else { return result }
            let from = toParent.apply(startPoint), to = toParent.apply(scenePoint)
            let origin = SIMD2(result.origin.x, result.origin.y)
            switch handle {
            case .body:
                let delta = to - from
                result.origin.x += delta.x
                result.origin.y += delta.y
            case .axis(let index):
                // Along the arrow's axis in scene space: the pointer's move on it, then into the parent's space.
                var axis = SIMD2<Double>(index == 0 ? 1 : 0, index == 1 ? 1 : 0)
                if space == .local {
                    let turned = start.world.applyVector(axis)
                    let length = (turned * turned).sum().squareRoot()
                    if length > 1e-12 { axis = turned / length }
                }
                let along = axis * ((scenePoint - startPoint) * axis).sum()
                let delta = toParent.applyVector(along)
                result.origin.x += delta.x
                result.origin.y += delta.y
            case .scaleUniform:
                let delta = (scenePoint - startPoint) / max(unitsPerPoint, 1e-12)
                let factor = exp((delta.x + delta.y) / LayerGizmo.uniformScaleDistance)
                result.scale.x = LayerGizmo.clampScale(start.transform.scale.x * factor)
                result.scale.y = LayerGizmo.clampScale(start.transform.scale.y * factor)
            case .scaleAxis(let index):
                let angle = start.transform.angles.z
                func unrotated(_ point: SIMD2<Double>) -> SIMD2<Double> {
                    let delta = point - origin
                    return SIMD2(cos(-angle) * delta.x - sin(-angle) * delta.y, sin(-angle) * delta.x + cos(-angle) * delta.y)
                }
                let u0 = unrotated(from), u1 = unrotated(to)
                if abs(u0[index]) > 1e-9 {
                    result.scale[index] = LayerGizmo.clampScale(start.transform.scale[index] * u1[index] / u0[index])
                }
            case .rotate:
                let before = atan2(from.y - origin.y, from.x - origin.x)
                let after = atan2(to.y - origin.y, to.x - origin.x)
                var angle = start.transform.angles.z + LayerGizmo.wrap(after - before)
                if snap {
                    let step = Double.pi / 12
                    angle = (angle / step).rounded() * step
                }
                result.angles.z = angle
            case .corner:
                // In the layer's unrotated frame, about its origin.
                let angle = start.transform.angles.z
                func unrotated(_ point: SIMD2<Double>) -> SIMD2<Double> {
                    let delta = point - origin
                    return SIMD2(cos(-angle) * delta.x - sin(-angle) * delta.y, sin(-angle) * delta.x + cos(-angle) * delta.y)
                }
                let u0 = unrotated(from), u1 = unrotated(to)
                if free {
                    if abs(u0.x) > 1e-9 { result.scale.x = LayerGizmo.clampScale(start.transform.scale.x * u1.x / u0.x) }
                    if abs(u0.y) > 1e-9 { result.scale.y = LayerGizmo.clampScale(start.transform.scale.y * u1.y / u0.y) }
                } else {
                    let length = (u0 * u0).sum()
                    guard length > 1e-12 else { return result }
                    // The pointer projected on the line through the origin and the grabbed corner.
                    let factor = (u0 * u1).sum() / length
                    result.scale.x = LayerGizmo.clampScale(start.transform.scale.x * factor)
                    result.scale.y = LayerGizmo.clampScale(start.transform.scale.y * factor)
                }
            }
            return result
        }
    }

    /// The angle in -π...π.
    static func wrap(_ angle: Double) -> Double {
        var value = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if value > .pi { value -= 2 * .pi } else if value < -.pi { value += 2 * .pi }
        return value
    }

    /// A scale never reaches zero, which would make the layer impossible to grab again; flipping
    /// through zero keeps its sign.
    static func clampScale(_ value: Double) -> Double {
        let minimum = 0.01
        if abs(value) >= minimum { return value }
        return value < 0 ? -minimum : minimum
    }
}
