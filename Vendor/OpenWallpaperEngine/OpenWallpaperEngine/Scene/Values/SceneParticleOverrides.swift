import simd

/// A particle object's `instanceoverride`, resolved against the current user properties.
///
/// Scalars multiply the particle file's values (`count` the emitters' rates and the particle
/// budget, `size`/`alpha`/`lifetime` their initial ranges, `speed` the initial velocities; the
/// operator fields WE also binds, and `rate`, are in `ParticleOverrideBindings`).
/// `colorn` (0–1) or `color` (0–255) tints the initial colour, and `brightness` scales it.
struct SceneParticleOverrides: Equatable {
    var rate: Float = 1
    var count: Float = 1
    var size: Float = 1
    var alpha: Float = 1
    var speed: Float = 1
    var lifetime: Float = 1
    var brightness: Float = 1
    var tint = SIMD3<Float>(repeating: 1)
    /// `controlpoint<n>`: where control point n sits, relative to the emitter, as authored.
    var controlPoints: [Int: SIMD3<Float>] = [:]
    /// `controlpointangle<n>`: control point n's orientation, radians (x, then y, then z).
    var controlPointAngles: [Int: SIMD3<Float>] = [:]

    init() {}

    /// The overrides a particle system's `flags` can switch off (`wallpaper64.exe`: bits 8 colour,
    /// 0x10 speed, 0x20 count, 0x40 lifetime, 0x80 size).
    struct Parts: OptionSet, Equatable {
        let rawValue: Int
        static let color = Parts(rawValue: 8), speed = Parts(rawValue: 0x10), count = Parts(rawValue: 0x20)
        static let lifetime = Parts(rawValue: 0x40), size = Parts(rawValue: 0x80)

        /// The parts a system's `flags` switch off.
        init(systemFlags: Int) { rawValue = systemFlags & 0xF8 }
        init(rawValue: Int) { self.rawValue = rawValue }
    }

    /// These overrides with `parts` back at 1.
    func ignoring(_ parts: Parts) -> SceneParticleOverrides {
        var overrides = self
        if parts.contains(.color) {
            overrides.tint = SIMD3(repeating: 1)
            overrides.brightness = 1
        }
        if parts.contains(.speed) { overrides.speed = 1 }
        if parts.contains(.count) { overrides.count = 1 }
        if parts.contains(.lifetime) { overrides.lifetime = 1 }
        if parts.contains(.size) { overrides.size = 1 }
        return overrides
    }

    /// `object` is the particle system's object id, whose `instanceoverride` timelines
    /// (`SceneAnimationOwner.particleInstance`) beat the user-bound and authored values (§2.6).
    init(_ override: WEInstanceOverride?, in context: SceneValueContext, object: Int? = nil) {
        guard let override else { return }
        // Scripts run in the particle runtime; the timeline, the user binding and the literal resolve here.
        func value(_ field: SceneInstanceOverrideField) -> ShaderValue? {
            guard let raw = override.values[field] else { return nil }
            if let object, raw.animation != nil,
               let animated = context.animationValue(SceneAnimationSite(owner: .particleInstance(object), key: field.rawValue)) {
                return ShaderValue(components: animated)
            }
            if let source = raw.userBindingSource { return SceneValueResolver.resolve(source, in: context) }
            return raw.literalString.flatMap(ShaderValue.init(string:))
        }
        func scalar(_ field: SceneInstanceOverrideField) -> Float? { value(field)?.float }
        func vector(_ field: SceneInstanceOverrideField) -> SIMD3<Float>? {
            value(field).map { $0.components.count == 1 ? SIMD3(repeating: $0.float) : $0.vec3 }
        }
        rate = scalar(.rate) ?? 1
        count = scalar(.count) ?? 1
        size = scalar(.size) ?? 1
        alpha = scalar(.alpha) ?? 1
        speed = scalar(.speed) ?? 1
        lifetime = scalar(.lifetime) ?? 1
        brightness = scalar(.brightness) ?? 1
        if let colorn = vector(.colorn) {
            tint = colorn
        } else if let color = vector(.color) {
            tint = color / 255
        }
        for id in 0..<8 {
            guard let field = SceneInstanceOverrideField.controlPoint(id), let value = value(field) else { continue }
            controlPoints[id] = value.vec3
        }
        for id in 0..<8 {
            guard let field = SceneInstanceOverrideField.controlPointAngle(id), let value = value(field) else { continue }
            controlPointAngles[id] = value.vec3
        }
    }
}
