import AVFoundation

/// A wallpaper instance's sound layers (docs/scenescript-plan.md, sound layers): one
/// `SceneSoundPlayback` per scene.json `sound` object, played through one `SceneSoundMixer`, and
/// the wallpaper's gain. Owned by the renderer, main thread.
///
/// The wallpaper's gain is WE's wallpaper volume (the setter 0x1401816d0): `fade × level`.
/// - `level` is the app's volume times this wallpaper's music volume (WE's +0x178, the
///   wallpaper's `volume` over 100). It changes at once, as WE sets it (0x140114e20, 0x140115361).
/// - `fade` (WE's +0x174) is whether the wallpaper is heard: it eases to 0 when it is muted or
///   paused (or another display plays the wallpaper's sound) and back to 1 when it plays again,
///   with WE's ease (`SceneClock.ease`: the gap shrinks by min(6·dt, 1) a frame and closes once
///   under 0.01; main loop 0x1401113f8…0x14011144d), so a mute or a pause fades out in about
///   0.75 s and a resume fades in as long. In WE it starts at 1 (constructor 0x14010dc00) and a
///   loaded wallpaper takes its value at once (0x140114950): WE doesn't fade a wallpaper in when
///   it starts, nor out when it stops or is replaced, nor at a loop point or between clips (the
///   sound update 0x1401f4f50 has no gain ramp of its own).
/// - **OWE's own start fade-in (not WE's):** when a wallpaper starts (loaded, switched to, the app
///   launched), the fade starts at 0 as its first layer arrives and eases to 1 with the same ease,
///   so the music comes in over about 0.75 s instead of at full volume at once. Only the first
///   layers after the content is released fade in: a rebuild, a script's new layer and a loop
///   point don't, and nothing fades out on a switch or quit. A muted or paused wallpaper has
///   nothing to fade in (its target is 0), and `level` (the volume) still applies at once.
///
/// The fade is stepped by each drawn frame's wall step (`advanceFade`), as WE's main loop steps
/// it. WE's loop keeps running while no wallpaper frame is drawn (it sleeps 250 ms a turn while
/// paused, 0x140111486), so while no frame comes a timer steps it instead; at 0 the layers pause,
/// above 0 they resume where they were. Each step sets the players' volumes, which
/// AVAudioMixerNode ramps sample by sample, so a step of the fade never clicks (OpenAL Soft
/// ramps WE's gain changes the same way).
///
/// A `spatialization` layer's mono files play from its object (`SceneSoundSpatialization`),
/// placed when they start and on every update, like WE's.
final class SceneSoundLayers {
    private struct Layer {
        var content: SceneSoundContent
        var voices: SceneSoundVoices
        var playback: SceneSoundPlayback
    }

    /// How long without a drawn frame before the timer steps the fade.
    static let frameGap: CFTimeInterval = 0.25

    /// Whether a layer has arrived since the content was last released; the first one fades the
    /// wallpaper in (OWE's start fade-in).
    private var hasStarted = false

    private let label: String
    private let offline: AVAudioFormat?
    private let random: () -> Double
    private var mixer: SceneSoundMixer?
    private var layers: [Int: Layer] = [:]
    private var order: [Int] = []
    /// The app's volume × the wallpaper's music volume (WE's +0x178), applied at once.
    private(set) var level: Float = 0
    /// Whether the wallpaper is heard (WE's +0x174), eased toward `fadeTarget`.
    private(set) var fade: Float = 0
    /// 1 while the wallpaper plays sound, 0 while it is muted or paused.
    private(set) var fadeTarget: Float = 0
    /// The wallpaper's gain the layers play at: `fade × level`.
    private(set) var gain: Float = 0
    private var fadeTimer: Timer?
    private var lastFadeTime: CFTimeInterval = 0
    /// When a drawn frame last stepped the fade (`advanceFade`).
    private var lastFrameFade: CFTimeInterval = -.infinity
    /// The camera spatialized layers are placed against (the last frame's); nil before the first.
    var listener: SceneSoundSpatialization.Listener?
    /// A layer's object's world position this frame (its world matrix's translation).
    var locate: (Int) -> SIMD3<Float>? = { _ in nil }

