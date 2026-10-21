import simd

/// A Puppet Warp image's skeleton in motion (docs/models-plan.md §2.8, §2.13, §4.3 M6/P2): its
/// animation layers evaluated every frame (0x1401fdf90, the image's update: WE's object loop
/// 0x1401891a0 calls it for every object, hidden or not, before the scripts' `update`), the local and
/// model-space bone matrices WE keeps (puppet+0x310, +0x2c8) and the bone palette the mesh is
/// drawn with (`ScenePuppetPose`, puppet+0x2f8). Scripts reach it through `SceneScriptRigCommand`s
/// and read it back through `SceneScriptRigFeedback`. Render thread only.
final class ScenePuppetAnimator {
    let skeleton: SceneSkeleton
    private(set) var stack: SceneAnimationLayerStack
    /// Each bone's local matrix as last evaluated or set (`getLocalBoneTransform`).
    private(set) var locals: [simd_float4x4]
    /// Each bone's model-space matrix (`getBoneTransform` before the object's world).
    private(set) var worlds: [simd_float4x4]
    private(set) var pose: ScenePuppetPose
    /// What the last `advance` did besides posing.
    private(set) var lastUpdate = SceneAnimationLayerUpdate()
    /// Layers whose clip ended since scripts were last told (`takeEnded`).
    private var endedSinceFeedback: [Int] = []
    /// Clip events the layers crossed since scripts were last told (`takeEvents`).
    private var eventsSinceFeedback: [SceneAnimationLayerUpdate.Event] = []
    /// The rig's blend shapes, and their weights per mesh this frame (`SceneMorphWeights`).
    let morphRig: SceneMorphRig?
    private(set) var morphs: [SceneMorphWeights]
    /// The texture channels' weights, `g_BlendMap` (puppet+0x350): what the layers last set,
    /// kept from frame to frame, 0 until a clip with channel tracks plays.
    private(set) var channelWeights = [Float](repeating: 0, count: SceneAnimationLayerStack.maximumTextureChannels)
    /// The bones' keyed opacity and depth offset this frame (`SceneBoneScalars`): their rest values
    /// until a layer applies, and every frame the layers run.
    private(set) var boneScalars: SceneBoneScalars
    /// The parts' draw order the keyed depths sort (`ScenePuppetDrawOrder`); nil for a rig whose
    /// clips key none, or a model.
    let drawOrder: ScenePuppetDrawOrder?
    /// The rig's physics bones (docs/models-plan.md §2.14); nil without one.
    private(set) var physics: SceneBonePhysics?
    /// The rig's blend rules (docs/models-plan.md §2.15); nil without one, and for a model, whose
    /// update has none.
    let blendRules: SceneBlendRules?
    /// The rig's IK sets (docs/models-plan.md §2.16, `ScenePuppetIK`); nil without one, and for a
    /// model, whose update has no solver.
    let ik: ScenePuppetIK?
    /// Its rope chains' points (`ScenePuppetRope`); nil without a rope.
    let rope: ScenePuppetRope?
    /// The object's world matrix at the last `advance`, which with `worlds` gives the physics
    /// last frame's bones.
    private var lastObjectWorld: simd_float4x4?

    /// An authored layer's bound values: user bindings and `animation` timelines on `rate`,
    /// `blend` and `visible`, re-read every frame until a script sets the field.
    private struct Binding {
        /// The layer's index in `animationlayers`: its timelines' site
        /// (`SceneAnimationOwner.animationLayer`).
        var position: Int
        var rate: SceneRawValue?
        var blend: SceneRawValue?
        var visible: SceneRawValue?
        var rateTimeline: SceneTimelineAnimation?
        var blendTimeline: SceneTimelineAnimation?
    }

    private var bindings: [Int: Binding] = [:]
    /// The scene object whose `animationlayers` these are, whose timelines run in the wallpaper's
    /// `SceneAnimationSet` (where scripts play them and their events reach the object's scripts);
    /// nil runs each timeline on its own clock here.
    let objectID: Int?
    /// Model-space matrices `setBoneTransform` set: that bone's palette entry only, its children
    /// untouched (0x14020f350). Kept until the next evaluation or local write recomputes the bones.
    private var worldOverrides: [Int: simd_float4x4] = [:]
    private var nextScriptKey = 1 << 20
    /// Whether the next `advance` can change the pose: the first frame, a frame after layers ran
    /// (their blend-shape weights start over), or after a script set a blend shape. A rig with no
    /// layers and no physics otherwise poses exactly as it did, so its frame skips `recompute`.
    private var poseMayChange = true

