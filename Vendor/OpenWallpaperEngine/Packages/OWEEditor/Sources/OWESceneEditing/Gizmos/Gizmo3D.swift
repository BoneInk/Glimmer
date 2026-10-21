import Foundation

/// The 3D scene's gizmo: arrows that move an object along an axis, rings that turn it about one,
/// handles that scale it along its own axes and a centre that moves it in the view's plane or
/// scales it evenly, laid out on the canvas through the scene's camera.
public enum Gizmo3D {
    public enum Handle: Hashable, Sendable {
        /// Moves along axis 0, 1 or 2 (x, y, z) of the gizmo's space.
        case move(Int)
        /// Moves in the view's plane (the centre in Translate and Multi).
        case moveFree
        /// Turns about axis 0, 1 or 2 of the gizmo's space.
        case rotate(Int)
        /// Scales along the object's own axis 0, 1 or 2.
        case scale(Int)
        /// Scales every axis evenly (the centre in Scale).
        case scaleUniform
    }

    /// Canvas points from the pivot to an arrow's tip or a scale handle.
    public static let axisLength: Double = 70
    /// The rings' radius in canvas points.
    public static let ringRadius: Double = 56
    /// How near (canvas points) a press must be to a handle to grab it.
    public static let handleRadius: Double = 7
    /// How near (canvas points) a press must be to an object's origin to pick it.
    public static let pickRadius: Double = 10
    /// Canvas points a centre drag scales by e (Scale's centre: right and up enlarge).
    public static let uniformScaleDistance: Double = 120

    /// The gizmo of one object as the canvas shows it.
    public struct Frame: Hashable, Sendable {
        /// The object's origin on the canvas.
        public var pivot: SIMD2<Double>
        /// The axes in world space: the scene's in world space, the object's own (unit) in local.
        public var axes: [SIMD3<Double>]
        /// The object's own axes in world space (unit), which scaling follows.
        public var ownAxes: [SIMD3<Double>]
        /// Canvas points per world unit along each of `axes` and `ownAxes` at the pivot, as
        /// vectors (zero for an axis pointing at the camera).
        public var screenAxes: [SIMD2<Double>]
        public var screenOwnAxes: [SIMD2<Double>]
        /// Each ring as a closed polyline on the canvas.
        public var rings: [[SIMD2<Double>]]
        /// Each ring's direction on screen: +1 when turning about its axis by a positive angle
        /// goes counter-clockwise on screen (the axis points at the viewer), −1 otherwise.
        public var ringSense: [Double]

        /// The unit screen direction of `axes[index]`, nil when it points at the camera.
        public func direction(_ index: Int, own: Bool = false) -> SIMD2<Double>? {
            let vector = own ? screenOwnAxes[index] : screenAxes[index]
            let length = (vector * vector).sum().squareRoot()
            return length > 1e-6 ? vector / length : nil
        }

        /// Where an axis handle is drawn: `axisLength` from the pivot along its screen direction.
        public func tip(_ index: Int, own: Bool = false, length: Double = Gizmo3D.axisLength) -> SIMD2<Double>? {
            direction(index, own: own).map { pivot + $0 * length }
        }
    }

