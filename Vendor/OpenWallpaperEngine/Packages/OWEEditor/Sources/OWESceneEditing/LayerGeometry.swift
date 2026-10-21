import Foundation

/// A layer's own transform values, as scene.json holds them: origin in its parent's space, scale,
/// and rotation about z in radians.
public struct LayerTransform: Hashable, Sendable {
    public var origin: SIMD3<Double>
    public var scale: SIMD3<Double>
    /// `angles` in radians; the canvas edits `z`.
    public var angles: SIMD3<Double>

    public init(origin: SIMD3<Double> = .zero, scale: SIMD3<Double> = .one, angles: SIMD3<Double> = .zero) {
        self.origin = origin
        self.scale = scale
        self.angles = angles
    }

    public var local: SceneTransform2D {
        .layer(translation: SIMD2(origin.x, origin.y), rotation: angles.z, scale: SIMD2(scale.x, scale.y))
    }
}

/// Where a planar layer is on the scene: its rectangle in its own space and the transform to the
/// scene's, its parents' included.
public struct LayerGeometry: Hashable, Sendable {
    public var transform: LayerTransform
    /// The parents' transforms composed: the layer's parent space to scene space.
    public var parent: SceneTransform2D
    /// The rectangle's size before scaling.
    public var size: SIMD2<Double>
    /// Where the rectangle's centre is from the origin (WE's `alignment`).
    public var anchorOffset: SIMD2<Double>

    public init(transform: LayerTransform, parent: SceneTransform2D = .identity, size: SIMD2<Double>,
                anchorOffset: SIMD2<Double> = .zero) {
        self.transform = transform
        self.parent = parent
        self.size = size
        self.anchorOffset = anchorOffset
    }

    /// Layer space to scene space.
    public var world: SceneTransform2D { parent.concatenating(transform.local) }

    /// The rectangle's corners in scene space: bottom-left, bottom-right, top-right, top-left.
    public var corners: [SIMD2<Double>] {
        let half = size / 2
        return [SIMD2(-half.x, -half.y), SIMD2(half.x, -half.y), SIMD2(half.x, half.y), SIMD2(-half.x, half.y)]
            .map { world.apply($0 + anchorOffset) }
    }

    /// The layer's origin in scene space, which rotation and scale turn about.
    public var pivot: SIMD2<Double> { parent.apply(SIMD2(transform.origin.x, transform.origin.y)) }

    /// Whether `scenePoint` is on the layer's rectangle.
    public func contains(_ scenePoint: SIMD2<Double>) -> Bool {
        guard let inverse = world.inverted else { return false }
        let local = inverse.apply(scenePoint) - anchorOffset
        return abs(local.x) <= size.x / 2 && abs(local.y) <= size.y / 2
    }

    /// WE's `alignment`: where the origin sits on the rectangle (`center` by default; y up).
    public static func anchorOffset(alignment: String?, size: SIMD2<Double>) -> SIMD2<Double> {
        let value = (alignment ?? "center").lowercased()
        var offset = SIMD2<Double>.zero
        if value.contains("left") { offset.x = size.x / 2 } else if value.contains("right") { offset.x = -size.x / 2 }
        if value.contains("top") { offset.y = -size.y / 2 } else if value.contains("bottom") { offset.y = size.y / 2 }
        return offset
    }
}
