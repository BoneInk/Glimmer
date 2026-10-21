import Foundation

/// The renderer's side of a wallpaper instance's timelines and texture clocks
/// (docs/timeline-plan.md §2, T3): the `SceneAnimationSet`, kept across content rebuilt from the
/// same document, and what one frame reads of it (each animated object's fields, each layer's
/// sprite frame, the scripts' states). Confined to the render thread, like the renderer.
final class SceneRendererAnimations {
    /// The instance's timelines and texture clocks, advanced once per frame before the scripts
    /// run; nil without a scene document.
    private(set) var set: SceneAnimationSet?
    /// The document `set` was built from (`SceneTimelineSource`).
    private var key: (wallpaperID: String, signature: String)?
    /// Objects whose own fields a timeline drives, with where those fields sit in the set, and
    /// the fields' values this frame (`objectAnimations[position[id]]`).
    private var animatedObjects: [SceneObjectAnimation.Indices] = []
    private var objectAnimations: [SceneObjectAnimation] = []
    private var position: [String: Int] = [:]
    /// Where the timelines of the scene's own settings (`general.<field>`) sit in the set: only
    /// numbers and vectors, the types WE's setter writes (a bool, 6, is skipped at `0x14017242d`).
    private var sceneSettings: [SceneScriptSceneField: Int] = [:]
    /// Each animated layer's sprite frame this frame, by id (`spriteFrame(object:delta:)`).
    private var spriteFrames: [Int: Int32] = [:]
    /// The Wallpaper Editor's playhead, in seconds, while its timeline is open: each frame shows
    /// every timeline there (`SceneAnimationSet.scrub`) instead of advancing it. Kept across
    /// content rebuilt from the editor's changes.
    var scrubTime: Float?

    /// Drops everything (the content is gone).
    func clear() {
        set = nil
        key = nil
        animatedObjects = []
        objectAnimations = []
        position = [:]
        sceneSettings = [:]
    }

    /// Takes the content's timelines: a new set for a new document, or when new scripts started
    /// (`restart`: the old ones' created layers and calls are gone); otherwise the running set
    /// keeps its clocks, as WE keeps a scene's across a user property change.
    func setTimelines(_ source: SceneTimelineSource?, restart: Bool) {
        guard let source else {
            set = nil
            key = nil
            refreshAnimatedObjects()
            return
        }
        if restart || set == nil || key?.wallpaperID != source.wallpaperID || key?.signature != source.signature {
            set = SceneAnimationSet(document: source.document, wallpaperID: source.wallpaperID)
            key = (source.wallpaperID, source.signature)
        }
        refreshAnimatedObjects()
    }

    /// A layer `createLayer` made: its timelines join the set.
    func addObject(_ object: [String: SceneJSON], id: Int) {
        set?.addObject(object, id: id)
        refreshAnimatedObjects()
    }

    /// A destroyed layer: its timelines and texture animation leave the set.
    func removeObject(_ id: Int) {
        set?.removeObject(id)
        refreshAnimatedObjects()
    }

    /// What a script frame's `IAnimation` calls left of a timeline's clock, in the script frame
    /// that saw the set's frame `seenAt`. A script frame that overran the draw's wait comes back
    /// after later advances: the set replays them, and this frame draws the replayed value.
    func restore(_ site: SceneAnimationSite, time: Float, flags: SceneTimelineClock.Flags, rate: Float, seenAt: UInt64) {
        guard let set, set.restore(site, time: time, flags: flags, rate: rate, seenAt: seenAt) else { return }
        // Unchanged unless the restore replayed advances; restores are rare, so read them all.
        readObjects()
    }

    /// What a script frame's `ITextureAnimation` calls left of layer `id`'s override, in the
    /// script frame that saw the set's frame `seenAt`.
    func restoreTexture(_ control: SceneTextureAnimationControl, object id: Int, seenAt: UInt64) {
        guard let set else { return }
        set.textures.restore(control, object: id, replaying: set.deltas(since: seenAt))
        spriteFrames[id] = nil
    }

    /// An animated texture's layer shares its texture's clock (§2.7), frame times in sheet order.
    func registerTexture(object id: Int, texture: String, frameTimes: [Float]) {
        set?.textures.register(object: id, texture: texture, frameTimes: frameTimes)
    }

