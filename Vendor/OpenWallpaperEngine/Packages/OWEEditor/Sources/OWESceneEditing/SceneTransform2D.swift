import Foundation

/// A 2D affine transform in scene space (y up): `p' = M·p + t`, with `M = [a c; b d]`.
public struct SceneTransform2D: Hashable, Sendable {
    public var a: Double, b: Double, c: Double, d: Double
    public var tx: Double, ty: Double

    public init(a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) {
        (self.a, self.b, self.c, self.d, self.tx, self.ty) = (a, b, c, d, tx, ty)
    }

    public static let identity = SceneTransform2D(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)

    /// A layer's local transform as WE composes it: scale, then rotate by `rotation` radians
    /// (counter-clockwise, y up), then move to `translation`.
    public static func layer(translation: SIMD2<Double>, rotation: Double, scale: SIMD2<Double>) -> SceneTransform2D {
        let cosine = cos(rotation), sine = sin(rotation)
        return SceneTransform2D(a: cosine * scale.x, b: sine * scale.x, c: -sine * scale.y, d: cosine * scale.y,
                                tx: translation.x, ty: translation.y)
    }

    public func apply(_ point: SIMD2<Double>) -> SIMD2<Double> {
        SIMD2(a * point.x + c * point.y + tx, b * point.x + d * point.y + ty)
    }

    /// Moves a direction: the linear part only.
    public func applyVector(_ vector: SIMD2<Double>) -> SIMD2<Double> {
        SIMD2(a * vector.x + c * vector.y, b * vector.x + d * vector.y)
    }

    /// `self` after `inner`: `(self ∘ inner)(p) = self(inner(p))`, as a parent's world transform
    /// composes a child's local one.
    public func concatenating(_ inner: SceneTransform2D) -> SceneTransform2D {
        SceneTransform2D(a: a * inner.a + c * inner.b, b: b * inner.a + d * inner.b,
                         c: a * inner.c + c * inner.d, d: b * inner.c + d * inner.d,
                         tx: a * inner.tx + c * inner.ty + tx, ty: b * inner.tx + d * inner.ty + ty)
    }

    public var determinant: Double { a * d - b * c }

    /// Nil when the transform flattens space (a zero scale), which nothing can be picked through.
    public var inverted: SceneTransform2D? {
        let det = determinant
        guard abs(det) > 1e-12 else { return nil }
        let ia = d / det, ib = -b / det, ic = -c / det, id = a / det
        return SceneTransform2D(a: ia, b: ib, c: ic, d: id, tx: -(ia * tx + ic * ty), ty: -(ib * tx + id * ty))
    }
}
