import Foundation

/// Where building a scene's particle systems spends its time: each step's own time, summed over
/// one build (a content load, an object rebuild or a script's `createLayer`) and logged once at
/// `.debug` when the build ends. Owned by that build, which holds the scene lock.
final class ParticleBuildTiming {
    enum Step: String, CaseIterable {
        /// The material json.
        case materialDocument = "material json"
        /// Texture 0, decoded once per build and shared (`buildTextures`).
        case texture
        case spriteSheet = "sprite sheet"
        /// The first renderer's material: shader variants, textures and constants.
        case materialPlan = "material plan"
        /// The simulation's configuration: emitters, initializers, operators, control points.
        case system
        case fallbackTexture = "fallback texture"
        /// The materials of the renderers after the first.
        case extraRenderers = "extra renderers"
    }

    private(set) var nanoseconds: [Step: UInt64] = [:]
    /// Systems built in full, and those whose shared parts came from an earlier copy.
    private(set) var built = 0
    private(set) var reused = 0

    func measure<T>(_ step: Step, _ body: () -> T) -> T {
        let start = DispatchTime.now().uptimeNanoseconds
        defer { nanoseconds[step, default: 0] += DispatchTime.now().uptimeNanoseconds - start }
        return body()
    }

    func countBuilt() { built += 1 }
    func countReused() { reused += 1 }

    /// One line: each step's milliseconds, slowest first; nil when nothing was built.
    var summary: String? {
        guard built + reused > 0 else { return nil }
        let steps = nanoseconds.sorted { $0.value > $1.value }
            .map { String(format: "%@ %.1f ms", $0.key.rawValue, Double($0.value) / 1e6) }
        return "\(built + reused) particle systems (\(built) built, \(reused) sharing an earlier copy's parts): "
            + steps.joined(separator: ", ")
    }
}