    /// `layers` are the image's authored `animationlayers`; one naming no clip of `clips` makes
    /// no layer (WE's parser, 0x1402230fe), and is reported through `missing`.
    /// `model`: a model object's rig (WE's model update); `rootMotion`: it runs its clips' root
    /// motion (its `rootmotion` is on).
    init(skeleton: MDLSkeleton, clips: [MDLAnimation], layers: [WEAnimationLayer], morphRig: SceneMorphRig? = nil,
         model: Bool = false, rootMotion: Bool = false, objectID: Int? = nil, drawOrder: ScenePuppetDrawOrder? = nil,
         missing: (WEAnimationLayer) -> Void = { _ in }) {
        self.objectID = objectID
        self.drawOrder = drawOrder
        // Models have no `g_BonesAlpha` or part order; their clips' per-bone lists stay unread.
        var scalars = model ? SceneBoneScalars() : SceneBoneScalars.rest(boneCount: skeleton.bones.count, clips: clips)
        blendRules = model ? nil : SceneBlendRules(skeleton)
        if let blendRules { scalars.blendRules = Array(repeating: 0, count: blendRules.weightCount) }
        boneScalars = scalars
        physics = SceneBonePhysics(skeleton)
        let solver = model ? nil : ScenePuppetIK(skeleton)
        let ropes = solver.flatMap { $0.sets.contains(where: \.hasRope) ? ScenePuppetRope(boneCount: skeleton.bones.count) : nil }
        solver?.rope = ropes
        ik = solver
        rope = ropes
        let skeleton = SceneSkeleton(skeleton)
        self.skeleton = skeleton
        self.morphRig = morphRig
        morphs = (morphRig?.targetCounts ?? []).map(SceneMorphWeights.init(count:))
        stack = SceneAnimationLayerStack(skeleton: skeleton, clips: clips, model: model, rootMotion: rootMotion)
        locals = skeleton.restLocal
        worlds = skeleton.restWorld
        pose = .bind(boneCount: skeleton.boneCount)
        pose.drawRanges = drawOrder?.ranges(offsets: [])
        for (position, authored) in layers.enumerated() {
            guard let id = authored.animation, let clip = stack.clipIndex(id: id) else {
                missing(authored)
                continue
            }
            let key = authored.id ?? position
            let layer = SceneAnimationLayer(key: key, name: authored.name ?? "", clip: clip, animation: clips[clip],
                                            additive: authored.additive, blendIn: authored.blendIn,
                                            blendOut: authored.blendOut, blendTime: Float(authored.blendTime),
                                            rate: Float(authored.rate), blend: Float(authored.blend),
                                            visible: authored.visible, authored: authored.position ?? position)
            stack.insert(layer, autosort: authored.autosort ?? false, index: authored.index)
            bindings[key] = Binding(position: authored.position ?? position, rate: authored.values[.rate], blend: authored.values[.blend],
                                    visible: authored.values[.visible],
                                    rateTimeline: Self.timeline(authored.values[.rate]),
                                    blendTimeline: Self.timeline(authored.values[.blend]))
        }
    }

    /// A bound value's keyframe timeline, run on its own clock (docs/timeline-plan.md §2).
    private static func timeline(_ raw: SceneRawValue?) -> SceneTimelineAnimation? {
        guard let raw, let json = raw.animation else { return nil }
        do {
            // Only a string `value` matters to a timeline (`relative`).
            var staticValue: SceneJSON?
            if case .object(let object) = raw, let text = object.value?.literalString { staticValue = .string(text) }
            return try SceneTimelineAnimation(json: json, staticValue: staticValue)
        } catch {
            OWELog.error(.scene, "An animation layer's timeline can't play: \(error)")
            return nil
        }
    }

