import Foundation

/// The parts of planning a shader that depend on its text alone, kept for the next material
/// that plans the same text: a stage's parsed declarations (`ShaderSource`, with its prelude
/// analysis) and a geometry stage folded into its vertex stage for one combo set
/// (`GeometryShaderEmulation.make`, which runs the preprocessor). Particle materials plan the
/// same few WE shaders over and over, within a load and across loads.
///
/// Keyed by the full text (and path, stage, combos), so a wallpaper's own copy of a shader never
/// reads another's entry. Held by the `ShaderVariantTranslator`, next to its variants, and as
/// long-lived. Thread-safe: `lock` owns the tables and counters.
final class ShaderSourceMemo {
    private let lock = NSLock()
    private var sources: [String: ShaderSource] = [:]
    private var emulations: [String: GeometryShaderEmulation] = [:]
    private var hits = 0
    private var misses = 0

    /// `text` parsed as `ShaderSourceLoader.load` parses an expanded stage.
    func source(stage: ShaderStage, path: String, text: String) -> ShaderSource {
        let key = "\(stage.rawValue)\u{0}\(path)\u{0}\(text)"
        if let cached = lock.withLock({ () -> ShaderSource? in
            let cached = sources[key]
            if cached != nil { hits += 1 }
            return cached
        }) { return cached }
        let parsed = ShaderSource(stage: stage, path: path, text: text, combos: ShaderSourceLoader.parseCombos(text),
                                  uniforms: ShaderSourceLoader.parseUniforms(text))
        return lock.withLock {
            misses += 1
            // A racing thread's copy wins, so every caller shares one prelude analysis.
            if let raced = sources[key] { return raced }
            sources[key] = parsed
            return parsed
        }
    }

    /// `GeometryShaderEmulation.make(sources, combos:, compiler:)`. A failure isn't kept.
    func geometryEmulation(_ sources: GeometryShaderEmulation.Sources, combos: [String: Int],
                           compiler: ShaderCompiler) throws -> GeometryShaderEmulation {
        let key = ([sources.path, sources.vertex, sources.geometry] + combos.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" })
            .joined(separator: "\u{0}")
        if let cached = lock.withLock({ () -> GeometryShaderEmulation? in
            let cached = emulations[key]
            if cached != nil { hits += 1 }
            return cached
        }) { return cached }
        let made = try GeometryShaderEmulation.make(sources, combos: combos, compiler: compiler)
        lock.withLock {
            misses += 1
            emulations[key] = made
        }
        return made
    }

    /// Hits and misses so far, for the load log.
    var counts: (hits: Int, misses: Int) { lock.withLock { (hits, misses) } }
}
