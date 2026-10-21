import AppKit
import simd

/// The time-varying inputs a layer's pixels can follow (efficiency-plan-2d notes WP1-A).
struct SceneLayerDependencies: OptionSet, Hashable, CustomStringConvertible {
    let rawValue: UInt32

    /// Scene time: `g_Time` and friends, an effect that carries frames, an animated texture, a puppet.
    static let time = SceneLayerDependencies(rawValue: 1 << 0)
    static let cursor = SceneLayerDependencies(rawValue: 1 << 1)
    static let parallax = SceneLayerDependencies(rawValue: 1 << 2)
    /// Camera shake, and the camera it moves (lit layers read the eye).
    static let shake = SceneLayerDependencies(rawValue: 1 << 3)
    static let audio = SceneLayerDependencies(rawValue: 1 << 4)
    /// What scripts write into the object (or an ancestor).
    static let script = SceneLayerDependencies(rawValue: 1 << 5)
    /// A property timeline on the object (or an ancestor).
    static let timeline = SceneLayerDependencies(rawValue: 1 << 6)
    /// User-bound values: bindings, dynamic material constants, bound text.
    static let userProperties = SceneLayerDependencies(rawValue: 1 << 7)
    /// A video source, or a texture WE supplies at run time (now-playing artwork).
    static let video = SceneLayerDependencies(rawValue: 1 << 8)
    /// Particles drawn beneath a layer that samples the frame beneath.
    static let particles = SceneLayerDependencies(rawValue: 1 << 9)
    /// Samples the scene drawn so far (`_rt_FullFrameBuffer`) or the last frame
    /// (`_rt_MipMappedFrameBuffer`).
    static let frameBeneath = SceneLayerDependencies(rawValue: 1 << 10)
    /// Samples another layer's image (`_rt_imageLayerComposite_<id>_a`).
    static let composite = SceneLayerDependencies(rawValue: 1 << 11)
    /// A live Inspector edit.
    static let inspector = SceneLayerDependencies(rawValue: 1 << 12)

    static let all: [(SceneLayerDependencies, String)] = [
        (.time, "time"), (.cursor, "cursor"), (.parallax, "parallax"), (.shake, "shake"), (.audio, "audio"),
        (.script, "script"), (.timeline, "timeline"), (.userProperties, "userProperties"), (.video, "video"),
        (.particles, "particles"), (.frameBeneath, "frameBeneath"), (.composite, "composite"), (.inspector, "inspector"),
    ]

    var description: String { Self.all.filter { contains($0.0) }.map(\.1).joined(separator: "|") }
}

/// What a layer's image looks like, for consumers that trade detail for cost (half-res
/// blur): text and line art keep full resolution.
enum SceneLayerContentClass: String {
    case text
    case lineArt
    case photo
}

/// Where a layer can draw, in scene units (y up), clipped to the scene.
struct SceneLayerCoverage: Equatable {
    var min: SIMD2<Float>
    var max: SIMD2<Float>
    /// Unbounded (it moves, is drawn through a camera, reads the scene, …): the whole scene.
    var fullScene: Bool
    /// Every pixel of the bounds is written with alpha 1 by normal blending, whatever the inputs.
    var opaque: Bool

    static func full(_ sceneSize: SIMD2<Float>) -> SceneLayerCoverage {
        SceneLayerCoverage(min: .zero, max: sceneSize, fullScene: true, opaque: false)
    }

    var isEmpty: Bool { !fullScene && (max.x <= min.x || max.y <= min.y) }
}

/// The per-frame values the analysis diffs against the last frame. Everything is a value (the
/// renderer hands over what it already computed); the analysis keeps the previous frame's copy.
struct SceneLayerFrameInputs {
    var time: Double = 0
    var pointer = SIMD2<Float>(0.5, 0.5)
    var parallax = SIMD2<Float>(0.5, 0.5)
    /// Whether the parallax displaces objects this frame (their coverage is then unbounded).
    var parallaxActive = false
    /// The shake that moves the scene (orthographic) and the one the camera carries (perspective).
    var shake = SIMD2<Float>.zero
    var cameraShake = SIMD3<Float>.zero
    var audio = AudioSpectrumSnapshot.silent
    var audioLevel: Double = 0
    /// Bumped whenever a video or system texture may show a new picture (a decoded video frame).
    var videoRevision: UInt64 = 0
    /// Bumped whenever any user property of the running wallpapers changes.
    var userPropertiesRevision: UInt64 = 0
    /// Bumped by a live Inspector edit that isn't a content rebuild.
    var inspectorRevision: UInt64 = 0
    var scripts = SceneScriptFrameState()
    /// Every animated site of the instance's timelines.
    var animatedSites: [SceneAnimationSite] = []
    /// Anything scene-wide changed that isn't one of the above (draw order, clear colour, a
    /// structural script event): every layer is dirty.
    var sceneChanged = false
}

