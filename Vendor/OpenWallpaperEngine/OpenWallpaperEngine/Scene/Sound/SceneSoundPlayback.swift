import Foundation

/// Where a sound layer's files play: one voice per file, started from the beginning, paused,
/// resumed or stopped, at a gain. `SceneSoundVoices` plays them through AVAudioEngine; tests record.
protocol SceneSoundOutput: AnyObject {
    /// Starts `file` from its beginning; `loop` repeats it seamlessly until stopped.
    func start(file: Int, loop: Bool)
    func pause(file: Int)
    func resume(file: Int)
    func stop(file: Int)
    /// The file's gain (linear; WE's `volume² × sceneGain`).
    func setGain(_ gain: Float, file: Int)
}

/// One sound layer's playback exactly as wallpaper64.exe runs it (docs/scenescript-plan.md,
/// sound layers): `play()` 0x1401f5980, the per-frame update 0x1401f4f50, load 0x1401f4f20,
/// `stop()` 0x1401f6e60, `pause()` 0x1401f6f00, `isPlaying()` 0x1401f6fb0, the volume handler
/// 0x1401f4c20 and the wallpaper-volume setter 0x1401816d0.
///
/// - Gain is `volume² × sceneGain`; with no gain `play()` starts nothing.
/// - Every start picks one of the files at random (repeats allowed) and stops the others.
/// - `loop` with one file loops it natively; with several, each clip plays once and the next
///   random one starts when it ends (at frame granularity, like WE).
/// - `random` plays a clip, then waits `mintime + u·(maxtime − mintime)` after its end.
/// - `single` plays one clip once.
/// - A wallpaper gain of 0 (muted, paused, or another display plays the sound) pauses the files
///   and freezes the timers; a gain above 0 resumes them where they were.
///
/// Main thread (the renderer's).
final class SceneSoundPlayback {
    let mode: WESceneSound.PlaybackMode
    /// Each file's length in seconds.
    let durations: [Double]
    let minTime: Double
    let maxTime: Double
    private let output: SceneSoundOutput
    private let random: () -> Double

    /// `volume` (linear; scripts write it).
    private(set) var volume: Float
    /// The wallpaper's gain (the app's volume and mute, faded).
    private(set) var sceneGain: Float
    /// Paused by a script (WE's bit 30).
    private(set) var isPaused = false
    /// Stopped by a script (bit 31).
    private(set) var isStopped = false
    /// `startsilent`, until the first `play()` (bit 1).
    private(set) var isSilentUntilPlayed: Bool
    /// Seconds until the next `play()` (0x2fc): the end of a clip in `loop` with several files,
    /// the end of the pause after a clip in `random`.
    private(set) var restartTimer: Double = 0
    /// Seconds left of the clip (0x300), counted while the wallpaper's gain is above 0.
    private(set) var clipTimer: Double = 0

    private enum Voice: Equatable {
        case idle, playing, paused
    }

    private var voices: [Voice]
    private var remaining: [Double]
    private var looping: [Bool]
    /// A file has started at least once.
    private var hasStarted = false

    init(sound: WESceneSound, durations: [Double], volume: Float, sceneGain: Float, output: SceneSoundOutput,
         random: @escaping () -> Double = { Double.random(in: 0..<1) }) {
        mode = sound.playbackMode
        self.durations = durations
        minTime = sound.minTime
        maxTime = sound.maxTime
        self.output = output
        self.random = random
        self.volume = volume
        self.sceneGain = sceneGain
        isSilentUntilPlayed = sound.startSilent
        voices = Array(repeating: .idle, count: durations.count)
        remaining = Array(repeating: 0, count: durations.count)
        looping = Array(repeating: false, count: durations.count)
    }

    /// WE's gain for every file.
    var gain: Float { volume * volume * sceneGain }

    /// At load: plays unless `startsilent`.
    func load() {
        applyGain()
        if !isSilentUntilPlayed { play() }
    }

    // MARK: - Script API

