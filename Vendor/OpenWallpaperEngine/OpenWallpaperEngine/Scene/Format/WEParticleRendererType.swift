/// A particle renderer's `name`: WE's four renderer types (docs/models-plan.md, "Renderers"), matched
/// exactly. Any other name isn't a WE renderer; the builder logs it and draws sprites.
enum WEParticleRendererType: String, CaseIterable {
    case sprite, spritetrail, rope, ropetrail

    /// `rope` and `ropetrail` draw strips (`ParticleVertexFormat.rope`); the others draw quads.
    var isRope: Bool { self == .rope || self == .ropetrail }
}