/// Per-layer dependencies, coverage, content class and per-frame dirty state of one prepared
/// scene: the foundation flattening, culling and the adaptive frame rate build on
/// (efficiency-plan-2d notes WP1-A).
///
/// Conservative throughout: an input the analysis can't prove static makes the layer dynamic, and a
/// bound it can't prove makes the coverage the whole scene. A layer it has never seen (one a script
/// created) is always dirty.
///
/// Built off the main thread (`make`, which scans textures); `update` runs on the render thread in
/// O(layers + script objects + animated sites).
final class SceneLayerAnalysis {
    struct Layer {
        let id: String
        /// scene.json id, when the layer id is one.
        let objectID: Int?
        /// The layer and its ancestors, as scene.json ids (script and timeline changes on any of
        /// them move or change it).
        let lineage: [Int]
        let order: Int
        let dependencies: SceneLayerDependencies
        /// Coverage while nothing moves it; see `coverage(at:)`.
        let staticCoverage: SceneLayerCoverage
        /// The dependencies that move or resize the layer (and so unbound its coverage).
        let movedBy: SceneLayerDependencies
        let contentClass: SceneLayerContentClass
        /// The class came from the image's pixels (or it is text), not the default.
        let classifiedFromPixels: Bool
        /// Samples the last finished frame: dirty whenever anything was dirty in it or this one.
        let readsPreviousFrame: Bool
        /// Indices (into `layers`) of the layers whose composite image this one samples.
        let compositeSources: [Int]
        /// Particle systems are drawn beneath it.
        let particlesBeneath: Bool
    }

    let sceneSize: SIMD2<Float>
    let layers: [Layer]
    /// Layer index by id.
    private let indices: [String: Int]
    /// Layer indices in draw order (bottom first).
    private let drawOrder: [Int]
    /// scene.json ids of the drawn layers and particle systems: script changes on any other object
    /// (a light, a sound, a group that isn't an ancestor) count as scene-wide.
    private let knownObjectIDs: Set<Int>
    private let ancestorObjectIDs: Set<Int>
    /// The scene has frame-wide stages that change on their own (a camera fade or path, volumetric
    /// lights, 3D models): no frame is clean while it runs.
    let sceneStagesAnimate: Bool
    /// Hot-loop copies of `layers`' fields, by layer index.
    private let dependencyBits: [UInt32]
    private let lineages: [[Int]]
    private let beneathFlags: [(particles: Bool, previousFrame: Bool)]
    private let compositeReaders: [Int]

    /// This frame's result, by layer index.
    private(set) var dirty: [Bool]
    private(set) var dirtyCount = 0
    /// This frame changed as a whole (`update`'s scene-wide case): the picture changes even when the
    /// scene has no layers (particles only), e.g. once a compiling pipeline lands.
    private(set) var sceneWideDirty = true
    /// The inputs that changed this frame, across the dirty layers' dependencies.
    private(set) var changed: SceneLayerDependencies = []
    /// Frames `update` has run.
    private(set) var frame: UInt64 = 0
    /// CPU time of the last `update`, in seconds.
    private(set) var lastUpdateSeconds: Double = 0

    private var previous: SceneLayerFrameInputs?
    private var previousAnyDirty = true
    private var animatedObjects = Set<Int>()
    private var sceneAnimated = false
    private var lastSites: [SceneAnimationSite] = []
    /// Object ids scripts changed this frame, and which ones own any field (moving the layer).
    private var scriptChanged = Set<Int>()
    private var scriptOwning = Set<Int>()
    private var forceAll = true