    /// `play()`: resumes a paused layer where it was; otherwise (re)starts a random file, except
    /// during `random`'s pause.
    func play() {
        if isPaused {
            isPaused = false
            if let paused = voices.firstIndex(of: .paused), sceneGain > 0 { resume(paused) }
            return
        }
        if mode == .random, restartTimer != 0 { return }
        isStopped = false
        isSilentUntilPlayed = false
        guard gain > 0, !durations.isEmpty else { return }
        stopAll()
        let count = durations.count
        let file = min(count - 1, Int(random() * Double(count)))
        let nativeLoop = count <= 1 && mode == .loop
        start(file, loop: nativeLoop)
        let duration = durations[file]
        switch mode {
        case .loop:
            restartTimer = nativeLoop ? 0 : duration
            clipTimer = duration
        case .random:
            clipTimer = duration
            restartTimer = duration + minTime + random() * (maxTime - minTime)
        case .single:
            restartTimer = 0
            clipTimer = duration
        }
    }

    /// `stop()`: every file stops (their positions reset); the next `play()` starts afresh.
    func stop() {
        isStopped = true
        isPaused = false
        stopAll()
    }

    /// `pause()`: the playing files pause; `play()` resumes them.
    func pause() {
        guard !isPaused, !isStopped else { return }
        isPaused = true
        for file in voices.indices where voices[file] == .playing {
            voices[file] = .paused
            output.pause(file: file)
        }
    }

    /// Whether a voice is playing, even silently (the mixer idles when none is).
    var hasSoundingVoice: Bool { voices.contains(.playing) }

    /// `isPlaying()`.
    var isPlaying: Bool {
        if mode == .single, clipTimer <= 0 { return false }
        if mode == .random, restartTimer <= 0 { return false }
        guard !isPaused else { return false }
        return voices.indices.contains { voices[$0] != .idle && (looping[$0] || remaining[$0] > 0) }
    }

    /// `volume = …` (a script, or a user property): the new gain for every file, and a sound that
    /// could never start (no gain at load) starts now.
    func setVolume(_ newVolume: Float) {
        volume = newVolume
        applyGain()
        startIfItNeverCould()
    }

    // MARK: - Frame

    /// WE's per-frame update, `seconds` of real time since the last frame.
    func update(deltaTime seconds: Double) {
        guard !isPaused, !isStopped, seconds > 0 else { return }
        if sceneGain > 0 {
            for file in voices.indices where voices[file] == .playing && !looping[file] {
                remaining[file] -= seconds
                if remaining[file] <= 0 { voices[file] = .idle }
            }
            clipTimer -= seconds
        }
        if gain > 0, restartTimer > 0 {
            restartTimer -= seconds
            if restartTimer <= 0 {
                restartTimer = 0
                play()
            }
        }
    }

    /// The wallpaper's gain changed (`setWallpaperVolume`): at 0 the files pause (or, in `random`
    /// and `single`, stop once their clip is over); above 0 they resume unless a script paused them.
    func setSceneGain(_ newGain: Float) {
        sceneGain = newGain
        applyGain()
        if newGain <= 0 {
            for file in voices.indices where voices[file] == .playing {
                if mode != .loop, clipTimer <= 0 {
                    voices[file] = .idle
                    output.stop(file: file)
                } else {
                    voices[file] = .paused
                    output.pause(file: file)
                }
            }
        } else if !isPaused {
            for file in voices.indices where voices[file] == .paused { resume(file) }
            startIfItNeverCould()
        }
    }

    // MARK: - Voices

    private func startIfItNeverCould() {
        guard !hasStarted, !isPaused, !isStopped, !isSilentUntilPlayed, gain > 0 else { return }
        play()
    }

    private func applyGain() {
        let value = gain
        for file in voices.indices { output.setGain(value, file: file) }
    }

    private func start(_ file: Int, loop: Bool) {
        voices[file] = .playing
        looping[file] = loop
        remaining[file] = durations[file]
        hasStarted = true
        output.start(file: file, loop: loop)
    }

    private func resume(_ file: Int) {
        voices[file] = .playing
        output.resume(file: file)
    }

    /// Stops every file and the restart timer (0x1401f58e0).
    private func stopAll() {
        restartTimer = 0
        for file in voices.indices where voices[file] != .idle {
            voices[file] = .idle
            output.stop(file: file)
        }
    }
}