    /// One frame (`delta` scene seconds): the bound values, then the layers. It runs before the
    /// scripts' frame, as WE updates its objects before the scripts' `update` (0x1401891a0 at
    /// 0x14017fd26; the scripts at 0x1401802e5), so a script reads this frame's pose, and its bone
    /// and blend-shape writes (`perform`) land on it and show in this frame's draw. A rig with
    /// layers is posed from its bind pose again the next frame, which replaces what scripts set;
    /// one without keeps its bones as scripts leave them (0x1401fdf90 poses only from layers).
    /// Blend-shape weights start over every frame (0x14021c5b0, 0x1401fecba), layers or not.
    /// Physics bones then step in the object's world (`objectWorld`) as the bones are posed,
    /// layers or not, from the second frame on (WE's last-frame bones are null before that).
    func advance(delta: Float, values: SceneValueContext, objectWorld: simd_float4x4 = matrix_identity_float4x4) {
        resolveBindings(delta: delta, values: values)
        var update = SceneAnimationLayerUpdate()
        for index in morphs.indices { morphs[index].reset() }
        if !stack.layers.isEmpty {
            boneScalars = SceneBoneScalars(alpha: boneScalars.alpha.map { _ in 1 }, depth: boneScalars.depth.map { _ in 0 },
                                           blendRules: boneScalars.blendRules)
            let transforms = stack.evaluate(delta: delta, update: &update, morphs: &morphs, kind: morphRig?.kind ?? .model,
                                            channels: &channelWeights, bones: &boneScalars)
            locals = transforms.map(\.matrix)
            worldOverrides.removeAll()
        }
        lastUpdate = update
        endedSinceFeedback += update.ended
        eventsSinceFeedback += update.events
        var frame: SceneBonePhysics.Frame?
        // A frame without time (a held clock) keeps the physics where it was [I: WE doesn't update then].
        if physics != nil, delta > 0, let last = lastObjectWorld {
            frame = SceneBonePhysics.Frame(delta: delta, objectWorld: objectWorld, previousWorlds: worlds.map { last * $0 })
        }
        lastObjectWorld = objectWorld
        let layered = !stack.layers.isEmpty
        guard layered || physics != nil || poseMayChange else { return }
        // WE solves only on the update's path with animation layers (0x1402037a6).
        let solver = layered ? ik : nil
        solver?.beginFrame(links: stack.linkPose(bind: solver?.linkBind ?? []), delta: delta, objectWorld: objectWorld)
        recompute(physics: frame, ik: solver)
        poseMayChange = layered
    }

    /// The layers whose clip ended since the last call, for scripts' `addEndedCallback`.
    func takeEnded() -> [Int] {
        defer { endedSinceFeedback.removeAll() }
        return endedSinceFeedback
    }

    /// The clip events crossed since the last call, for scripts' `animationEvent`.
    func takeEvents() -> [SceneAnimationLayerUpdate.Event] {
        defer { eventsSinceFeedback.removeAll() }
        return eventsSinceFeedback
    }

    /// A timeline's value this frame: the wallpaper's `SceneAnimationSet` sample of the layer's
    /// field when it runs there, else the timeline advanced on its own clock here.
    private func timelineValue(_ timeline: inout SceneTimelineAnimation?, field: String, position: Int, delta: Float,
                               values: SceneValueContext) -> Float? {
        guard var own = timeline else { return nil }
        if let objectID,
           let shared = values.animationValue(SceneAnimationSite(owner: .animationLayer(object: objectID, layer: position),
                                                                 key: field)) {
            return shared.first ?? 1
        }
        own.clock.advance(by: delta)
        timeline = own
        return own.value().first ?? 1
    }

    private func resolveBindings(delta: Float, values: SceneValueContext) {
        for (key, binding) in bindings {
            var binding = binding
            let rate = timelineValue(&binding.rateTimeline, field: SceneAnimationLayerValueField.rate.rawValue,
                                     position: binding.position, delta: delta, values: values)
                ?? binding.rate?.userBindingSource.map { SceneValueResolver.resolve($0, in: values).float }
            let blend = timelineValue(&binding.blendTimeline, field: SceneAnimationLayerValueField.blend.rawValue,
                                      position: binding.position, delta: delta, values: values)
                ?? binding.blend?.userBindingSource.map { SceneValueResolver.resolve($0, in: values).float }
            let visible = binding.visible?.userBindingSource.map { SceneValueResolver.resolve($0, in: values).float != 0 }
            bindings[key] = binding
            stack.update(key: key) { layer in
                if let rate { layer.rate = rate }
                if let blend { layer.blend = blend }
                if let visible { layer.visible = visible }
            }
        }
    }

    /// Worlds from the locals (with the blend rules, the physics bones and the IK chains), then
    /// `setBoneTransform`'s overrides, then the palette.
    private func recompute(physics frame: SceneBonePhysics.Frame? = nil, ik: ScenePuppetIK? = nil) {
        var adjust: ((Int, simd_float4x4, [simd_float4x4]) -> simd_float4x4)?
        if let blendRules {
            let previous = self.worlds, weights = boneScalars.blendRules
            adjust = { bone, model, posed in
                blendRules.apply(bone: bone, to: model, posed: posed, previous: previous, weights: weights)
            }
        }
        var worlds = physics?.worlds(locals: locals, skeleton: skeleton, frame: frame, adjust: adjust, ik: ik)
            ?? skeleton.worlds(locals: locals, adjust: adjust, ik: ik)
        if let ik { heldLocals(ik, worlds: worlds) }
        var palette = skeleton.palette(worlds: worlds)
        for (bone, matrix) in worldOverrides where bone < worlds.count {
            worlds[bone] = matrix
            palette[bone] = matrix * skeleton.inverseBind[bone]
        }
        self.worlds = worlds
        let next = ScenePuppetPose(bones: palette,
                                   bonesAlpha: boneScalars.alpha.isEmpty ? pose.bonesAlpha : boneScalars.alpha,
                                   morph: morphRig?.puppetUniforms(morphs, boneMatrices: worlds),
                                   blendMap: channelWeights,
                                   drawRanges: drawOrder?.ranges(offsets: boneScalars.depth))
        if next != pose { pose = next }
    }

