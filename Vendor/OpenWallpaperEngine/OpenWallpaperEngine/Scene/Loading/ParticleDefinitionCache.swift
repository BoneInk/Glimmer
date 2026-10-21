/// The shared parts (`ParticleSharedParts`) of the particle definitions one build has built, so
/// every further copy of a definition reuses them instead of building its material plans, shader
/// variants and textures again. A copy's own state (transform, instance overrides, object id,
/// control points, visibility and its user-property bindings) is still built per copy.
///
/// Scoped to one build (a content load, an object rebuild or a script's `createLayer`), which
/// holds the scene lock: the scene's engine combos and user properties can't change during it.
final class ParticleDefinitionCache {
    /// Everything the shared parts are built from besides the scene: the definition, its
    /// material and the blending that replaces the material's (an object's Scene Edit / Export edit,
    /// which only the object's own system takes). The renderers, flags and textures come from
    /// the definition and its material, which read the same throughout one build.
    struct Key: Hashable {
        let particlePath: String
        let materialPath: String
        let blending: String?
    }

    private struct Entry {
        /// Nil when the definition can't draw: every copy is skipped, as building it again would.
        let parts: ParticleSharedParts?
        /// The asset documents the build read, which each copy's object owns too.
        let reads: Set<String>
    }

    let timing = ParticleBuildTiming()
    /// False builds every copy in full (the reference the shared build is tested against).
    let sharesParts: Bool
    private var entries: [Key: Entry] = [:]

    init(sharesParts: Bool = true) {
        self.sharesParts = sharesParts
    }

    /// Distinct shared parts built so far.
    var count: Int { entries.count }

    /// The parts for `key`, built by `build` the first time; `noteReads` links the documents
    /// that first build read to each later copy.
    func parts(for key: Key, noteReads: (Set<String>) -> Void,
               build: () -> (ParticleSharedParts?, Set<String>)) -> ParticleSharedParts? {
        if sharesParts, let entry = entries[key] {
            noteReads(entry.reads)
            timing.countReused()
            return entry.parts
        }
        let (parts, reads) = build()
        if sharesParts { entries[key] = Entry(parts: parts, reads: reads) }
        timing.countBuilt()
        return parts
    }
}
