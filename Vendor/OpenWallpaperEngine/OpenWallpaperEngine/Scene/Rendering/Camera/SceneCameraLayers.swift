import simd

/// WE's camera layers (docs/models-plan.md §2.3): every visible one plays its path file, and the
/// last visible one in scene order is the scene's camera.
///
/// **Playback** (the layer's update, `wallpaper64.exe` 0x1401f2ad0, only while it is visible, and
/// only for a layer whose object authors `visible`, as WE 2.8.42 plays them: §5.19):
/// 1. A path finished since the last frame (a "single" clock) is rewound and a new one picked; so
///    is one when none plays yet. `queuemode` "sequential" takes the next visible path, wrapping;
///    "random" draws from a bag of the visible paths at a uniform index, steps past entries equal
///    to the path it drew last, and removes what it drew; an empty bag is refilled with each
///    visible path once. The first bag is the one the path file's load leaves, which holds most
///    paths twice (`loadedBag`). The generator is seeded per load, so the order differs every
///    time, as in WE (docs/test-risks.md MG1).
/// 2. The path's clock advances (the timeline clock, `SceneTimelineClock`) and its channels are
///    sampled between whole frames. A component without keyframes follows the layer's world
///    matrix: eye = its translation, centre = eye − 5·normalize(row 2), up = normalize(row 1).
/// 3. The result is written back into the layer: `origin` = eye and `angles` those of
///    `lookAt(eye, centre, up)`, so the camera moves through its own transform. A perspective
///    scene takes the path's `fov` channel (50 without one); `zoom` is an orthographic scene's.
///    The write-back wins over a script's or a timeline's `origin` and `angles` on the layer: WE
///    2.8.42 follows only the path while one plays, and the script only without one (§5.20).
///
/// **The camera** (0x140189220…0x140189402): the active layer's world matrix gives eye = row 3,
/// centre = row 3 − row 2, up = row 1 (it looks down its local −z; parents apply), and its fov is
/// the playing path's, else the layer's own. World matrices are M3's (`SceneTransformHierarchy3D`).
final class SceneCameraLayers {
    /// The active layer's camera this frame.
    struct Camera: Equatable {
        var id: String
        var pose: SceneCameraPose
        /// Degrees, before the clamp.
        var fov: Float
        /// The playing path's `zoom` (1 without a channel), else the layer's as a script set it
        /// (`ICamera.zoom`) or as authored: an orthographic scene's camera zoom.
        var zoom: Float = 1
    }

    /// What the rig asks of the frame about one layer.
    struct FrameInput {
        var deltaTime: Float
        /// The layer's own `visible` this frame (scripts included, ancestors not: WE tests the
        /// layer's own flag and condition).
        var isVisible: (String) -> Bool
        /// An object's own transform this frame where scripts or timelines set it; nil keeps the
        /// authored one (and, for a camera layer, what its paths wrote back).
        var live: SceneTransformHierarchy3D.Live
        /// A camera layer's `fov` a script set.
        var fov: (String) -> Float?
        /// A camera layer's `zoom` a script set (`ICamera.zoom`).
        var zoom: (String) -> Float? = { _ in nil }
    }

    private final class Path {
        /// The path's clock (+0xf8); nil when its options give no duration, which WE rejects.
        var clock: SceneTimelineClock?
        var eye: SceneTimelineAnimation?
        var center: SceneTimelineAnimation?
        var up: SceneTimelineAnimation?
        var fovChannel: SceneTimelineAnimation?
        var zoomChannel: SceneTimelineAnimation?
        /// `visible`, resolved at load: a hidden path isn't queued.
        let visible: Bool
        /// Whether the file gives the path a `visible` key, whose load runs WE's visibility hook.
        let authorsVisible: Bool
        /// The path's fov (+0x33c): 50 until its channel sets it.
        var fov = Float(SceneCameraDefaults.fov)
        /// The path's zoom: 1 until its channel sets it. Only an orthographic scene uses it: in
        /// perspective WE ignores a path's zoom channel and plays its fov (capture 501).
        var zoom: Float = 1

        init(_ path: WECameraLayerPath, values: SceneValueContext, layer: String) {
            visible = Self.flag(path.visible, in: values) ?? true
            authorsVisible = path.visible != nil
            clock = SceneTimelineClock(options: path.options)
            func animation(_ document: SceneTimelineDocument?, _ name: String) -> SceneTimelineAnimation? {
                guard let document else { return nil }
                do {
                    return try SceneTimelineAnimation(document: document, staticValue: nil)
                } catch {
                    OWELog.error(.scene, "Camera layer \(layer): path \(path.name ?? "?")'s \(name) can't play: \(error)")
                    return nil
                }
            }
            eye = animation(path.eye, "eye")
            center = animation(path.center, "center")
            up = animation(path.up, "up")
            fovChannel = animation(path.fov, "fov")
            zoomChannel = animation(path.zoom, "zoom")
        }