    /// `offline` renders through a manual-rendering engine (tests).
    init(label: String, offline: AVAudioFormat? = nil, random: @escaping () -> Double = { Double.random(in: 0..<1) }) {
        self.label = label
        self.offline = offline
        self.random = random
    }

    deinit {
        fadeTimer?.invalidate()
    }

    var isEmpty: Bool { layers.isEmpty }
    var ids: [Int] { order }

    /// The scene's sound layers. Layers that stay (same id and files) keep playing with the new
    /// settings, as a content rebuild for a user property doesn't restart WE's sounds; others
    /// stop, and new ones load (and play unless `startsilent`).
    func setContent(_ sounds: [SceneSoundContent]) {
        var kept: [Int: Layer] = [:]
        for content in sounds {
            guard var layer = layers.removeValue(forKey: content.id) else { continue }
            guard layer.content.files == content.files, layer.content.sound == content.sound else {
                layer.playback.stop()
                continue
            }
            if layer.content.volume != content.volume { layer.playback.setVolume(content.volume) }
            layer.content = content
            kept[content.id] = layer
        }
        for id in layers.keys { layers[id]?.playback.stop() }
        layers = kept
        order = sounds.map(\.id)
        for content in sounds where layers[content.id] == nil { add(content) }
        idleIfSilent()
    }

    /// Adds one layer (a script's `createLayer`, or new content) and loads it.
    func add(_ content: SceneSoundContent) {
        if layers[content.id] != nil { remove(content.id) }
        if !hasStarted {
            hasStarted = true
            fadeInFromSilence()
        }
        // OpenAL Soft places only mono sources; a stereo file of a spatialized sound plays as it is.
        let spatialFiles = content.sound.spatialization
            ? Set(content.files.indices.filter { content.files[$0].channels == 1 }) : []
        let voices = SceneSoundVoices(files: content.files, spatialFiles: spatialFiles,
                                      mixer: { [weak self] in self?.sharedMixer() }, label: "\(label) '\(content.name)'")
        let playback = SceneSoundPlayback(sound: content.sound, durations: content.files.map(\.duration),
                                          volume: content.volume, sceneGain: gain, output: voices, random: random)
        let layer = Layer(content: content, voices: voices, playback: playback)
        layers[content.id] = layer
        if !order.contains(content.id) { order.append(content.id) }
        place(layer)
        playback.load()
    }

    /// Stops and forgets one layer (`destroyLayer`).
    func remove(_ id: Int) {
        layers.removeValue(forKey: id)?.playback.stop()
        order.removeAll { $0 == id }
        idleIfSilent()
    }

    /// Stops everything (content released).
    func stopAll() {
        for layer in layers.values { layer.playback.stop() }
        layers.removeAll()
        order.removeAll()
        fadeTimer?.invalidate()
        fadeTimer = nil
        hasStarted = false
        mixer?.idle()
    }

    // MARK: - Scripts

    func perform(_ playback: SceneScriptObjectCommand.Playback, on id: Int) {
        guard let layer = layers[id] else { return }
        switch playback {
        case .play: layer.playback.play()
        case .pause: layer.playback.pause()
        case .stop: layer.playback.stop()
        }
        idleIfSilent()
    }

    /// `volume` as a script left it.
    func setVolume(_ volume: Float, of id: Int) {
        guard let layer = layers[id], layer.playback.volume != volume else { return }
        layer.playback.setVolume(volume)
        idleIfSilent()
    }

    func isPlaying(_ id: Int) -> Bool? { layers[id]?.playback.isPlaying }

    func playback(of id: Int) -> SceneSoundPlayback? { layers[id]?.playback }

    // MARK: - Frame

    /// WE's per-frame update, `seconds` of real time since the last draw.
    func update(deltaTime seconds: Double) {
        guard !layers.isEmpty else { return }
        for id in order {
            guard let layer = layers[id] else { continue }
            layer.playback.update(deltaTime: seconds)
            place(layer)
        }
        idleIfSilent()
    }