    init(sceneSize: SIMD2<Float>, layers: [Layer], knownObjectIDs: Set<Int>, ancestorObjectIDs: Set<Int>,
         sceneStagesAnimate: Bool = false) {
        self.sceneSize = sceneSize
        self.sceneStagesAnimate = sceneStagesAnimate
        self.layers = layers
        var indices: [String: Int] = [:]
        for (index, layer) in layers.enumerated() where indices[layer.id] == nil { indices[layer.id] = index }
        self.indices = indices
        drawOrder = layers.indices.sorted { (layers[$0].order, $0) < (layers[$1].order, $1) }
        self.knownObjectIDs = knownObjectIDs
        self.ancestorObjectIDs = ancestorObjectIDs
        dependencyBits = layers.map(\.dependencies.rawValue)
        lineages = layers.map(\.lineage)
        beneathFlags = layers.map { ($0.particlesBeneath, $0.readsPreviousFrame) }
        compositeReaders = layers.indices.filter { !layers[$0].compositeSources.isEmpty }
        dirty = Array(repeating: true, count: layers.count)
        dirtyCount = layers.count
    }

    // MARK: - Queries

    func index(of id: String) -> Int? { indices[id] }

    /// Unknown layers (script-created ones) are always dirty.
    func isDirty(_ id: String) -> Bool {
        guard let index = indices[id] else { return true }
        return dirty[index]
    }

    var anyDirty: Bool { dirtyCount > 0 || sceneWideDirty }

    /// This frame's coverage: the static bounds unless something that moves the layer is live.
    func coverage(at index: Int) -> SceneLayerCoverage {
        let layer = layers[index]
        guard !layer.staticCoverage.fullScene else { return layer.staticCoverage }
        var moving = layer.movedBy.subtracting([.parallax, .script, .timeline])
        if layer.movedBy.contains(.parallax), previous?.parallaxActive == true { moving.insert(.parallax) }
        if layer.movedBy.contains(.script), layer.lineage.contains(where: scriptOwning.contains) { moving.insert(.script) }
        if layer.movedBy.contains(.timeline), sceneAnimated || layer.lineage.contains(where: animatedObjects.contains) {
            moving.insert(.timeline)
        }
        return moving.isEmpty ? layer.staticCoverage : .full(sceneSize)
    }

    /// Everything is dirty on the next update (a live edit the inputs don't carry).
    func invalidateAll() { forceAll = true }

    // MARK: - Per frame

    /// Diffs `inputs` against the last frame and marks each layer dirty when an input it depends on
    /// changed. The first update after `make` marks everything dirty.
    func update(_ inputs: SceneLayerFrameInputs) {
        let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        defer {
            frame &+= 1
            lastUpdateSeconds = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1e9
        }
        // A timeline added or removed (a script's createLayer, a relink) can move anything.
        let sitesChanged = refreshTimelines(inputs.animatedSites)
        var sceneWide = sitesChanged || forceAll || sceneStagesAnimate || inputs.sceneChanged || inputs.scripts.halted != (previous?.scripts.halted ?? false)
        diffScripts(inputs.scripts, sceneWide: &sceneWide)
        var global: SceneLayerDependencies = []
        if let last = previous {
            let timeAdvanced = inputs.time != last.time
            if timeAdvanced { global.formUnion([.time, .particles]) }
            if inputs.videoRevision != last.videoRevision { global.insert(.video) }
            if inputs.pointer != last.pointer { global.insert(.cursor) }
            if inputs.parallax != last.parallax || inputs.parallaxActive != last.parallaxActive { global.insert(.parallax) }
            if inputs.shake != last.shake || inputs.cameraShake != last.cameraShake { global.insert(.shake) }
            if inputs.audioLevel != last.audioLevel || inputs.audio != last.audio { global.insert(.audio) }
            if inputs.userPropertiesRevision != last.userPropertiesRevision { global.insert(.userProperties) }
            if inputs.inspectorRevision != last.inspectorRevision { global.insert(.inspector) }
            if timeAdvanced, !animatedObjects.isEmpty || sceneAnimated { global.insert(.timeline) }
            if sceneAnimated, timeAdvanced { sceneWide = true }
            if scriptChangedAny { global.insert(.script) }
        } else {
            sceneWide = true
        }
        if global.contains(.inspector) { sceneWide = true }
        forceAll = false
        sceneWideDirty = sceneWide
        changed = sceneWide ? SceneLayerDependencies(rawValue: ~0) : global

        var count = 0
        var anyBeneath = false
        let timeAdvanced = global.contains(.time)
        let direct = global.subtracting([.timeline, .script]).rawValue
        let timelineLive = global.contains(.timeline)
        let scriptLive = global.contains(.script)
        let timelineBit = SceneLayerDependencies.timeline.rawValue
        let beneathBit = SceneLayerDependencies.frameBeneath.rawValue
        dirty.withUnsafeMutableBufferPointer { dirty in
            for index in drawOrder {
                let bits = dependencyBits[index]
                var isDirty = sceneWide || bits & direct != 0
                if !isDirty, timelineLive, bits & timelineBit != 0 {
                    isDirty = lineages[index].contains(where: animatedObjects.contains)
                }
                if !isDirty, scriptLive { isDirty = lineages[index].contains(where: scriptChanged.contains) }
                if !isDirty, bits & beneathBit != 0 {
                    let flags = beneathFlags[index]
                    isDirty = anyBeneath || (flags.particles && timeAdvanced) || (flags.previousFrame && previousAnyDirty)
                }
                dirty[index] = isDirty
                if isDirty { count += 1; anyBeneath = true }
            }
            // A layer that samples another's image is dirty when that one is; chains settle in a few rounds.
            guard !sceneWide else { return }
            var settled = compositeReaders.isEmpty
            var rounds = 0
            while !settled, rounds < compositeReaders.count {
                settled = true
                rounds += 1
                for index in compositeReaders where !dirty[index] {
                    if layers[index].compositeSources.contains(where: { dirty[$0] }) {
                        dirty[index] = true
                        count += 1
                        settled = false
                    }
                }
            }
        }
        dirtyCount = count
        previousAnyDirty = count > 0
        previous = inputs
    }

