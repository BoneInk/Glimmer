//
//  SceneParticleEmitterSpace.swift
//  Open Wallpaper Engine
//

import simd

/// Maps a particle system's emitter-local geometry into scene space with the emitter object's
/// world transform (its own and its parents' origin, scale and angle).
struct SceneParticleEmitterSpace {
    let world: SceneAffineTransform

    /// Where the emitter sits in scene space.
    var origin: SIMD2<Float> { world.translation }

    /// A spawn box's half extent (`distancemax`), scaled by the world scale on each axis.
    func extent(_ distance: SIMD2<Float>) -> SIMD2<Float> {
        simd_abs(distance * world.axisScale)
    }

    /// An emitter-local offset given y-down (as the particle builder stores control points and
    /// position offsets), scaled and rotated into scene space and returned y-down.
    func offset(_ yDown: SIMD2<Float>) -> SIMD2<Float> { offsetLinear * yDown }

    /// `offset` as a matrix: the world scale and rotation conjugated by the y flip.
    var offsetLinear: simd_float2x2 {
        let flip = simd_float2x2(diagonal: SIMD2<Float>(1, -1))
        return flip * world.linear * flip
    }

    /// The emitter's world rotation (and any mirroring) without its scale. Velocities and
    /// gravity are directions in emitter space: a rotated parent turns them, a scaled one doesn't.
    var rotation: simd_float2x2 {
        func unit(_ v: SIMD2<Float>, _ fallback: SIMD2<Float>) -> SIMD2<Float> {
            simd_length(v) > 1e-6 ? simd_normalize(v) : fallback
        }
        return simd_float2x2(columns: (unit(world.linear.columns.0, SIMD2(1, 0)),
                                       unit(world.linear.columns.1, SIMD2(0, 1))))
    }

    /// An emitter-local direction (y-up, as velocities and gravity are authored) in scene space.
    func direction(_ yUp: SIMD2<Float>) -> SIMD2<Float> { rotation * yUp }
}
