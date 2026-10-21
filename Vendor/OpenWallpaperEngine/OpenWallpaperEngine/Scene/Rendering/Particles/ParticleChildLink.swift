import simd

/// How a child particle system hangs off its parent (a `children` entry).
///
/// - `static`: one child placed on the parent's emitter with the link's origin, scale and angles.
///   Under an instanced parent (see below) each parent instance gets its own, emitting while that
///   instance lasts.
/// - `follow`: every parent particle that passes `probability` gets an instance of the child
///   that follows it and dies with it, taking its particles along.
/// - `spawn`: the same on spawn, but the instance's particles outlive the parent particle.
/// - `death`: an instance where a parent particle dies, emitting for that one step.
///
/// Event children are *instanced*: up to `maximumInstances` copies of the child run at once, each
/// with its own position (`translate(T_i)` before the shared emitter transform), burst, emission
/// and at most the child's `maxcount` particles. A static child of an instanced system is
/// instanced too, one instance per parent instance.
struct ParticleChildLink {
    enum Kind: UInt32 {
        case `static` = 1, follow, spawn, death
    }

    /// Index of the parent in the scene's particle systems (it always comes first).
    var parentIndex: Int
    let kind: Kind
    /// The link's origin, scale and angles relative to the parent's emitter, in the plane: the x
    /// and y of its turned axes, as a tilted layer's (`ParticleLinkSpace` keeps the depth).
    let local: SceneLocalTransform
    /// Chance an event makes an instance.
    let probability: Float
    /// Instances that may run at once: the link's `maxcount` (default 10) for event children, the
    /// parent's for a static child of an instanced parent; 1 otherwise.
    let maximumInstances: Int
    /// Whether the child runs as instances.
    let instanced: Bool
    /// Link flag 1: the child's control points from this index on are the parent's particles
    /// (`particleLinkPoints`); nil without it.
    var controlPointStart: Int? = nil
    /// Link flag 2 (the editor's "Restart with periodic emission"): each time a periodic emitter of
    /// the parent starts a period, the child starts over (`wallpaper64.exe` 0x14022f790 →
    /// 0x14022f6c0): its time, each emitter's delay, duration, burst, carry and period, and its
    /// sequences. It doesn't touch colours: the instance colour reaches the child either way.
    var restartsWithParentPeriod = false

    /// The child's emitter transform given its parent's this frame. Event instances sit at their
    /// parent particle, so for them it carries only the parent's scale and rotation; each instance
    /// adds its own position.
    func emitter(parent: SceneAffineTransform) -> SceneAffineTransform {
        let base = kind == .static ? parent : SceneAffineTransform(linear: parent.linear, translation: .zero)
        return base * SceneAffineTransform(local)
    }
}
