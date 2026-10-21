import simd

/// How WE's object loop orders a scene's objects (0x14018aac0; docs/models-plan.md §2.4). Plain
/// scene.json order is `.sceneOrder`'s; `ordered(_:forward:)` applies the other modes.
struct SceneDrawOrderMode: Equatable {
    /// `customsortorder` without `transparentsorting` (flags & 0x3000 == 0x2000): a stable sort
    /// by each object's `sortorder`, ascending (comparator 0x140186980).
    var sortsBySortOrder = false
    /// `transparentsorting` in a perspective scene (flags & 0x1008 == 0x1000): every object not
    /// flagged translucent first, in list order, then the translucent ones back to front by
    /// `dot(origin, camera forward)`, descending (0x1401865c0).
    var splitsTranslucent = false

    /// Plain scene.json order: every orthographic scene without `customsortorder`, and the default.
    static let sceneOrder = SceneDrawOrderMode()

    init(sortsBySortOrder: Bool = false, splitsTranslucent: Bool = false) {
        self.sortsBySortOrder = sortsBySortOrder
        self.splitsTranslucent = splitsTranslucent
    }

    /// The flag tests of the object loop. Both flags set sort nothing: `customsortorder` needs
    /// `transparentsorting` off, and `transparentsorting` needs a perspective scene. An
    /// orthographic scene with camera parallax walks the same (possibly sorted) list with a
    /// per-object offset (0x14018ac84), which doesn't change the order.
    init(_ settings: SceneCameraSettings) {
        sortsBySortOrder = settings.customSortOrder && !settings.transparentSorting
        splitsTranslucent = settings.transparentSorting && settings.projection.isPerspective
    }

    /// Whether this mode reorders the list at all.
    var reorders: Bool { sortsBySortOrder || splitsTranslucent }

    /// `entries` (the object list in scene order, or the order scripts set) in the order WE draws
    /// them. `forward` is the frame camera's view direction, `transparentsorting`'s key.
    func ordered(_ entries: [SceneDrawEntry], forward: SIMD3<Float>) -> [SceneDrawItem] {
        if sortsBySortOrder {
            return entries.indices.sorted {
                (entries[$0].sortOrder, $0) < (entries[$1].sortOrder, $1)
            }.map { entries[$0].item }
        }
        guard splitsTranslucent else { return entries.map(\.item) }
        let opaque = entries.filter { !$0.translucent }.map(\.item)
        let translucent = entries.indices.filter { entries[$0].translucent }
        // The key WE computes per object (0x140186686): an object flagged 0x200 (fullscreen and
        // project layers) gets −∞ and draws last. Ties keep list order (WE's sorts are stable
        // insertion and merge sorts, 0x14019ee60).
        let keys = translucent.map { index -> Float in
            entries[index].drawsLast ? -.infinity : simd_dot(entries[index].origin, forward)
        }
        let sorted = translucent.indices.sorted { (keys[$0], -$0) > (keys[$1], -$1) }
        return opaque + sorted.map { entries[translucent[$0]].item }
    }
}

/// One thing the object loop draws: a layer (image or text), a particle system, or a model.
/// The payloads are indices into the renderer's own lists for this frame.
enum SceneDrawItem: Hashable {
    case layer(Int)
    case particles(Int)
    case model(Int)
}

/// An object as the draw-order modes see it.
struct SceneDrawEntry: Equatable {
    var item: SceneDrawItem
    /// `sortorder` (0 when not authored).
    var sortOrder = 0
    /// WE's translucent flag (object +0x120 bit 0x100): particles, lights, text, images whose
    /// first pass blends translucent or additive (0x1401fb34b), and models unless their meshes
    /// blend normal or alpha-to-coverage.
    var translucent = false
    /// The object's own `origin`, not its world position [I]: `transparentsorting`'s key.
    var origin = SIMD3<Float>.zero
    /// Object flag 0x200, set by an image model's `fullscreen` or `projectlayer` (0x1401fae07,
    /// 0x1401faf23): sorted last among the translucent objects.
    var drawsLast = false

    /// Whether an image is translucent (0x1401fb31b): its first pass blends neither normal nor
    /// alpha-to-coverage, or its model is `passthrough` (composition, fullscreen and project
    /// layers) without being a `solidlayer`.
    static func imageIsTranslucent(blending: String?, passthrough: Bool = false, solidLayer: Bool = false) -> Bool {
        switch blending?.lowercased() {
        case "translucent", "additive": return true
        // normal, alphatocoverage, and a value the enum parser doesn't know (the zeroed byte, normal).
        default: return passthrough && !solidLayer
        }
    }
}
