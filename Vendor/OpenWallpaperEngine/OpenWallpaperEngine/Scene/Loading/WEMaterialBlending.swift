/// A material pass's `blending`, as WE's pass loader parses it into its blend byte (+0x1f0):
/// normal 0, translucent 1, additive 2, alphatocoverage 3. A value the parser doesn't know
/// leaves the zeroed byte, normal.
///
/// Scene Edit / Export sets a layer's (`sceneObjectBlendingKey`), which the scene loader puts in
/// place of its material's first pass's (`ImageMaterialPlanBuilder.blending`,
/// `ParticleMaterialPlanBuilder.blending`), so it draws, sorts and picks its combos
/// (`ImageMaterialPlanBuilder.blendingCombos`) as that material would.
enum WEMaterialBlending: String, CaseIterable {
    case normal
    case translucent
    case additive
    case alphaToCoverage = "alphatocoverage"

    /// The values an image layer's material draws with (`ImageMaterialRenderer.applyBlending`).
    static let imageLayer: [WEMaterialBlending] = [.normal, .translucent, .additive, .alphaToCoverage]
    /// The values a particle system's material draws with (`ParticleMaterialRenderer`): it has no
    /// alpha-to-coverage draw.
    static let particleSystem: [WEMaterialBlending] = [.normal, .translucent, .additive]

    /// A pass's authored value, in any case; nil for a value the parser doesn't know.
    init?(authored value: String) {
        self.init(rawValue: value.lowercased())
    }

    /// An image's pass without `blending` draws normal (`ImageMaterialPlanBuilder`), a
    /// particle system's translucent (`ParticleMaterialPlanBuilder`).
    static func authored(_ value: String?, particle: Bool) -> WEMaterialBlending {
        value.flatMap { WEMaterialBlending(authored: $0) } ?? (particle ? .translucent : .normal)
    }
}