    private var scriptChangedAny: Bool { !scriptChanged.isEmpty }

    private func refreshTimelines(_ sites: [SceneAnimationSite]) -> Bool {
        guard sites != lastSites else { return false }
        lastSites = sites
        animatedObjects.removeAll(keepingCapacity: true)
        sceneAnimated = false
        for site in sites {
            switch site.owner {
            case .scene: sceneAnimated = true
            case .object(let id), .particleInstance(let id): animatedObjects.insert(id)
            case .effect(let id, _), .material(let id, _, _), .animationLayer(let id, _): animatedObjects.insert(id)
            }
        }
        // A timeline on an object that isn't a drawn layer nor an ancestor (a light) reaches every
        // lit layer: treat it as scene-wide.
        if animatedObjects.contains(where: { !knownObjectIDs.contains($0) && !ancestorObjectIDs.contains($0) }) {
            sceneAnimated = true
        }
        return true
    }

    private func diffScripts(_ scripts: SceneScriptFrameState, sceneWide: inout Bool) {
        scriptChanged.removeAll(keepingCapacity: true)
        scriptOwning.removeAll(keepingCapacity: true)
        let last = previous?.scripts
        if scripts.scene != last?.scene || scripts.order != last?.order { sceneWide = true }
        for (id, state) in scripts.objects {
            if state.owned.bits != 0 || !state.strings.isEmpty || !state.effectVisible.isEmpty || !state.constants.isEmpty {
                scriptOwning.insert(id)
            }
            if let before = last?.objects[id], Self.same(before, state) { continue }
            scriptChanged.insert(id)
        }
        if let last {
            for id in last.objects.keys where scripts.objects[id] == nil { scriptChanged.insert(id) }
        }
        if scriptChanged.contains(where: { !knownObjectIDs.contains($0) && !ancestorObjectIDs.contains($0) }) {
            sceneWide = true
        }
    }

    private static func same(_ a: SceneScriptObjectState, _ b: SceneScriptObjectState) -> Bool {
        a.effectRevision == b.effectRevision && a.owned == b.owned && a.playback == b.playback
            && a.values == b.values && a.strings == b.strings && a.effectVisible == b.effectVisible
    }
}

// MARK: - Building