    /// A held bone's local matrix from its solved one, as WE derives it (0x14020086f…).
    private func heldLocals(_ ik: ScenePuppetIK, worlds: [simd_float4x4]) {
        for bone in worlds.indices where bone < locals.count && ik.heldModel(bone) != nil {
            locals[bone] = skeleton.parents[bone].map { worlds[$0].inverse * worlds[bone] } ?? worlds[bone]
        }
    }

    // MARK: - Scripts

    /// A model's `rootmotion` (`IModelLayer.rootmotion`): whether its clips' root motion runs.
    var rootMotion: Bool {
        get { stack.runsRootMotion }
        set { stack.runsRootMotion = newValue }
    }

    /// A script's call (`IImageLayer`, `IAnimationLayer`), in the order scripts made them.
    func perform(_ command: SceneScriptRigCommand) {
        switch command {
        case let .createLayer(key, clip, config, singlePlay):
            guard let index = stack.clipIndex(named: clip) else { return }
            var layer = SceneAnimationLayer(key: key, name: config.name ?? clip, clip: index,
                                            animation: stack.clips[index], additive: config.additive,
                                            blendIn: config.blendIn, blendOut: config.blendOut,
                                            blendTime: config.blendTime, rate: config.rate, blend: config.blend,
                                            visible: config.visible)
            layer.removesWhenFinished = singlePlay
            stack.insert(layer, autosort: config.autosort, index: nil)
            nextScriptKey = max(nextScriptKey, key + 1)
        case .destroyLayer(let key):
            stack.remove(key: key)
            bindings[key] = nil
        case let .setLayer(key, field, value):
            // A script's write replaces the field's binding from then on.
            switch field {
            case .rate:
                bindings[key]?.rate = nil
                bindings[key]?.rateTimeline = nil
                stack.update(key: key) { $0.rate = value }
            case .blend:
                bindings[key]?.blend = nil
                bindings[key]?.blendTimeline = nil
                stack.update(key: key) { $0.blend = value }
            case .visible:
                bindings[key]?.visible = nil
                stack.update(key: key) { $0.visible = value != 0 }
            }
        case let .playback(key, action):
            stack.update(key: key) { layer in
                switch action {
                case .play: layer.clock.play()
                case .pause: layer.clock.pause()
                case .stop: layer.clock.stop()
                case .setFrame(let frame): layer.clock.setFrame(frame)
                }
            }
        case let .setLocal(bone, matrix):
            guard bone >= 0, bone < locals.count else { return }
            locals[bone] = matrix
            worldOverrides.removeAll()
            recompute()
        case let .setWorld(bone, matrix):
            guard bone >= 0, bone < locals.count else { return }
            worldOverrides[bone] = matrix
            recompute()
        case let .setBlendShape(index, weight):
            guard !morphs.isEmpty else { return }
            morphs[0].setFromScript(index, weight)
            recompute()
            poseMayChange = true
        case let .physicsImpulse(bone, linear, angularDegrees):
            physics?.applyImpulse(bone: bone, linear: linear, angularDegrees: angularDegrees)
        case .resetPhysics(let bone):
            physics?.reset(bone: bone)
            rope?.reset(bone: bone)
        }
    }

    /// The first mesh's blend-shape weights as scripts see them (`getBlendShapeWeight`).
    var blendShapeWeights: [Float] { morphs.first?.weights ?? [] }

    /// The layers as scripts see them, in evaluation order.
    var layerStates: [SceneScriptRigFeedback.Layer] {
        stack.layers.map { layer in
            SceneScriptRigFeedback.Layer(key: layer.key, name: layer.name, clip: layer.clip, time: layer.clock.time,
                                         frame: layer.clock.frame, flags: layer.clock.flags, rate: layer.rate,
                                         blend: layer.blend, visible: layer.visible, additive: layer.additive)
        }
    }
}
