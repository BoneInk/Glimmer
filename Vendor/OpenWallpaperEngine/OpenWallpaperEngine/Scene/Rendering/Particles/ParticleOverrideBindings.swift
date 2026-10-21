/// The instance overrides WE's particle parser binds into operator and initializer records.
///
/// `wallpaper64.exe`'s parser (0x1401c1c70) writes a binding next to each bound field: the
/// override's offset in the instance's key table (0x14024d980: size 0xcc, count 0xd0, speed 0xd4,
/// rate 0xdc) and where the field sits in the record. Every frame the bindings rewrite their fields
/// as `authored × override` (0x1401d17c0), so a range's minimum and maximum both scale. A system's
/// `flags` switch a binding off (0x10 speed, 0x80 size; `SceneParticleOverrides.Parts`).
///
/// Bound here (the records' layouts are `ParticleOperatorBuilder`'s and `ParticleInitializerBuilder`'s):
/// - speed, operators: `movement` gravity (0x1401cb52f), `angularmovement` force (0x1401cb85e),
///   `oscillateposition` frequencymin/max (0x1401cc416), `controlpointattract` scale (0x1401ccd7b),
///   `turbulence` speedmin/max (0x1401cd872), `vortex` and `vortex_v2` speedinner/outer
///   (0x1401cdddc, 0x1401ce39b).
/// - speed, initializers: `inheritcontrolpointvelocity` min/max (0x1401c870f) and
///   `mapsequencearoundcontrolpoint` speedmin/max (0x1401ca151). `velocityrandom`,
///   `angularvelocityrandom` and `turbulentvelocityrandom` (0x1401c855f, 0x1401c98ff, 0x1401c8c73)
///   and the emitters' speeds scale at spawn instead (`ParticleFrameInputs.spawnScale.w`), which is
///   the same product.
/// - size: `sizechange` startvalue/endvalue (0x1401cbb48); `sizerandom` scales at spawn.
/// - rate: the `timescale` of `turbulence` and `turbulentvelocityrandom` (0x1401cd7ba, 0x1401c8bc5).
///
/// `count` is bound to the emitters and the map sequences' counts, which `ParticleFrameInputs` scales.
enum ParticleOverrideBindings {
    /// An operator's record with the overrides bound into it.
    static func bind(_ record: ParticleProgramOp, operator kind: ParticleOperatorKind,
                     overrides: SceneParticleOverrides) -> ParticleProgramOp {
        var record = record
        let speed = overrides.speed
        switch kind {
        case .movement, .angularMovement:
            record.a.x *= speed
            record.a.y *= speed
            record.a.z *= speed
        case .oscillatePosition:
            record.b.x *= speed
            record.b.y *= speed
        case .controlPointAttract:
            record.b.x *= speed
        case .turbulence:
            record.b.y *= speed
            record.b.z *= speed
            record.b.w *= overrides.rate
        case .vortex:
            record.c.z *= speed
            record.c.w *= speed
        case .vortexV2:
            record.b.z *= speed
            record.b.w *= speed
        case .sizeChange:
            record.a.x *= overrides.size
            record.a.y *= overrides.size
        default:
            break
        }
        return record
    }

    /// An initializer's record with the overrides bound into it.
    static func bind(_ record: ParticleProgramOp, initializer kind: ParticleInitializerKind,
                     overrides: SceneParticleOverrides) -> ParticleProgramOp {
        var record = record
        let speed = overrides.speed
        switch kind {
        case .inheritControlPointVelocity:
            record.a.x *= speed
            record.a.y *= speed
        case .mapSequenceAroundControlPoint:
            record.b.x *= speed
            record.b.y *= speed
            record.b.z *= speed
            record.c.x *= speed
            record.c.y *= speed
            record.c.z *= speed
        case .turbulentVelocityRandom:
            record.b.x *= overrides.rate
        default:
            break
        }
        return record
    }
}