extension SceneLayerAnalysis {
    /// Analyses `content`'s layers. Scans textures (opacity, line art), so run it off the main and
    /// render threads.
    static func make(content: SceneMetalContent, scanTextures: Bool = true) -> SceneLayerAnalysis {
        ThreadGuards.assertNotMainThread("SceneLayerAnalysis.make")
        let size = content.size
        let nodes = content.transforms.nodes
        let hasScripts = content.scripts != nil
        let particleOrders = content.particleSystems.map(\.order)
        let lowestParticle = particleOrders.min()
        var known = Set(content.layers.compactMap { Int($0.id) })
        known.formUnion(content.particleSystems.compactMap { $0.objectID.flatMap(Int.init) })
        var ancestors = Set<Int>()
        let layerIndex = Dictionary(content.layers.enumerated().map { ($0.element.id, $0.offset) },
                                    uniquingKeysWith: { first, _ in first })

        var layers: [Layer] = []
        layers.reserveCapacity(content.layers.count)
        for layer in content.layers {
            let lineageIDs = Self.lineageIDs(of: layer.id, nodes: nodes)
            let lineage = lineageIDs.compactMap { Int($0) }
            ancestors.formUnion(lineage.dropFirst())
            let ancestorBindings = lineageIDs.dropFirst().contains { content.motions[$0]?.bindings.isEmpty == false }

            var deps = dependencies(of: layer)
            if hasScripts { deps.insert(.script) }
            if content.timelines != nil { deps.insert(.timeline) }
            if ancestorBindings { deps.formUnion([.userProperties, .audio]) }
            deps.formUnion([.shake, .inspector])
            let depth = nodes[layer.id]?.parallaxDepth ?? SIMD2(1, 1)
            let parallaxed = lineageIDs.contains { (nodes[$0]?.parallaxDepth ?? SIMD2(1, 1)) != .zero }
            if parallaxed || depth != .zero { deps.insert(.parallax) }
            let particlesBeneath = lowestParticle.map { $0 < layer.order } ?? false
            if deps.contains(.frameBeneath), particlesBeneath { deps.insert(.particles) }

            var movedBy: SceneLayerDependencies = [.shake]
            if deps.contains(.parallax) { movedBy.insert(.parallax) }
            if deps.contains(.script) { movedBy.insert(.script) }
            if deps.contains(.timeline) { movedBy.insert(.timeline) }
            if !layer.bindings.isEmpty || ancestorBindings { movedBy.insert(.userProperties) }
            if layer.musicSync != nil { movedBy.insert(.audio) }
            // Shake only moves the camera (and so the layers) when the scene has it on; parallax is
            // decided per frame. Everything else that moves the layer unbounds its coverage.
            if !content.camera.shake { movedBy.remove(.shake) }

            let coverage = staticCoverage(of: layer, transforms: content.transforms, sceneSize: size,
                                          unbounded: !movedBy.subtracting([.parallax, .script, .timeline]).isEmpty,
                                          scanTextures: scanTextures)
            let (contentClass, fromPixels) = scanTextures ? classify(layer) : (layer.text != nil ? .text : .lineArt, layer.text != nil)
            let sources = layer.weEffects.flatMap(\.compositeLayerIDs).compactMap { layerIndex[$0] }
            layers.append(Layer(id: layer.id, objectID: Int(layer.id), lineage: lineage, order: layer.order,
                                dependencies: deps, staticCoverage: coverage, movedBy: movedBy,
                                contentClass: contentClass, classifiedFromPixels: fromPixels,
                                readsPreviousFrame: readsPreviousFrame(layer), compositeSources: sources,
                                particlesBeneath: particlesBeneath))
        }
        let stages = content.cameraFade != nil || content.volumetrics != nil || !content.spatial.models.isEmpty
            || !content.spatial.cameraPaths.isEmpty || !content.spatial.cameraLayers.isEmpty
        return SceneLayerAnalysis(sceneSize: size, layers: layers, knownObjectIDs: known, ancestorObjectIDs: ancestors,
                                  sceneStagesAnimate: stages)
    }

    /// The layer and its ancestors (cycles stop the walk).
    static func lineageIDs(of id: String, nodes: [String: SceneTransformHierarchy.Node]) -> [String] {
        var lineageIDs = [id]
        var visited: Set<String> = [id]
        var cursor = nodes[id]?.parentID
        while let parent = cursor, visited.insert(parent).inserted {
            lineageIDs.append(parent)
            cursor = nodes[parent]?.parentID
        }
        return lineageIDs
    }

