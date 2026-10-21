import AVFoundation

/// One wallpaper instance's audio graph: an `AVAudioEngine` whose main mixer takes every sound
/// layer's voices. It is made when a voice first plays (a muted wallpaper, or a display that
/// doesn't play the wallpaper's sound, never touches the audio hardware), starts then, and pauses
/// when the layers go silent. Owner thread (the renderer's render thread).
///
/// The engine always renders in manual rendering mode, so it never makes its own hardware output:
/// that `AUHAL` would open the default output device with its inputs, which makes macOS ask for
/// the microphone and holds the calling thread (here the render thread) in coreaudiod until the
/// prompt is answered. Live, a `ManualRenderingOutput` pulls its frames onto the default output
/// device without its inputs (`OutputOnlyAudioDevice`), starting and stopping off this thread;
/// offline (tests) the caller pulls them (`AVAudioEngine.renderOffline`).
final class SceneSoundMixer {
    let engine = AVAudioEngine()
    private var failed = false
    private let label: String
    /// Where a live engine plays; nil offline, or without an output device (silent, logged).
    private let output: ManualRenderingOutput?
    /// Where spatialized voices meet (`attachSpatial`), made with the first of them.
    private var spatialBus: AVAudioMixerNode?

    /// `offline` renders on demand (`AVAudioEngine.renderOffline`) instead of to `device`.
    init(label: String, offline: AVAudioFormat? = nil, device: OutputOnlyAudioDevice? = WallpaperServices.shared.sceneSoundOutput) {
        self.label = label
        let mode: AVAudioEngineManualRenderingMode = offline == nil ? .realtime : .offline
        // Live: the device's rate, so the output copies frames without resampling.
        let rate = device?.sampleRate ?? 48_000
        guard let format = offline ?? AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else {
            failed = true
            output = nil
            return
        }
        do {
            try engine.enableManualRenderingMode(mode, format: format, maximumFrameCount: ManualRenderingOutput.maximumFrameCount)
        } catch {
            OWELog.error(.audio, "\(label): \(offline == nil ? "" : "offline ")sound rendering is unavailable: \(error)")
            failed = true
            output = nil
            return
        }
        if offline == nil, let device {
            output = ManualRenderingOutput(device: device, render: engine.manualRenderingBlock, format: format, label: label)
        } else {
            output = nil
        }
    }

    deinit {
        // The engine stays until its output no longer pulls from it; disposing it talks to
        // coreaudiod, which must not stall the renderer, so it goes on a queue of its own.
        let engine = self.engine
        guard let output else {
            DispatchQueue.global(qos: .utility).async { engine.stop() }
            return
        }
        output.shutdown { engine.stop() }
    }

    func attach(_ node: AVAudioPlayerNode, format: AVAudioFormat) {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }

    func detach(_ node: AVAudioNode) {
        engine.detach(node)
    }

    /// Attaches a voice whose left and right gains are set on their own
    /// (`SceneSoundSpatialization`): the player feeds a stage mixer, and the stage's input on a
    /// stereo bus takes the gains as a volume and a balance. That input pans the (stereo) player's
    /// signal linearly: left × min(1, 1 − pan), right × min(1, 1 + pan).
    func attachSpatial(_ node: AVAudioPlayerNode, format: AVAudioFormat) -> AVAudioMixerNode? {
        guard let stereo = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 2) else { return nil }
        let bus: AVAudioMixerNode
        if let spatialBus {
            bus = spatialBus
        } else {
            bus = AVAudioMixerNode()
            engine.attach(bus)
            engine.connect(bus, to: engine.mainMixerNode, format: stereo)
            spatialBus = bus
        }
        let stage = AVAudioMixerNode()
        engine.attach(node)
        engine.attach(stage)
        engine.connect(node, to: stage, format: format)
        engine.connect(stage, to: bus, format: stereo)
        return stage
    }

    /// A stage's left and right gains (`attachSpatial`), as its volume and balance on the bus.
    static func setGains(_ gains: SIMD2<Float>, of stage: AVAudioMixerNode) {
        let left = max(gains.x, 0), right = max(gains.y, 0)
        let level = max(left, right)
        stage.volume = level
        stage.pan = level > 0 ? (right - left) / level : 0
    }

    /// Starts the engine if it isn't running, and its output; false (logged once) when it can't.
    /// Starting a manual-rendering engine touches no hardware, so this never waits on coreaudiod.
    func run() -> Bool {
        if engine.isRunning { return true }
        guard !failed else { return false }
        do {
            engine.prepare()
            try engine.start()
            output?.setRunning(true)
            return true
        } catch {
            failed = true
            OWELog.error(.audio, "\(label): the sound engine can't start, sound layers stay silent: \(error)")
            return false
        }
    }

    /// Pauses the engine and its output (nothing plays).
    func idle() {
        guard engine.isRunning else { return }
        output?.setRunning(false)
        engine.pause()
    }
}
