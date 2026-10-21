import AVFoundation

/// One sound layer's files as AVAudioEngine voices (the `SceneSoundOutput` `SceneSoundPlayback`
/// drives): an `AVAudioPlayerNode` per file, attached to the wallpaper's mixer on first use and
/// streaming the file from disk, as WE streams each file through its own `sf::Music`. A looping
/// file keeps two passes scheduled, so it wraps without a gap: when one has played, the next is
/// queued behind the other. A spatialized file plays through a stage of its own, which takes its
/// left and right gains (`setSpatialGains`). A mono file plays at OpenAL's level for a mono source,
/// `SceneSoundSpatialization.monoLevel` of a stereo file's in each channel (WE's capture: 1/1.6789):
/// its player outputs stereo, which copies the file to both channels at any sample rate (a mono
/// input to AVAudioMixerNode comes out at 0.707 or 1 by the mixer's rate). Main thread; the
/// players' completion handlers hop back to it (a player must not be scheduled from inside its own
/// callback).
final class SceneSoundVoices: SceneSoundOutput {
    private final class Voice {
        let node = AVAudioPlayerNode()
        var file: AVAudioFile?
        var attached = false
        /// A spatialized voice's stage (`SceneSoundMixer.attachSpatial`).
        var stage: AVAudioMixerNode?
        /// The gain `SceneSoundPlayback` set (`setGain`).
        var gain: Float = 1
    }

    private let files: [SceneSoundContent.File]
    /// The wallpaper's mixer, made on first use (`SceneSoundLayers`).
    private let makeMixer: () -> SceneSoundMixer?
    private var mixer: SceneSoundMixer?
    private let label: String
    private var voices: [Voice]
    /// A voice's loop keeps scheduling only while its generation stands.
    private var generations: [Int]
    private var reported = Set<Int>()
    /// The files that play spatialized, and their left and right gains (`setSpatialGains`).
    let spatialFiles: Set<Int>
    private var spatialGains: [Int: SIMD2<Float>] = [:]

    init(files: [SceneSoundContent.File], spatialFiles: Set<Int> = [], mixer: @escaping () -> SceneSoundMixer?,
         label: String) {
        self.files = files
        self.spatialFiles = spatialFiles
        makeMixer = mixer
        self.label = label
        voices = files.map { _ in Voice() }
        generations = Array(repeating: 0, count: files.count)
    }

    deinit {
        for index in voices.indices { stop(file: index) }
        for voice in voices where voice.attached {
            mixer?.detach(voice.node)
            if let stage = voice.stage { mixer?.detach(stage) }
        }
    }

    func start(file index: Int, loop: Bool) {
        guard let voice = prepared(index), let file = voice.file else { return }
        let generation = nextGeneration(index)
        voice.node.stop()
        let frames = AVAudioFrameCount(clamping: max(file.length, 0))
        guard frames > 0 else { return }
        if loop {
            schedule(file, frames: frames, on: voice.node, index: index, generation: generation)
            schedule(file, frames: frames, on: voice.node, index: index, generation: generation)
        } else {
            voice.node.scheduleSegment(file, startingFrame: 0, frameCount: frames, at: nil)
        }
        guard mixer?.run() == true else { return }
        voice.node.play()
    }

    func pause(file index: Int) {
        guard voices.indices.contains(index), voices[index].attached else { return }
        voices[index].node.pause()
    }

    func resume(file index: Int) {
        guard voices.indices.contains(index), voices[index].attached, mixer?.run() == true else { return }
        voices[index].node.play()
    }

    func stop(file index: Int) {
        guard voices.indices.contains(index), voices[index].attached else { return }
        _ = nextGeneration(index)
        voices[index].node.stop()
    }

    func setGain(_ gain: Float, file index: Int) {
        guard voices.indices.contains(index) else { return }
        voices[index].gain = gain
        applyGain(index)
    }

    /// The player's volume: the gain, at the mono level for a mono file that isn't spatialized (a
    /// spatialized one takes it in its stage's gains). Before the file is open its channels
    /// aren't known; `prepared` applies it again.
    private func applyGain(_ index: Int) {
        let voice = voices[index]
        let mono = voice.file?.processingFormat.channelCount == 1 && !spatialFiles.contains(index)
        voice.node.volume = voice.gain * (mono ? SceneSoundSpatialization.monoLevel : 1)
    }

    /// A spatialized file's left and right gains (`SceneSoundSpatialization.gains`), on top of
    /// its gain. Kept for a voice not yet attached.
    func setSpatialGains(_ gains: SIMD2<Float>, file index: Int) {
        guard spatialFiles.contains(index), spatialGains[index] != gains else { return }
        spatialGains[index] = gains
        if let stage = voices[index].stage { SceneSoundMixer.setGains(gains, of: stage) }
    }

    // MARK: - Private

    /// The voice with its file open and its node in the mixer; nil (logged once) when the file
    /// can't be opened.
    private func prepared(_ index: Int) -> Voice? {
        guard voices.indices.contains(index) else { return nil }
        let voice = voices[index]
        if voice.file == nil {
            do {
                voice.file = try AVAudioFile(forReading: files[index].url)
            } catch {
                if reported.insert(index).inserted {
                    OWELog.error(.audio, "\(label): sound '\(files[index].path)' can't be opened: \(error)")
                }
                return nil
            }
        }
        if !voice.attached, let file = voice.file {
            if mixer == nil { mixer = makeMixer() }
            guard let mixer else { return nil }
            var format = file.processingFormat
            if format.channelCount == 1 {
                guard let stereo = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 2) else {
                    return nil
                }
                format = stereo
            }
            if spatialFiles.contains(index) {
                guard let stage = mixer.attachSpatial(voice.node, format: format) else { return nil }
                SceneSoundMixer.setGains(spatialGains[index] ?? SIMD2(repeating: SceneSoundSpatialization.monoLevel),
                                         of: stage)
                voice.stage = stage
            } else {
                mixer.attach(voice.node, format: format)
            }
            voice.attached = true
            applyGain(index)
        }
        return voice
    }

    private func nextGeneration(_ index: Int) -> Int {
        generations[index] += 1
        return generations[index]
    }

    /// One pass of a looping file; when it has played, another is queued behind the pass now
    /// playing, so the loop never runs dry.
    private func schedule(_ file: AVAudioFile, frames: AVAudioFrameCount, on node: AVAudioPlayerNode, index: Int,
                          generation: Int) {
        node.scheduleSegment(file, startingFrame: 0, frameCount: frames, at: nil,
                             completionCallbackType: .dataPlayedBack) { [weak self, weak node] _ in
            DispatchQueue.main.async {
                guard let self, let node, self.generations[index] == generation else { return }
                self.schedule(file, frames: frames, on: node, index: index, generation: generation)
            }
        }
    }
}