    /// The analysis once scripts reparented objects (`ILayer.setParent`), from the parent graph
    /// `nodes` now holds. A layer whose ancestry changed takes its new lineage and what its new
    /// ancestors bring (parallax, bindings), and the whole scene as coverage, since the bounds
    /// were worked out under its old parent. Nothing is rescanned. Every layer is dirty on the
    /// next update, so the frame after the change is drawn.
    func reparented(nodes: [String: SceneTransformHierarchy.Node],
                    motions: [String: SceneObjectMotion]) -> SceneLayerAnalysis {
        var ancestors = Set<Int>()
        let updated = layers.map { layer -> Layer in
            let lineageIDs = Self.lineageIDs(of: layer.id, nodes: nodes)
            let lineage = lineageIDs.compactMap { Int($0) }
            ancestors.formUnion(lineage.dropFirst())
            guard lineage != layer.lineage else { return layer }
            var deps = layer.dependencies
            var movedBy = layer.movedBy
            if lineageIDs.dropFirst().contains(where: { motions[$0]?.bindings.isEmpty == false }) {
                deps.formUnion([.userProperties, .audio])
                movedBy.insert(.userProperties)
            }
            if lineageIDs.contains(where: { (nodes[$0]?.parallaxDepth ?? SIMD2(1, 1)) != .zero }) {
                deps.insert(.parallax)
                movedBy.insert(.parallax)
            }
            return Layer(id: layer.id, objectID: layer.objectID, lineage: lineage, order: layer.order,
                         dependencies: deps, staticCoverage: .full(sceneSize), movedBy: movedBy,
                         contentClass: layer.contentClass, classifiedFromPixels: layer.classifiedFromPixels,
                         readsPreviousFrame: layer.readsPreviousFrame, compositeSources: layer.compositeSources,
                         particlesBeneath: layer.particlesBeneath)
        }
        return SceneLayerAnalysis(sceneSize: sceneSize, layers: updated, knownObjectIDs: knownObjectIDs,
                                  ancestorObjectIDs: ancestors, sceneStagesAnimate: sceneStagesAnimate)
    }

