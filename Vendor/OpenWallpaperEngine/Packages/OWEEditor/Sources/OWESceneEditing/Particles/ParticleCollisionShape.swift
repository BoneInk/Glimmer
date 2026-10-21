import Foundation

/// A particle system's collision operator as Show Particle Collision draws it in a 2D scene, in
/// scene space, placed as the renderer places it (`ParticleCollision.placed`): from the emitter's
/// space (its world transform) with WE's 2D defaults (wallpaper64.exe 0x1401c0540, 0x1401c0740,
/// 0x1401c0870), or on a control point when its flag 1 says so.
public enum ParticleCollisionShape: Hashable, Sendable {
    /// A plane's line or a rectangle's edge; particles stay on `normal`'s side.
    case segment(from: SIMD2<Double>, to: SIMD2<Double>, normal: SIMD2<Double>)
    case circle(centre: SIMD2<Double>, radius: Double)
    /// `collisionbounds`: the scene's rectangle from its bottom-left corner.
    case rectangle(size: SIMD2<Double>)

    /// The shapes of `operators` (the definition's `operator` list) for an emitter at `world`.
    public static func shapes(_ operators: [[String: SceneJSONValue]], world: SceneTransform2D, sceneSize: SIMD2<Double>,
                              controlPoint: (Int) -> SIMD2<Double>? = { _ in nil }) -> [ParticleCollisionShape] {
        let scale = abs(world.determinant).squareRoot()
        // The world's rotation without its scale.
        func direction(_ v: SIMD3<Double>) -> SIMD2<Double>? {
            let xAxis = world.applyVector(SIMD2(1, 0)), yAxis = world.applyVector(SIMD2(0, 1))
            func unit(_ a: SIMD2<Double>) -> SIMD2<Double> {
                let length = (a * a).sum().squareRoot()
                return length > 1e-9 ? a / length : a
            }
            let turned = unit(xAxis) * v.x + unit(yAxis) * v.y
            let length = (turned * turned).sum().squareRoot()
            return length > 1e-6 ? turned / length : nil
        }
        func vector(_ item: [String: SceneJSONValue], _ key: String, _ fallback: SIMD3<Double>) -> SIMD3<Double> {
            let values = SceneVector.components(item[key], fallback: [fallback.x, fallback.y, fallback.z])
            return SIMD3(values[safe: 0] ?? 0, values[safe: 1] ?? 0, values[safe: 2] ?? 0)
        }
        func number(_ item: [String: SceneJSONValue], _ key: String, _ fallback: Double) -> Double {
            item[key]?.doubleValue ?? fallback
        }
        let origin = world.apply(.zero)
        let diagonal = max((sceneSize * sceneSize).sum().squareRoot(), 1)
        var result: [ParticleCollisionShape] = []
        for item in operators {
            let flags = Int(item["flags"]?.doubleValue ?? 0)
            let anchor = flags & 1 != 0 ? controlPoint(min(max(Int(item["controlpoint"]?.doubleValue ?? 0), 0), 7)) : nil
            switch item["name"]?.stringValue {
            case "collisionplane":
                guard let n = direction(vector(item, "plane", SIMD3(0, 1, 0))) else { continue }
                let d = anchor.map { ($0 * n).sum() } ?? number(item, "distance", -150) * scale + (n * origin).sum()
                let tangent = SIMD2(-n.y, n.x)
                let centre = n * d + tangent * ((sceneSize / 2) * tangent).sum()
                result.append(.segment(from: centre - tangent * diagonal, to: centre + tangent * diagonal, normal: n))
            case "collisionsphere":
                let local = vector(item, "origin", SIMD3(0, -200, 0))
                result.append(.circle(centre: anchor ?? world.apply(SIMD2(local.x, local.y)), radius: number(item, "radius", 50) * scale))
            case "collisionquad":
                let normal = vector(item, "plane", SIMD3(0, 1, 0)), forward = vector(item, "forward", SIMD3(0, 0, 1))
                let right3 = SIMD3(normal.y * forward.z - normal.z * forward.y, normal.z * forward.x - normal.x * forward.z,
                                   normal.x * forward.y - normal.y * forward.x)
                guard let n = direction(normal), let right = direction(right3) else { continue }
                let local = vector(item, "origin", SIMD3(0, -150, 0))
                let centre = anchor ?? world.apply(SIMD2(local.x, local.y))
                let size = SceneVector.components(item["size"], fallback: [200, 200])
                let half = (size[safe: 0] ?? 200) / 2 * scale
                result.append(.segment(from: centre - right * half, to: centre + right * half, normal: n))
            case "collisionbounds":
                result.append(.rectangle(size: sceneSize))
            default:
                continue
            }
        }
        return result
    }
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
