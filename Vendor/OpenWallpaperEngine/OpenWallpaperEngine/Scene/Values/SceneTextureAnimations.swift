import Foundation

/// A wallpaper instance's texture animations (docs/timeline-plan.md §2.7, §3.2): one shared
/// `SceneTextureAnimationClock` per animated texture, however many layers draw it, and each image
/// layer's `ITextureAnimation` override (`SceneTextureAnimationControl`).
///
/// A texture's shared clock moves when something draws it (`drawnFrame`: WE advances it when a
/// material binds the texture), at most one step per engine frame. A layer's override moves with
/// the engine frame (`advanceOverrides`), drawn or not: WE steps it in the image layer's update
/// (`0x1401fdf90` → `0x1402063c1`), on both paths of that function, not in the draw (test-risks
/// TF5, TL8). Confined to the thread that owns the wallpaper's `SceneAnimationSet`.
final class SceneTextureAnimations {
    /// An `ITextureAnimation` call on a layer.
    enum Control: Equatable {
        case play, pause, stop, join
        case setFrame(Int32)
        case setRate(Float)
    }

    /// What scripts read of a layer's texture animation: its override and the shared clock.
    struct State: Equatable {
        var control: SceneTextureAnimationControl
        var sharedFrame: Int32
        var sharedTime: Float
        var frameCount: Int
        var duration: Float
    }

    private struct Layer {
        var texture: String
        var control = SceneTextureAnimationControl()
    }

    private var clocks: [String: SceneTextureAnimationClock] = [:]
    private var layers: [Int: Layer] = [:]
    /// Textures a material binds without a layer of its own (effect and material textures): their
    /// clocks stay when the layers that share them go.
    private var materialTextures = Set<String>()

    /// Object `id` draws the animated texture `texture` (its path, the shared clock's key), whose
    /// TEXS frames last `frameTimes` seconds. The first user creates the texture's clock. A layer
    /// registered again with the same texture (content rebuilt) keeps its override.
    func register(object id: Int, texture: String, frameTimes: [Float]) {
        if clocks[texture] == nil { clocks[texture] = SceneTextureAnimationClock(frameTimes: frameTimes) }
        if layers[id]?.texture != texture { layers[id] = Layer(texture: texture) }
    }

    /// Every layer but `ids` is gone (content rebuilt without them): as `removeObject` for each.
    func retainObjects(_ ids: Set<Int>) {
        for id in layers.keys where !ids.contains(id) { removeObject(id) }
    }

    /// The layer is gone; its texture's clock goes with its last user.
    func removeObject(_ id: Int) {
        guard let removed = layers.removeValue(forKey: id) else { return }
        if !materialTextures.contains(removed.texture), !layers.values.contains(where: { $0.texture == removed.texture }) {
            clocks[removed.texture] = nil
        }
    }

    /// The shared clock of `texture`, for materials that draw it without a layer of their own.
    func clock(texture: String) -> SceneTextureAnimationClock? { clocks[texture] }

    var objectIDs: [Int] { Array(layers.keys) }

    /// The sprite frame object `id` draws this engine frame (`tick`): binding the texture advances
    /// its shared clock once per tick; a layer a script controls draws its override. `delta` is
    /// the engine frame time.
    func drawnFrame(object id: Int, tick: UInt64, delta: Float) -> Int32? {
        guard let layer = layers[id], let shared = clocks[layer.texture] else { return nil }
        shared.advance(tick: tick, delta: delta)
        return layer.control.currentFrame(shared: shared)
    }

    /// The sprite frame of `texture` as a material binds it this engine frame (`tick`): its shared
    /// clock (§2.7, the same one its image layers draw), made on the first bind from `frameTimes`
    /// and advanced once per tick.
    func boundFrame(texture: String, frameTimes: () -> [Float], tick: UInt64, delta: Float) -> Int32 {
        let clock: SceneTextureAnimationClock
        if let existing = clocks[texture] {
            clock = existing
        } else {
            clock = SceneTextureAnimationClock(frameTimes: frameTimes())
            clocks[texture] = clock
        }
        materialTextures.insert(texture)
        return clock.advance(tick: tick, delta: delta)
    }

    /// One engine frame of every layer's override, by `delta` × its `rate` while a script controls
    /// it and it plays; hidden layers too.
    func advanceOverrides(delta: Float) {
        for index in layers.values.indices {
            guard let shared = clocks[layers.values[index].texture] else { continue }
            layers.values[index].control.advance(delta: delta, frameTimes: shared.frameTimes)
        }
    }

    /// Applies a script call the way WE's wrapper does. False for an unknown layer.
    @discardableResult
    func perform(_ control: Control, object id: Int) -> Bool {
        guard var layer = layers[id], let shared = clocks[layer.texture] else { return false }
        switch control {
        case .play: layer.control.play()
        case .pause: layer.control.pause(shared: shared)
        case .stop: layer.control.stop()
        case .join: layer.control.join()
        case .setFrame(let frame): layer.control.setFrame(frame)
        case .setRate(let rate): layer.control.setRate(rate, shared: shared)
        }
        layers[id] = layer
        return true
    }

    /// Replaces a layer's override with what the script left (the JS side applies the same rules
    /// during the script frame; the host reads the dirty slot back afterwards), then steps it by
    /// the engine frames that went by since the script saw it (`replaying`, oldest first).
    @discardableResult
    func restore(_ control: SceneTextureAnimationControl, object id: Int, replaying deltas: [Float] = []) -> Bool {
        guard var layer = layers[id] else { return false }
        layer.control = control
        if let shared = clocks[layer.texture] {
            for delta in deltas { layer.control.advance(delta: delta, frameTimes: shared.frameTimes) }
        }
        layers[id] = layer
        return true
    }

    func state(object id: Int) -> State? {
        guard let layer = layers[id], let shared = clocks[layer.texture] else { return nil }
        return State(control: layer.control, sharedFrame: shared.frame, sharedTime: shared.time,
                     frameCount: shared.frameCount, duration: shared.duration)
    }
}