    /// This analysis with the layers of objects `ids` replaced by `fresh`'s (a structural binding
    /// change rebuilt them, `SceneObjectReplacement`). A rebuilt layer keeps what the scene gave the
    /// old one (scripts, timelines), which its own analysis can't see, and covers the whole scene
    /// until the next full analysis. Every layer is dirty on the next update.
    func replacing(_ ids: Set<String>, with fresh: SceneLayerAnalysis) -> SceneLayerAnalysis {
        let old = Dictionary(layers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let sceneWide = layers.reduce(SceneLayerDependencies()) { $0.union($1.dependencies.intersection([.script, .timeline])) }
        let rebuilt = fresh.layers.map { layer -> Layer in
            let previous = old[layer.id]
            return Layer(id: layer.id, objectID: layer.objectID, lineage: layer.lineage, order: layer.order,
                         dependencies: layer.dependencies.union(previous?.dependencies ?? sceneWide),
                         staticCoverage: .full(sceneSize),
                         movedBy: layer.movedBy.union(previous?.movedBy ?? sceneWide),
                         contentClass: layer.contentClass, classifiedFromPixels: layer.classifiedFromPixels,
                         readsPreviousFrame: layer.readsPreviousFrame, compositeSources: layer.compositeSources,
                         particlesBeneath: layer.particlesBeneath)
        }
        return SceneLayerAnalysis(sceneSize: sceneSize, layers: layers.filter { !ids.contains($0.id) } + rebuilt,
                                  knownObjectIDs: knownObjectIDs.union(fresh.knownObjectIDs),
                                  ancestorObjectIDs: ancestorObjectIDs.union(fresh.ancestorObjectIDs),
                                  sceneStagesAnimate: sceneStagesAnimate)
    }

    /// What the layer's own description says it follows (before its place in the scene).
    static func dependencies(of layer: SceneMetalLayer) -> SceneLayerDependencies {
        var deps: SceneLayerDependencies = []
        switch layer.source {
        // A video changes with its decoded frames (`videoRevision`), not with every clock tick.
        case .video: deps.insert(.video)
        case .animated: deps.insert(.time)
        case .image, .dxt, .uploaded: break
        }
        if layer.textureKey != nil || layer.puppet != nil { deps.insert(.time) }
        if layer.musicSync != nil { deps.insert(.audio) }
        if layer.systemImage != nil { deps.insert(.video) }
        if !layer.bindings.isEmpty { deps.formUnion([.userProperties, .audio]) }
        if layer.text != nil { deps.insert(.userProperties) }
        if layer.readsScene { deps.insert(.frameBeneath) }
        if readsPreviousFrame(layer) { deps.insert(.frameBeneath) }
        if layer.weEffects.contains(where: { !$0.compositeLayerIDs.isEmpty }) { deps.insert(.composite) }
        var passes: [SceneEffectPassPlan] = []
        if let material = layer.imageMaterial {
            passes.append(material.pass)
            if let prelighting = material.prelighting { passes.append(prelighting) }
        }
        for effect in layer.weEffects {
            if effect.carriesFrames { deps.insert(.time) }
            passes += effect.passes
        }
        for pass in passes {
            deps.formUnion(shaderDependencies(pass.variant))
            if !pass.systemTextures.isEmpty { deps.insert(.video) }
            if !pass.constants.dynamic.isEmpty { deps.formUnion([.userProperties, .audio]) }
            if pass.readsSceneSnapshot || pass.readsMipMappedFrameBuffer { deps.insert(.frameBeneath) }
        }
        // Effect visibility and constants can be user-bound; a change reaches only such layers.
        if !layer.weEffects.isEmpty { deps.insert(.userProperties) }
        return deps
    }

    private static func readsPreviousFrame(_ layer: SceneMetalLayer) -> Bool {
        (layer.imageMaterial?.pass.readsMipMappedFrameBuffer ?? false)
            || layer.weEffects.contains { $0.passes.contains(where: \.readsMipMappedFrameBuffer) }
    }

    /// Built-in uniforms a translated variant reads, by name in its source. A variant that failed to
    /// translate is taken as time-dependent.
    static func shaderDependencies(_ variant: TranslatedShaderVariant?) -> SceneLayerDependencies {
        guard let variant else { return [.time] }
        var deps: SceneLayerDependencies = []
        let names = variant.uniforms.map { Array($0.members.keys) } ?? []
        func reads(_ name: String) -> Bool {
            names.contains { $0.contains(name) } || variant.fragmentMSL.contains(name) || variant.vertexMSL.contains(name)
        }
        if reads("g_Time") || reads("g_Frametime") || reads("g_DayTime") || reads("g_Daytime") { deps.insert(.time) }
        if reads("g_Pointer") { deps.insert(.cursor) }
        if reads("g_AudioSpectrum") { deps.insert(.audio) }
        if reads("g_ParallaxPosition") { deps.insert(.parallax) }
        if reads("g_EyePosition") || reads("g_Lights") || reads("g_ViewForward") { deps.insert(.shake) }
        return deps
    }

    // MARK: Coverage

    static func staticCoverage(of layer: SceneMetalLayer, transforms: SceneTransformHierarchy, sceneSize: SIMD2<Float>,
                               unbounded: Bool, scanTextures: Bool) -> SceneLayerCoverage {
        // A material's vertex stage places the vertices, and nothing short of running it bounds
        // where they land: a layer drawn through one covers the scene.
        guard !unbounded, !layer.fillsScene, !layer.sceneInput, !layer.perspective, layer.puppet == nil,
              layer.text == nil, layer.imageMaterial == nil, layer.tilt == .zero, transforms.nodes[layer.id] != nil else {
            return .full(sceneSize)
        }
        let world = transforms.world(of: layer.id)
        let quad = SceneQuadGeometry(world: world, size: layer.size, alignment: layer.alignment)
        let box = quad.boundingBox
        let lower = simd_clamp(box.min, .zero, sceneSize)
        let upper = simd_clamp(box.max, .zero, sceneSize)
        let axisAligned = abs(quad.axisX.y) < 1e-4 && abs(quad.axisY.x) < 1e-4
        let opaque = axisAligned && scanTextures && isOpaque(layer)
        return SceneLayerCoverage(min: lower, max: upper, fullScene: false, opaque: opaque)
    }

    /// Normal blending at alpha 1 with no effect and an image with no transparent texel.
    static func isOpaque(_ layer: SceneMetalLayer) -> Bool {
        guard !layer.additive, layer.opacity == 1, layer.color.w >= 1, layer.weEffects.isEmpty, layer.bindings.isEmpty,
              layer.musicSync == nil, layer.systemImage == nil else { return false }
        if let material = layer.imageMaterial {
            guard material.pass.blending.lowercased() == "normal", material.prelighting == nil else { return false }
        }
        if let fill = layer.solidFill { return fill.w >= 1 }
        // A prepared texture recorded its opacity when it was compressed.
        if case .dxt(let texture) = layer.source, let opaque = texture.opaque { return opaque }
        guard case .image(let image) = layer.source else { return false }
        return imageIsOpaque(image)
    }

    static func imageIsOpaque(_ image: NSImage) -> Bool {
        if let raw = TEXRawImageRep.of(image) {
            guard raw.channels == .rgba else { return true }
            let width = raw.pixelsWide
            let stride = raw.rowPixels * 4
            return raw.bytes.withUnsafeBufferPointer { bytes in
                for row in 0..<raw.pixelsHigh {
                    var offset = row * stride + 3
                    for _ in 0..<width {
                        if bytes[offset] != 255 { return false }
                        offset += 4
                    }
                }
                return true
            }
        }
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
        switch cgImage.alphaInfo {
        case .none, .noneSkipLast, .noneSkipFirst: return true
        default: break
        }
        guard let rgba = rgbaPixels(cgImage, width: cgImage.width, height: cgImage.height) else { return false }
        return rgba.withUnsafeBufferPointer { bytes in
            var offset = 3
            while offset < bytes.count {
                if bytes[offset] != 255 { return false }
                offset += 4
            }
            return true
        }
    }

    // MARK: Content class

    /// Text is text; an image is line art when most of it is flat with some hard edges (a
    /// preparation-time edge-density heuristic on a ≤128² luma sample); anything else, or anything
    /// the analysis can't read, is line art when unreadable (the conservative class) and photo
    /// otherwise.
    static func classify(_ layer: SceneMetalLayer) -> (SceneLayerContentClass, Bool) {
        if layer.text != nil { return (.text, true) }
        if layer.solidFill != nil { return (.lineArt, true) }
        // A prepared texture recorded its class when it was compressed, from the same sample.
        if case .dxt(let texture) = layer.source, let contentClass = texture.contentClass { return (contentClass, true) }
        guard case .image(let image) = layer.source, let luma = lumaSample(image) else { return (.lineArt, false) }
        return (classify(luma: luma.values, width: luma.width, height: luma.height), true)
    }

    /// Flat: neighbours within 2/255. Edge: a step over 64/255. Transparent texels count as flat.
    static func classify(luma: [Float], width: Int, height: Int) -> SceneLayerContentClass {
        guard width > 2, height > 2 else { return .lineArt }
        var flat = 0
        var edges = 0
        var total = 0
        for y in 0..<(height - 1) {
            for x in 0..<(width - 1) {
                let here = luma[y * width + x]
                let step = max(abs(luma[y * width + x + 1] - here), abs(luma[(y + 1) * width + x] - here))
                if step < 2.0 / 255 { flat += 1 } else if step > 64.0 / 255 { edges += 1 }
                total += 1
            }
        }
        let flatShare = Double(flat) / Double(total)
        let edgeShare = Double(edges) / Double(total)
        return flatShare > 0.55 && edgeShare > 0.005 ? .lineArt : .photo
    }

    /// Luma (alpha-weighted over black) of `image` scaled to fit 128×128.
    static func lumaSample(_ image: NSImage) -> (values: [Float], width: Int, height: Int)? {
        let pixel = SceneMetalTextureSource.pixelSize(of: image)
        guard pixel.x >= 1, pixel.y >= 1 else { return nil }
        let scale = min(1, 128 / max(pixel.x, pixel.y))
        let width = max(1, Int((pixel.x * scale).rounded()))
        let height = max(1, Int((pixel.y * scale).rounded()))
        if let raw = TEXRawImageRep.of(image) {
            // Nearest-neighbour from the stored channels, without an RGBA expansion.
            let channels = raw.channels.rawValue
            var values = [Float](repeating: 0, count: width * height)
            for y in 0..<height {
                let sy = min(raw.pixelsHigh - 1, Int(Float(y) / scale))
                for x in 0..<width {
                    let sx = min(raw.pixelsWide - 1, Int(Float(x) / scale))
                    let offset = (sy * raw.rowPixels + sx) * channels
                    let r = Float(raw.bytes[offset]) / 255
                    let g = channels > 1 ? Float(raw.bytes[offset + 1]) / 255 : 0
                    let b = channels > 2 ? Float(raw.bytes[offset + 2]) / 255 : 0
                    let a = channels > 3 ? Float(raw.bytes[offset + 3]) / 255 : 1
                    values[y * width + x] = (0.2126 * r + 0.7152 * g + 0.0722 * b) * a
                }
            }
            return (values, width, height)
        }
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let rgba = rgbaPixels(cgImage, width: width, height: height) else { return nil }
        var values = [Float](repeating: 0, count: width * height)
        for index in 0..<(width * height) {
            let offset = index * 4
            // Premultiplied: already over black.
            values[index] = (0.2126 * Float(rgba[offset]) + 0.7152 * Float(rgba[offset + 1])
                + 0.0722 * Float(rgba[offset + 2])) / 255
        }
        return (values, width, height)
    }

    private static func rgbaPixels(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? bytes : nil
    }
}