    /// Places a spatialized layer's files at its object (0x1401f5029): WE sets one position for
    /// every file of the sound.
    private func place(_ layer: Layer) {
        guard !layer.voices.spatialFiles.isEmpty else { return }
        let world = locate(layer.content.id) ?? .zero
        let position = SceneSoundSpatialization.position(world: world, listener: listener)
        let gains = SceneSoundSpatialization.gains(position: position, minDistance: layer.content.minDistance,
                                                   attenuation: layer.content.attenuation)
        for file in layer.voices.spatialFiles { layer.voices.setSpatialGains(gains, file: file) }
    }

    // MARK: - Wallpaper gain

    /// The wallpaper's gain: `level` at once, and the fade toward heard (`audible`) or silent.
    /// A level of 0 counts as silent and keeps the last level, so the sound fades out from where
    /// it was (the app mutes by setting its volume to 0). Before any layer exists (and with no
    /// fade running) the fade takes its target at once, as WE's loaded wallpaper does; the first
    /// layer then fades the wallpaper in (`fadeInFromSilence`, OWE's own).
    func setTarget(level newLevel: Float, audible: Bool) {
        let heard = audible && newLevel > 0
        if newLevel > 0 { level = newLevel }
        fadeTarget = heard ? 1 : 0
        if layers.isEmpty && fadeTimer == nil { fade = fadeTarget }
        applyGain()
        startFadeTimer()
    }

    /// OWE's start fade-in: a wallpaper about to be heard starts silent and eases in.
    private func fadeInFromSilence() {
        guard fadeTarget > 0 else { return }
        fade = 0
        applyGain()
        startFadeTimer()
    }

    /// Steps the fade while no frame does, until it reaches its target.
    private func startFadeTimer() {
        guard fade != fadeTarget, fadeTimer == nil else { return }
        lastFadeTime = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = CACurrentMediaTime()
            let seconds = now - self.lastFadeTime
            self.lastFadeTime = now
            // Frames step the fade while they come.
            guard now - self.lastFrameFade > Self.frameGap else { return }
            self.stepFade(min(max(seconds, SceneClock.minimumFrameDelta), SceneClock.maximumFrameDelta))
        }
        fadeTimer = timer
        // On the owner's run loop (the renderer's render thread), so the fade and the frames step
        // the same state on one thread. Common modes: default-mode timers stall while menus track.
        RunLoop.current.add(timer, forMode: .common)
    }

    /// Heard at `target`, or silent at 0 (previews, captures and tests).
    func setTargetGain(_ target: Float) {
        setTarget(level: max(target, 0), audible: target > 0)
    }

    /// A drawn frame's step of the fade: `frameSeconds` is its wall step, clamped as the scene
    /// clock clamps it (`SceneClock.frame`).
    func advanceFade(frameSeconds: Double) {
        lastFrameFade = CACurrentMediaTime()
        guard fade != fadeTarget else { return }
        stepFade(frameSeconds)
    }

    /// One step of WE's fade, `seconds` long.
    func stepFade(_ seconds: Double) {
        fade = SceneClock.ease(fade, toward: fadeTarget, seconds: max(seconds, 0))
        applyGain()
        if fade == fadeTarget {
            fadeTimer?.invalidate()
            fadeTimer = nil
        }
        idleIfSilent()
    }

    /// `fade × level` to every layer, when it changed.
    private func applyGain() {
        let next = fade * level
        guard next != gain else { return }
        gain = next
        for id in order { layers[id]?.playback.setSceneGain(next) }
    }

    /// The one mixer of this wallpaper instance, made when the first voice plays.
    private func sharedMixer() -> SceneSoundMixer {
        if let mixer { return mixer }
        let made = SceneSoundMixer(label: label, offline: offline)
        mixer = made
        return made
    }

    /// Pauses the engine while no voice plays.
    private func idleIfSilent() {
        guard let mixer else { return }
        let anyPlaying = layers.values.contains { $0.playback.hasSoundingVoice }
        if !anyPlaying { mixer.idle() }
    }

    /// The mixer (tests render it offline).
    var soundMixer: SceneSoundMixer? { mixer }
}