    /// The gizmo for `spatial`; nil when its origin is behind the camera.
    public static func frame(_ spatial: LayerSpatial, space: GizmoSpace, camera: EditorSceneCamera,
                             viewport: CanvasViewport) -> Frame? {
        let pivot3 = spatial.pivot
        guard let pivot = camera.canvasPoint(pivot3, in: viewport) else { return nil }
        let rotation = spatial.world.rotationOnly
        let own = (0..<3).map { rotation.axis($0) }
        let world: [SIMD3<Double>] = [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)]
        let axes = space == .world ? world : own
        // Screen vectors per world unit, measured over a step small against the camera's depth.
        let clip = camera.clip(pivot3)
        let step = max(abs(clip.w), 1e-3) * 1e-3
        func screen(_ axis: SIMD3<Double>) -> SIMD2<Double> {
            guard let moved = camera.canvasPoint(pivot3 + axis * step, in: viewport) else { return .zero }
            return (moved - pivot) / step
        }
        let screenAxes = axes.map(screen)
        let screenOwn = own.map(screen)
        var rings: [[SIMD2<Double>]] = [], senses: [Double] = []
        for index in 0..<3 {
            let first = axes[(index + 1) % 3], second = axes[(index + 2) % 3]
            // The ring's world radius: `ringRadius` points at the pivot along its plane's axes.
            let lengths = [screenAxes[(index + 1) % 3], screenAxes[(index + 2) % 3]].map { ($0 * $0).sum().squareRoot() }
            let perUnit = max(lengths.max() ?? 0, 1e-9)
            let radius = ringRadius / perUnit
            var points: [SIMD2<Double>] = []
            for sample in 0..<48 {
                let angle = Double(sample) / 48 * 2 * .pi
                let point = pivot3 + (first * cos(angle) + second * sin(angle)) * radius
                if let canvas = camera.canvasPoint(point, in: viewport) { points.append(canvas) }
            }
            rings.append(points)
            // first × second is the axis: the ring's own winding on screen (y up) says which way it faces.
            let a = screenAxes[(index + 1) % 3], b = screenAxes[(index + 2) % 3]
            let crossUp = a.x * (-b.y) - (-a.y) * b.x
            senses.append(crossUp >= 0 ? 1 : -1)
        }
        return Frame(pivot: pivot, axes: axes, ownAxes: own, screenAxes: screenAxes, screenOwnAxes: screenOwn,
                     rings: rings, ringSense: senses)
    }

    /// The handle under `canvasPoint` for `mode`: the centre, then the axes' handles, then the rings.
    public static func handle(at canvasPoint: SIMD2<Double>, frame: Frame, mode: GizmoMode) -> Handle? {
        func distance(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { ((a - b) * (a - b)).sum().squareRoot() }
        func distanceToSegment(_ from: SIMD2<Double>, _ to: SIMD2<Double>) -> Double {
            let segment = to - from
            let length = (segment * segment).sum()
            guard length > 1e-12 else { return distance(canvasPoint, from) }
            let t = min(max(((canvasPoint - from) * segment).sum() / length, 0), 1)
            return distance(canvasPoint, from + segment * t)
        }
        if distance(canvasPoint, frame.pivot) <= handleRadius + 2 {
            if mode.translates { return .moveFree }
            if mode.scales { return .scaleUniform }
        }
        if mode == .scale || mode == .multi {
            let length = mode == .multi ? axisLength * 0.6 : axisLength
            for index in 0..<3 {
                if let tip = frame.tip(index, own: true, length: length), distance(canvasPoint, tip) <= handleRadius {
                    return .scale(index)
                }
            }
        }
        if mode.translates {
            for index in 0..<3 {
                guard let direction = frame.direction(index), let tip = frame.tip(index) else { continue }
                if distanceToSegment(frame.pivot + direction * 12, tip) <= handleRadius { return .move(index) }
            }
        }
        if mode.rotates {
            var best: (index: Int, distance: Double)?
            for (index, ring) in frame.rings.enumerated() where ring.count > 1 {
                for (point, next) in zip(ring, ring.dropFirst() + [ring[0]]) {
                    let gap = distanceToSegment(point, next)
                    if gap <= handleRadius, gap < (best?.distance ?? .infinity) { best = (index, gap) }
                }
            }
            if let best { return .rotate(best.index) }
        }
        return nil
    }

    /// What a drag needs from its start.
    public struct Drag: Hashable, Sendable {
        public var handle: Handle
        public var start: LayerSpatial
        public var frame: Frame
        /// Where the press was, in canvas points.
        public var startPoint: SIMD2<Double>

        public init(handle: Handle, start: LayerSpatial, frame: Frame, startPoint: SIMD2<Double>) {
            self.handle = handle
            self.start = start
            self.frame = frame
            self.startPoint = startPoint
        }

        /// The object's transform with the pointer at `canvasPoint`. `snap` turns in 15° steps.
        public func transform(at canvasPoint: SIMD2<Double>, camera: EditorSceneCamera, viewport: CanvasViewport,
                              snap: Bool = false) -> LayerTransform {
            var result = start.transform
            let delta = canvasPoint - startPoint
            switch handle {
            case .move(let index):
                guard let direction = frame.direction(index) else { return result }
                let perUnit = (frame.screenAxes[index] * frame.screenAxes[index]).sum().squareRoot()
                let distance = (delta * direction).sum() / perUnit
                moveWorldOrigin(by: frame.axes[index] * distance, in: &result)
            case .moveFree:
                guard let from = camera.worldPoint(at: startPoint, depthOf: start.pivot, in: viewport),
                      let to = camera.worldPoint(at: canvasPoint, depthOf: start.pivot, in: viewport) else { return result }
                moveWorldOrigin(by: to - from, in: &result)
            case .rotate(let index):
                let before = Gizmo3D.screenAngle(startPoint - frame.pivot)
                let after = Gizmo3D.screenAngle(canvasPoint - frame.pivot)
                var angle = LayerGizmo.wrap(after - before) * frame.ringSense[index]
                if snap {
                    let step = Double.pi / 12
                    angle = (angle / step).rounded() * step
                }
                result.angles = turned(by: angle, about: index)
            case .scale(let index):
                guard let direction = frame.direction(index, own: true) else { return result }
                let along = (delta * direction).sum()
                let factor = 1 + along / Gizmo3D.axisLength
                result.scale[index] = LayerGizmo.clampScale(start.transform.scale[index] * factor)
            case .scaleUniform:
                let factor = exp((delta.x - delta.y) / Gizmo3D.uniformScaleDistance)
                for index in 0..<3 { result.scale[index] = LayerGizmo.clampScale(start.transform.scale[index] * factor) }
            }
            return result
        }

        /// The origin moved by `worldDelta`, in the parent's space where the object's value lives.
        private func moveWorldOrigin(by worldDelta: SIMD3<Double>, in result: inout LayerTransform) {
            guard let toParent = start.parent.inverted else { return }
            result.origin = start.transform.origin + toParent.applyVector(worldDelta)
        }

        /// The angles after turning the object by `angle` about the gizmo's axis `index`: in local
        /// space after its own rotation, in world space before it (the parents' rotation undone,
        /// so the turn is about the world's axis).
        private func turned(by angle: Double, about index: Int) -> SIMD3<Double> {
            let (row0, row1, row2) = EditorMatrix4.rotationRows(start.transform.angles)
            let rotation = EditorMatrix4(columns: (SIMD4(row0.x, row0.y, row0.z, 0), SIMD4(row1.x, row1.y, row1.z, 0),
                                                   SIMD4(row2.x, row2.y, row2.z, 0), SIMD4(0, 0, 0, 1)))
            let turned: EditorMatrix4
            if frame.axes == frame.ownAxes {
                let axis = SIMD3<Double>(index == 0 ? 1 : 0, index == 1 ? 1 : 0, index == 2 ? 1 : 0)
                turned = rotation * EditorMatrix4.rotation(about: axis, angle: angle)
            } else {
                let parent = start.parent.rotationOnly
                let axis = parent.inverted.map { $0.applyVector(frame.axes[index]) } ?? frame.axes[index]
                turned = EditorMatrix4.rotation(about: axis, angle: angle) * rotation
            }
            return EditorMatrix4.angles(row0: turned.axis(0), row1: turned.axis(1), row2: turned.axis(2))
        }
    }

    /// A canvas vector's angle with y up, counter-clockwise from +x.
    static func screenAngle(_ vector: SIMD2<Double>) -> Double { atan2(-vector.y, vector.x) }
}
