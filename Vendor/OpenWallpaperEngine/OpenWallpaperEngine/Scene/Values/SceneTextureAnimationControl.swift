import Foundation

/// A layer's `ITextureAnimation` (docs/timeline-plan.md §3.2; WE's wrapper at `layer+0x4c0`,
/// callbacks `0x1401fa2a0`…`0x1401fa500`, constructor `0x14020e71f`). While `overridden` is off the
/// layer shows the texture's shared `SceneTextureAnimationClock`; a script taking control copies the
/// shared frame and time into this override, which then advances on its own by the engine frame
/// time × `rate`, only while `playing`, with the same one-frame-per-step walk. `join()` gives
/// control back to the shared clock.
///
/// `objects-animations.js` applies the same rules in the script's frame over the animation buffer
/// (`SceneScriptObjectStore.AnimationLayout`); this is the renderer's side of that state.
struct SceneTextureAnimationControl: Equatable {
    /// `rate` (+0xe4). Any float; it only acts while overridden.
    var rate: Float = 1
    /// The override's frame (+0xe8), an index into the texture's frames.
    var frame: Int32 = 0
    /// The override's seconds in `frame` (+0xec).
    var time: Float = 0
    /// +0xe0: starts true. `play()` sets it without taking control.
    var playing = true
    /// +0x48: whether the override, not the shared clock, drives the layer.
    var overridden = false

    /// `rate = value`: stored; a value other than 1 (NaN included) takes control, copying the
    /// shared frame and time, unless control is already taken (`0x1401fa4a0`).
    mutating func setRate(_ value: Float, shared: SceneTextureAnimationClock) {
        rate = value
        guard !(value == 1), !overridden else { return }
        take(shared)
    }

    /// `play()`: playing, nothing else. It doesn't take control.
    mutating func play() {
        playing = true
    }

    /// `pause()`: copies the shared state when not yet in control, then not playing, in control.
    mutating func pause(shared: SceneTextureAnimationClock) {
        if !overridden { take(shared) }
        playing = false
    }

    /// `stop()`: frame 0, time 0, not playing, in control.
    mutating func stop() {
        frame = 0
        time = 0
        overridden = true
        playing = false
    }

    /// `setFrame(n)`: frame `n` (not range-checked), time 0; taking control starts it playing.
    mutating func setFrame(_ value: Int32) {
        frame = value
        time = 0
        guard !overridden else { return }
        overridden = true
        playing = true
    }

    /// `join()`: back to the shared clock. The override keeps its frame, time and playing flag.
    mutating func join() {
        overridden = false
    }

    /// `isPlaying()`: false only while in control and not playing.
    var isPlaying: Bool { !overridden || playing }

    /// `getFrame()`: the override's frame while in control, else the shared one.
    func currentFrame(shared: SceneTextureAnimationClock) -> Int32 {
        overridden ? frame : shared.frame
    }

    /// The per-frame step of an overridden layer (`0x1402063c1`): only while in control and
    /// playing, by `delta × rate` in float. `delta` is the engine frame time.
    mutating func advance(delta: Float, frameTimes: [Float]) {
        guard overridden, playing else { return }
        SceneTextureAnimationClock.step(frame: &frame, time: &time, delta: delta * rate, frameTimes: frameTimes)
    }

    private mutating func take(_ shared: SceneTextureAnimationClock) {
        frame = shared.frame
        time = shared.time
        overridden = true
    }
}