        static func flag(_ raw: SceneRawValue?, in values: SceneValueContext) -> Bool? {
            guard let raw else { return nil }
            if let source = raw.userBindingSource { return SceneValueResolver.resolve(source, in: values).float != 0 }
            return raw.literalBool
        }
    }

    private final class Layer {
        let object: SceneCameraLayerObject
        let fov: Float
        let zoom: Float
        /// The object authors `visible`: only then do its paths play (§5.19).
        let playsPaths: Bool
        let paths: [Path]
        /// The visible paths with a clock, in file order.
        let queue: [Int]
        let sequential: Bool
        /// The playing path (+0x2e0); nil before the first and while none can play.
        var current: Int?
        /// The random queue's bag (+0x328) and the path it drew last (+0x340, +0x344).
        var bag: [Int]
        var last: Int?
        var random: SceneCameraLayers.SplitMix
        /// The origin and angles the paths wrote back, which the layer keeps (+0x128, +0x140).
        var writtenOrigin: SIMD3<Float>?
        var writtenAngles: SIMD3<Float>?

        init(_ object: SceneCameraLayerObject, values: SceneValueContext, seed: UInt64) {
            self.object = object
            let raw = object.authored.values[.fov]
            let resolved = raw?.userBindingSource.map { SceneValueResolver.resolve($0, in: values).float }
            fov = resolved ?? Float(object.authored.fov)
            zoom = Float(object.authored.zoom)
            playsPaths = object.authored.authorsVisible
            let paths = (object.pathFile?.paths ?? []).map { Path($0, values: values, layer: object.id) }
            self.paths = paths
            queue = paths.indices.filter { paths[$0].visible && paths[$0].clock != nil }
            sequential = object.authored.queueMode == .sequential
            bag = Self.loadedBag(paths)
            random = SceneCameraLayers.SplitMix(state: seed)
        }

        /// The bag as WE's path-file load leaves it (0x1401f2030). Loading a path's `visible` key
        /// calls the visibility hook (0x1401f1ca0, the property's change callback, called
        /// unconditionally by the bool loader 0x1401e1a90), which queues every path already loaded
        /// (not the one loading) that is visible and not yet queued; after the loop the load queues
        /// every visible path again (0x1401f2919: the set insert dedups, the bag push doesn't). A
        /// file of paths that all author `visible` so starts with each path twice but the last
        /// once. A path whose options give no clock is dropped after its `visible` loaded.
        static func loadedBag(_ paths: [Path]) -> [Int] {
            var queued = Set<Int>()
            var bag: [Int] = []
            var loaded: [Int] = []
            for index in paths.indices {
                if paths[index].authorsVisible {
                    for earlier in loaded where paths[earlier].visible && !queued.contains(earlier) {
                        queued.insert(earlier)
                        bag.append(earlier)
                    }
                }
                if paths[index].clock != nil { loaded.append(index) }
            }
            return bag + loaded.filter { paths[$0].visible }
        }
    }

    private let layers: [Layer]
    private var transforms: SceneTransformHierarchy3D

    /// `transforms` holds every object's authored transform and parent (`SceneSpatialContent.transforms`).
    /// `seed` seeds the random queues; WE's differ on every load (MG1), so the default is random.
    init(_ objects: [SceneCameraLayerObject], transforms: SceneTransformHierarchy3D, values: SceneValueContext,
         seed: UInt64 = UInt64.random(in: UInt64.min...UInt64.max)) {
        self.transforms = transforms
        layers = objects.sorted { $0.order < $1.order }.enumerated().map { index, object in
            Layer(object, values: values, seed: seed &+ 0x9E37_79B9_7F4A_7C15 &* UInt64(index + 1))
        }
    }

    var isEmpty: Bool { layers.isEmpty }

    /// `ILayer.setParent`: a camera layer (or an ancestor) follows its new parent.
    func setParent(_ id: String, to parent: String?, attachment: String?) {
        transforms.setParent(id, to: parent, attachment: attachment)
    }

    /// Plays every visible layer's paths, then returns the active layer's camera; nil when no
    /// camera layer is visible.
    func update(_ input: FrameInput) -> Camera? {
        var active: Layer?
        for layer in layers where input.isVisible(layer.object.id) {
            if layer.playsPaths { play(layer, input: input) }
            active = layer
        }
        guard let active else { return nil }
        let world = worldMatrix(active, input: input)
        let row = { (i: Int) in SIMD3(world[i].x, world[i].y, world[i].z) }
        let pose = SceneCameraPose(eye: row(3), center: row(3) - row(2), up: row(1))
        let pathFov: Float? = active.current.map { active.paths[$0].fov }
        let fov: Float = pathFov ?? input.fov(active.object.id) ?? active.fov
        let pathZoom: Float? = active.current.map { active.paths[$0].zoom }
        let zoom: Float = pathZoom ?? input.zoom(active.object.id) ?? active.zoom
        return Camera(id: active.object.id, pose: pose, fov: fov, zoom: zoom)
    }

