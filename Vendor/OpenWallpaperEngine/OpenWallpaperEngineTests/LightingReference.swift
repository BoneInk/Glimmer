import simd
@testable import OpenWallpaperEngine

/// A CPU model of `genericimage4.frag`'s `LIGHTING` path (docs/lighting-plan.md §1.4, §2.1) in
/// float32, written from WE's shader text rather than from our translation of it:
/// `PerformLighting_V1` as `LightingV1Require` generates it for points, spots, tubes and
/// directionals without shadows or cookies, `ComputePBRLightShadow(Infinite)` and its helpers from
/// `common_pbr_2.h` (the GLSL branches, `HDR` off), then `CombineLighting`: ambient·albedo + light.
///
/// Lights are given the way a scene authors them, not packed: a light's direction is its local +X
/// through WE's `Rz(z)·Ry(y)·Rx(x)` (0x1401dd630), so a test against this model also checks the
/// packer and the rotation convention.
enum LightingReference {
    struct Light {
        var kind: WELightKind
        var position: SIMD3<Float>
        /// `angles` in radians.
        var angles: SIMD3<Float> = .zero
        var color: SIMD3<Float> = SIMD3(repeating: 1)
        var intensity: Float = 1
        var radius: Float = 1
        var exponent: Float = 2
        /// Half-angles in degrees.
        var innerCone: Float = 20
        var outerCone: Float = 30
        /// Tube end B in the light's local space.
        var controlPoint: SIMD3<Float> = SIMD3(2, 0, 0)

        /// WE's row 0 of the light's rotation: its local +X in the world.
        var forward: SIMD3<Float> {
            let cy = cos(angles.y), sy = sin(angles.y), cz = cos(angles.z), sz = sin(angles.z)
            return SIMD3(cy * cz, cy * sz, -sy)
        }

        /// The light's local point `p` in the world (unit scale).
        func world(_ p: SIMD3<Float>) -> SIMD3<Float> {
            let cx = cos(angles.x), sx = sin(angles.x), cy = cos(angles.y), sy = sin(angles.y)
            let cz = cos(angles.z), sz = sin(angles.z)
            // Rows of WE's row-major `Rz·Ry·Rx` (row k: local axis k in the world).
            let row0 = SIMD3<Float>(cy * cz, cy * sz, -sy)
            let row1 = SIMD3<Float>(sy * cz * sx - cx * sz, sy * sz * sx + cx * cz, sx * cy)
            let row2 = SIMD3<Float>(cx * cz * sy + sx * sz, cx * sz * sy - sx * cz, cx * cy)
            return position + p.x * row0 + p.y * row1 + p.z * row2
        }
    }

    struct Surface {
        var albedo: SIMD3<Float>
        /// The shading normal in the world, normalised.
        var normal: SIMD3<Float>
        var roughness: Float
        var metallic: Float
        var specularTint: SIMD3<Float> = SIMD3(repeating: 1)
    }

    /// The lit colour at `position` (world, scene units), `SCENE_ORTHO`: the view vector is (0, 0, 1).
    static func shade(_ surface: Surface, at position: SIMD3<Float>, lights: [Light], ambient: SIMD3<Float>) -> SIMD3<Float> {
        let view = SIMD3<Float>(0, 0, 1)
        let f0 = simd_mix(SIMD3(repeating: 0.04), surface.albedo, SIMD3(repeating: surface.metallic))
        var light = SIMD3<Float>(repeating: 0)
        for source in lights {
            let color = source.color * source.intensity
            switch source.kind {
            case .point:
                light += pbr(surface, normal: surface.normal, delta: source.position - position, view: view,
                             color: color, radius: source.radius, exponent: source.exponent, f0: f0)
            case .spot:
                let delta = source.position - position
                let cosine = -simd_dot(simd_normalize(delta), source.forward)
                let cone = smoothstep(cos(source.outerCone * .pi / 180), cos(source.innerCone * .pi / 180), cosine)
                light += pbr(surface, normal: surface.normal, delta: delta, view: view, color: color * cone,
                             radius: source.radius, exponent: source.exponent, f0: f0)
            case .tube:
                let delta = pointSegmentDelta(position, source.position, source.world(source.controlPoint))
                light += pbr(surface, normal: surface.normal, delta: delta, view: view, color: color,
                             radius: source.radius, exponent: source.exponent, f0: f0)
            case .directional:
                light += pbrInfinite(surface, normal: surface.normal, toLight: -source.forward, view: view,
                                     color: color, f0: f0)
            case .legacyPoint:
                continue
            }
        }
        return ambient * surface.albedo + light
    }

