import simd

/// A particle system's `instanceoverride` values scripts wrote (`thisLayer.instance.rate`, a
/// script bound to `instanceoverride.alpha`, …), laid over the authored ones each step. Only
/// fields a script owns are set (`SceneScriptObjectState`).
struct SceneScriptInstanceOverrides: Equatable {
    var alpha: Float?
    var size: Float?
    var count: Float?
    var speed: Float?
    var lifetime: Float?
    var rate: Float?
    /// `colorn`, a number in lib.sceneScript.d.ts: it scales the tint's three components alike.
    var colorn: Float?
    var controlPoints: [Int: SIMD3<Float>] = [:]

    /// Nil when scripts own none of the instance fields.
    init?(_ state: SceneScriptObjectState) {
        alpha = state.scalar(.instanceAlpha)
        size = state.scalar(.instanceSize)
        count = state.scalar(.instanceCount)
        speed = state.scalar(.instanceSpeed)
        lifetime = state.scalar(.instanceLifetime)
        rate = state.scalar(.instanceRate)
        colorn = state.scalar(.instanceColorn)
        let points: [SceneScriptObjectField] = [.controlpoint0, .controlpoint1, .controlpoint2, .controlpoint3,
                                                .controlpoint4, .controlpoint5, .controlpoint6, .controlpoint7]
        for (index, field) in points.enumerated() {
            if let point = state.vector3(field) { controlPoints[index] = point }
        }
        if self == Self.none { return nil }
    }

    private init() {}

    private static let none = SceneScriptInstanceOverrides()

    /// `overrides` with the script's values in place of the authored ones. Numbers that can't be
    /// multipliers (NaN, ±Infinity) keep the authored value: they would poison every particle.
    func applied(to overrides: SceneParticleOverrides) -> SceneParticleOverrides {
        var result = overrides
        func finite(_ value: Float?) -> Float? { value.flatMap { $0.isFinite ? $0 : nil } }
        if let alpha = finite(alpha) { result.alpha = alpha }
        if let size = finite(size) { result.size = size }
        if let count = finite(count) { result.count = count }
        if let speed = finite(speed) { result.speed = speed }
        if let lifetime = finite(lifetime) { result.lifetime = lifetime }
        if let rate = finite(rate) { result.rate = rate }
        if let colorn = finite(colorn) { result.tint = SIMD3(repeating: colorn) }
        for (index, point) in controlPoints where point.x.isFinite && point.y.isFinite && point.z.isFinite {
            result.controlPoints[index] = point
        }
        return result
    }
}