    /// The layer's origin and angles its paths wrote back, if they did (tests, scripts).
    func writtenBack(_ id: String) -> (origin: SIMD3<Float>, angles: SIMD3<Float>)? {
        guard let layer = layers.first(where: { $0.object.id == id }),
              let origin = layer.writtenOrigin, let angles = layer.writtenAngles else { return nil }
        return (origin, angles)
    }

    /// The index of the path `id` plays, nil for none (tests).
    func playingPath(_ id: String) -> Int? {
        layers.first { $0.object.id == id }?.current
    }

    // MARK: - Playback

    private func play(_ layer: Layer, input: FrameInput) {
        guard !layer.queue.isEmpty else { return }
        // A finished path is rewound and the queue steps on from it (the index stays for "sequential").
        var picks = layer.current == nil
        if let current = layer.current, var clock = layer.paths[current].clock, clock.flags.contains(.finished) {
            clock.flags.remove(.finished)
            clock.time = 0
            layer.paths[current].clock = clock
            picks = true
        }
        if picks { layer.current = next(layer) }
        guard let index = layer.current else { return }
        let path = layer.paths[index]
        guard var clock = path.clock else { return }
        clock.advance(by: input.deltaTime)
        path.clock = clock

        let world = worldMatrix(layer, input: input)
        let row = { (i: Int) in SIMD3(world[i].x, world[i].y, world[i].z) }
        var eye = row(3)
        var center = eye - 5 * simd_normalize(row(2))
        var up = simd_normalize(row(1))
        Self.sample(&path.eye, on: clock, into: &eye)
        Self.sample(&path.center, on: clock, into: &center)
        Self.sample(&path.up, on: clock, into: &up)
        layer.writtenOrigin = eye
        layer.writtenAngles = SceneWorldMatrix.lookAtAngles(eye: eye, center: center, up: up)
        if var channel = path.fovChannel, channel.channels.first.map({ !$0.keyframes.isEmpty }) ?? false {
            path.fov = channel.components(on: clock).x
            path.fovChannel = channel
        }
        if var channel = path.zoomChannel, channel.channels.first.map({ !$0.keyframes.isEmpty }) ?? false {
            path.zoom = channel.components(on: clock).x
            path.zoomChannel = channel
        }
    }

    /// The next path to play, WE's queue step (0x1401f2bab…0x1401f2e70).
    private func next(_ layer: Layer) -> Int? {
        if layer.sequential {
            var index = layer.current ?? -1
            for _ in layer.paths.indices {
                index = (index + 1) % layer.paths.count
                if layer.queue.contains(index) { return index }
            }
            return nil
        }
        if layer.bag.isEmpty { layer.bag = layer.queue }
        var pick = Int(layer.random.next() % UInt64(layer.bag.count))
        for _ in layer.bag.indices where layer.bag[pick] == layer.last {
            pick = (pick + 1) % layer.bag.count
        }
        let index = layer.bag.remove(at: pick)
        layer.last = index
        return index
    }

    /// Components of `animation` that have keyframes replace `value`'s.
    private static func sample(_ animation: inout SceneTimelineAnimation?, on clock: SceneTimelineClock,
                               into value: inout SIMD3<Float>) {
        guard var channels = animation else { return }
        let sampled = channels.components(on: clock)
        for component in 0..<min(channels.channels.count, 3) where !channels.channels[component].keyframes.isEmpty {
            value[component] = sampled[component]
        }
        animation = channels
    }

    /// The layer's world matrix: its parents' times its own transform. Its paths' written-back
    /// origin and angles stand in for the authored ones and for what scripts and timelines set
    /// (WE 2.8.42: a script writing the layer's `origin` every frame has no effect while a path
    /// plays, §5.20); without a write-back, scripts and timelines move it.
    private func worldMatrix(_ layer: Layer, input: FrameInput) -> simd_float4x4 {
        let id = layer.object.id
        var own = input.live(id) ?? transforms.nodes[id]?.local ?? .identity
        if let origin = layer.writtenOrigin { own.origin = origin }
        if let angles = layer.writtenAngles { own.angles = angles }
        return transforms.world(of: id, local: own, live: input.live)
    }

    /// A seeded generator for the random queue: WE's own generator (behind 0x140077e10, a uniform
    /// integer in 0…count − 1) isn't reproduced, only the distribution of its draws.
    struct SplitMix {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}