    /// The layers of rebuilt content: each animated one registered, every other layer's texture
    /// animation dropped (a rebuild that no longer has a layer mustn't keep its clock, TL16).
    func registerTextures(_ layers: [(id: Int, texture: String, frameTimes: [Float])]) {
        for layer in layers { registerTexture(object: layer.id, texture: layer.texture, frameTimes: layer.frameTimes) }
        set?.textures.retainObjects(Set(layers.map(\.id)))
    }

    /// The objects with an animated field of their own, whose values `advance` reads.
    private func refreshAnimatedObjects() {
        animatedObjects.removeAll()
        position.removeAll()
        sceneSettings.removeAll()
        for field in SceneScriptSceneField.allCases where field.type != .bool && !field.isCamera {
            sceneSettings[field] = set?.index(of: SceneAnimationSite(owner: .scene, key: field.rawValue))
        }
        var ids = Set<Int>()
        for site in set?.sites ?? [] where SceneObjectAnimation.keys.contains(site.key) {
            if case .object(let id) = site.owner { ids.insert(id) }
        }
        if let set {
            for id in ids.sorted() {
                guard let indices = SceneObjectAnimation.Indices(set, object: id) else { continue }
                position[String(id)] = animatedObjects.count
                animatedObjects.append(indices)
            }
        }
        readObjects()
    }

    private func readObjects() {
        objectAnimations.removeAll(keepingCapacity: true)
        guard let set else { return }
        for indices in animatedObjects { objectAnimations.append(SceneObjectAnimation(set, indices: indices)) }
    }

    // MARK: - Frame

    /// One frame of the instance's timelines (plan P1: before the scripts): every clock owner
    /// advances by the frame's scene delta and every animated field is sampled. Returns the
    /// events crossed, for the scripts.
    func advance(by delta: Float) -> [SceneAnimationEvent] {
        spriteFrames.removeAll(keepingCapacity: true)
        guard let set else { return [] }
        if let scrubTime {
            set.scrub(to: scrubTime)
            readObjects()
            return []
        }
        let frame = set.advance(by: delta)
        readObjects()
        return frame.events
    }

    /// The scene setting `general.<field>` as its timeline set it this frame: its first component;
    /// nil when no timeline drives it (or its value isn't finite).
    func sceneScalar(_ field: SceneScriptSceneField) -> Float? {
        sceneSettings[field].flatMap { set?.drawnComponents(at: $0)?.x }
    }

    /// Object `key`'s fields as its timelines set them this frame; nil when none is animated.
    func object(_ key: String) -> SceneObjectAnimation? {
        position[key].map { objectAnimations[$0] }
    }

    /// Field `field` of object `id` as its timeline set it this frame (a light's `intensity`);
    /// nil when no timeline drives it.
    func objectField(_ id: String, _ field: String) -> SIMD4<Float>? {
        guard let set, let object = Int(id),
              let index = set.index(of: SceneAnimationSite(owner: .object(object), key: field)) else { return nil }
        return set.drawnComponents(at: index)
    }

    /// The sprite frame layer `id` draws this frame: drawing binds the texture, which advances its
    /// shared clock once per frame (§2.7); a layer a script controls draws its override, which
    /// the set advanced with the frame. `delta` is the engine frame time.
    func spriteFrame(object id: Int, delta: Float) -> Int32 {
        if let drawn = spriteFrames[id] { return drawn }
        let frame = set?.drawnTextureFrame(object: id, delta: delta) ?? 0
        spriteFrames[id] = frame
        return frame
    }

    /// The sprite frame an effect or material texture shows this frame: the texture's shared clock,
    /// advanced by the first binding of the frame (T7). `texture` is its name, the clock's key.
    func materialTextureFrame(texture: String, frameTimes: () -> [Float], delta: Float) -> Int32 {
        set?.boundTextureFrame(texture: texture, frameTimes: frameTimes, delta: delta) ?? 0
    }

    /// The scripts' view of this frame: every timeline's `IAnimation` state, every layer's texture
    /// state and the events the advance crossed.
    func describe(into input: inout SceneScriptFrameInput, events: [SceneAnimationEvent]) {
        guard let set else { return }
        input.animationFrame = set.frameCounter
        input.animationEvents = events
        input.animations.reserveCapacity(set.sites.count)
        for (index, site) in set.sites.enumerated() { input.animations[site] = set.state(at: index) }
        for id in set.textures.objectIDs { input.textureAnimations[id] = set.textures.state(object: id) }
    }

    /// Resolves bound values against this frame's timelines.
    var values: LiveSceneValueContext { LiveSceneValueContext(animations: set) }
}