    // MARK: - common_pbr_2.h

    static func pointSegmentDelta(_ p: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
        let delta = b - a
        let v = simd_dot(delta, delta)
        if v == 0 { return a - p }
        return a + saturate(simd_dot(p - a, b - a) / v) * (b - a) - p
    }

    private static func distributionGGX(_ n: SIMD3<Float>, _ h: SIMD3<Float>, _ roughness: Float) -> Float {
        let r2 = roughness * roughness
        let r4 = r2 * r2
        let nh = max(simd_dot(n, h), 0)
        let denominator = nh * nh * (r4 - 1) + 1
        return r4 / (Float.pi * denominator * denominator)
    }

    private static func schlickGGX(_ nv: Float, _ roughness: Float) -> Float {
        let base = roughness + 1
        let k = base * base / 8
        return nv / (nv * (1 - k) + k)
    }

    private static func geoSmith(_ n: SIMD3<Float>, _ v: SIMD3<Float>, _ l: SIMD3<Float>, _ roughness: Float) -> Float {
        schlickGGX(max(simd_dot(n, v), 0.001), roughness) * schlickGGX(max(simd_dot(n, l), 0.001), roughness)
    }

    private static func fresnelSchlick(_ theta: Float, _ f0: SIMD3<Float>) -> SIMD3<Float> {
        f0 + (SIMD3(repeating: 1) - f0) * pow(max(1 - theta, 0.001), 5)
    }

    /// `ComputePBRLightShadow` with shadow factor 1.
    private static func pbr(_ surface: Surface, normal n: SIMD3<Float>, delta: SIMD3<Float>, view v: SIMD3<Float>,
                            color: SIMD3<Float>, radius: Float, exponent: Float, f0: SIMD3<Float>) -> SIMD3<Float> {
        let distance = simd_length(delta)
        let l = delta / distance
        let falloff = saturate(1 - distance / radius)
        let fltMin: Float = 6.103515625e-5
        let radiance = color * (falloff - fltMin >= 0 ? pow(falloff + fltMin, exponent) : 0)
        return brdf(surface, n: n, l: l, v: v, f0: f0) * radiance
    }

    /// `ComputePBRLightShadowInfinite` with shadow factor 1.
    private static func pbrInfinite(_ surface: Surface, normal n: SIMD3<Float>, toLight l: SIMD3<Float>,
                                    view v: SIMD3<Float>, color: SIMD3<Float>, f0: SIMD3<Float>) -> SIMD3<Float> {
        brdf(surface, n: n, l: l, v: v, f0: f0) * color
    }

    /// `(diffuse·albedo/π + specular·tint)·NL`, the part both light functions share.
    private static func brdf(_ surface: Surface, n: SIMD3<Float>, l: SIMD3<Float>, v: SIMD3<Float>,
                             f0: SIMD3<Float>) -> SIMD3<Float> {
        let h = simd_normalize(v + l)
        let ndf = distributionGGX(n, h, surface.roughness)
        let g = geoSmith(n, v, l, surface.roughness)
        let f = fresnelSchlick(max(simd_dot(h, v), 0), f0)
        let numerator = ndf * g * f
        let diffuse = (1 - surface.metallic) * (SIMD3(repeating: 1) - f)
        let nl = max(simd_dot(n, l), 0)
        let denominator = 4 * max(simd_dot(n, v), 0) * nl
        let specular = numerator / max(denominator, 0.001)
        return (diffuse * surface.albedo / Float.pi + specular * surface.specularTint) * nl
    }

    static func saturate(_ x: Float) -> Float { min(max(x, 0), 1) }

    static func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
        let t = saturate((x - edge0) / (edge1 - edge0))
        return t * t * (3 - 2 * t)
    }

    /// The shading normal of a normal-map texel: `rg·2 − 1`, z from the unit length, normalised,
    /// then through the layer's tangent space (its x and y axes, and +z), which the shader doesn't
    /// normalise again.
    static func mappedNormal(_ texel: SIMD2<Float>, tangent: SIMD3<Float>, bitangent: SIMD3<Float>) -> SIMD3<Float> {
        let xy = texel * 2 - 1
        let local = simd_normalize(SIMD3(xy.x, xy.y, max(0, 1 - xy.x * xy.x - xy.y * xy.y).squareRoot()))
        return local.x * tangent + local.y * bitangent + local.z * SIMD3(0, 0, 1)
    }
}
