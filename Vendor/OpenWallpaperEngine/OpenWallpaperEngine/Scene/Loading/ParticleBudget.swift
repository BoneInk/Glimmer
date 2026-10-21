/// The user's particle budget (Settings → Performance, `GSParticleBudget`): the most particles one
/// scene may hold at once, over all its systems.
///
/// A scene whose authored capacity exceeds it is thinned, not cut off: every system's maximum and
/// emission rate are scaled by the same factor (`SceneMetalParticleSystem.budgetScale`), the way
/// WE's own `count` and `rate` instance overrides thin a system, so each keeps its lifetime, spread
/// and look with fewer particles. A scene within the budget is left exactly as authored.
enum ParticleBudget {
    /// What applying a budget did to a scene's systems.
    struct Report: Equatable {
        /// The particles the scene's systems can hold as authored.
        let authored: Int
        let budget: Int
        /// The factor on every system's maximum and rate (< 1).
        let scale: Float
    }

    /// The most particles `system` holds at once as authored, per instance times its instances when
    /// it runs as instances (an event child, or a static child of one:
    /// `ParticleChildLink.maximumInstances`). Per instance that is its `maxcount` times its `count`
    /// override (unless its flags switch that off), as the simulations bound it
    /// (`ParticleFrameInputs.maximum`, `ParticleGPUSystem.maximumCount`), or what its emitters can
    /// keep alive if that is less (`sustained(by:)`): many systems carry a `maxcount` far above what
    /// they ever emit (WE's rain preset holds 100 000 and shows a few hundred), and counting it would
    /// thin every other system of the scene for particles that never exist.
    static func capacity(of system: SceneMetalParticleSystem) -> Int {
        let overrides = system.overrides.ignoring(system.ignoredOverrides)
        var perInstance = max(Double(system.maximumParticleCount) * Double(max(overrides.count, 0)), 0).rounded()
        if let sustained = sustained(by: system, overrides: overrides) { perInstance = min(perInstance, sustained) }
        let instances = system.isInstanced ? Double(max(system.link?.maximumInstances ?? 0, 0)) : 1
        // Saturating: a NaN product counts as no particles, an infinite one as the most there can be.
        return Int(saturating: perInstance * instances, in: 0...Int.max / 2)
    }

    /// The sum of `capacities`, saturating at `Int.max` instead of overflowing.
    static func total(_ capacities: [Int]) -> Int {
        capacities.reduce(0) { sum, capacity in
            let (result, overflow) = sum.addingReportingOverflow(max(capacity, 0))
            return overflow ? Int.max : result
        }
    }

    /// The most particles `system`'s emitters keep alive: each emitter's rate (times the `count`
    /// override, which WE binds it to; audio only ever lowers it) over the longest lifetime its `lifetimerandom` gives
    /// (WE's default 1 s without one, times the `lifetime` override), one more for the carried
    /// fraction, plus its `instantaneous` burst. Nil when a remap writes the lifetime, which this
    /// can't bound; then only `maxcount` counts.
    static func sustained(by system: SceneMetalParticleSystem, overrides: SceneParticleOverrides) -> Double? {
        let program = system.program
        let remapsLifetime = program.initializers.contains {
            $0.kind == .remapInitialValue && ParticleProgramEncoding.RemapCode.output($0.record.header.w) == 1
        } || program.operators.contains {
            $0.kind == .remapValue && ParticleProgramEncoding.RemapCode.output($0.record.header.w) == 1
        }
        guard !remapsLifetime else { return nil }
        // The last `lifetimerandom` is the one a particle keeps (they run in order).
        let authored = program.initializers.last { $0.kind == .lifetimeRandom }.map { max($0.record.a.x, $0.record.a.y) } ?? 1
        let lifetime = Double(max(authored, 0.001)) * Double(max(overrides.lifetime, 0))
        let rate = Double(max(overrides.count, 0))
        return system.emitters.reduce(0) { total, emitter in
            total + (Double(emitter.rate) * rate * lifetime).rounded(.up) + 1 + Double(max(emitter.instantaneous, 0))
        }
    }

    /// The factor that brings `authored` particles within `budget`: 1 when they fit or there is no
    /// budget.
    static func scale(authored: Int, budget: Int?) -> Float {
        guard let budget, budget > 0, authored > budget else { return 1 }
        return Float(Double(budget) / Double(authored))
    }

    /// Scales `systems` (a scene's, children and instances included) to fit `budget` particles;
    /// nil, with every system untouched, when they already fit or there is no budget.
    @discardableResult
    static func apply(_ budget: Int?, to systems: inout [SceneMetalParticleSystem]) -> Report? {
        let authored = total(systems.map { capacity(of: $0) })
        let factor = scale(authored: authored, budget: budget)
        guard factor < 1, let budget else { return nil }
        for index in systems.indices { systems[index].budgetScale = factor }
        return Report(authored: authored, budget: budget, scale: factor)
    }
}
