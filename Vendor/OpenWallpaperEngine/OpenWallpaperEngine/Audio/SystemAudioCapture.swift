import Accelerate
import AVFoundation
import Cocoa
import CoreMedia
import ScreenCaptureKit

/// System audio capture: the capture itself and its restarts, the overall level (video music
/// sync) and WE's spectrum analyzer (shaders' `g_AudioSpectrum*`, SceneScript's
/// `registerAudioBuffers`). Owned by `WallpaperServices`.
///
/// The audio comes from a Core Audio process tap on macOS 14.2+ (System Audio Recording
/// permission), or from a ScreenCaptureKit stream (Screen Recording) before that or when the tap
/// can't start, or from the recording device chosen in Settings (`recordingDevice`, Microphone
/// permission) (`SystemAudioBackend`). All feed `consume(left:right:)`.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private let levelLock = NSLock()
    private var level: Double = 0

    /// Guards `stream`, `processTap` and `inputCapture`, the one running capture (at most one is
    /// set); capture starts and stops on arbitrary tasks.
    private let captureLock = NSLock()
    private var stream: SCStream?
    private var processTap: ProcessTapAudioCapture?
    private var inputCapture: InputDeviceAudioCapture?

    /// Only touched on the main actor. Never starts a capture that would make macOS prompt:
    /// ScreenCaptureKit shows the Screen Recording prompt itself whenever that grant is missing.
    @MainActor private lazy var permissionGate = AudioCapturePermissionGate(
        preflight: { [weak self] in !(self?.backendCandidates().isEmpty ?? true) },
        isAlertDismissed: { GlobalSettingsViewModel.isAudioPermissionAlertDismissed })
    /// Only touched on the main actor. The single owner of capture starts, so at most one
    /// capture exists app-wide.
    @MainActor private lazy var restartScheduler = CaptureRestartScheduler(
        schedule: { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated(work) }
        },
        start: { [weak self] in self?.startSystemAudioCapture() })

    /// The consumers that need audio now. Capture runs only while there is one, and stops
    /// `idleGrace` seconds after the last one goes.
    let demand = AudioCaptureDemand(schedule: { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    })

    override init() {
        super.init()
        // Unit tests run ad-hoc signed with this bundle id; a capture request from them is denied
        // and that denial replaces the user's grant for the real app.
        guard !SceneBackendRuntimeContext.isActive, ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        Task { @MainActor [weak self] in self?.setUpSystemAudioCapture() }
    }

    /// The backends a start may try now, without prompting (`SystemAudioBackend.candidates`).
    @MainActor
    func backendCandidates() -> [SystemAudioBackend] {
        let tapSupported = ProcessTapAudioCapture.isSupported
        return SystemAudioBackend.candidates(
            tapSupported: tapSupported,
            tapPermission: tapSupported ? SystemAudioRecordingPermission.status : .notDetermined,
            screenRecordingGranted: CGPreflightScreenCaptureAccess(),
            inputDevice: recordingDevice?.uid,
            microphoneGranted: recordingDevice != nil && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized)
    }

    /// WE's "Audio recording device" (`GlobalSettings.audioRecordingDevice`): nil records the
    /// system output (WE's default), a device records that device while it is connected and the
    /// Microphone permission is granted, and the system output otherwise. A change restarts capture.
    @MainActor var recordingDevice: AudioInputDevice? {
        didSet {
            guard recordingDevice != oldValue else { return }
            OWELog.info(.audio, "Audio recording device: \(recordingDevice.map { "\($0.name) (\($0.uid))" } ?? "system output").")
            guard !SceneBackendRuntimeContext.isActive, ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
            deviceListMonitor = recordingDevice == nil ? nil : AudioDeviceListMonitor { [weak self] in
                self?.deviceListDidChange()
            }
            restartSystemAudioCapture(reason: "the recording device changed")
        }
    }
    /// Watches for the chosen recording device being connected or disconnected.
    @MainActor private var deviceListMonitor: AudioDeviceListMonitor?

    /// Moves capture to the chosen device when it is connected, and off it when it goes away.
    @MainActor
    private func deviceListDidChange() {
        guard let recordingDevice else { return }
        captureLock.lock()
        let recordsDevice = inputCapture != nil
        captureLock.unlock()
        let connected = AudioInputDevices.deviceID(uid: recordingDevice.uid) != nil
        guard connected != recordsDevice else { return }
        restartSystemAudioCapture(reason: connected ? "the recording device was connected" : "the recording device was disconnected")
    }

    @MainActor
    private func setUpSystemAudioCapture() {
        observeCaptureInterruptions()
        demand.observe { [weak self] active in
            MainActor.assumeIsolated { self?.demandDidChange(active: active) }
        }
        if permissionGate.canCapture() {
            if demand.isDemanded { restartScheduler.requestRestart() }
        } else {
            OWELog.info(.audio, "No system audio permission granted; system audio capture is off.")
            if permissionGate.shouldAlertMissingPermission() {
                NotificationCenter.default.post(name: .audioCapturePermissionMissing, object: nil)
            }
        }
    }

    /// A capture does not survive system sleep, and a ScreenCaptureKit stream not a display
    /// reconfiguration either; nothing else would ever start a new one, so every audio-reactive
    /// feature would stay silent until the app is relaunched. (The process tap watches its own
    /// output device, `ProcessTapAudioCapture.onInterruption`.)
    @MainActor
    private func observeCaptureInterruptions() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemDidWake), name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    // AppKit posts all three on the main thread.
    @MainActor @objc private func systemDidWake() {
        restartSystemAudioCapture(reason: "system woke")
    }

    /// Only a ScreenCaptureKit stream depends on the displays.
    @MainActor @objc private func screenParametersDidChange() {
        captureLock.lock()
        let usesScreenCapture = stream != nil
        captureLock.unlock()
        guard usesScreenCapture else { return }
        restartSystemAudioCapture(reason: "display configuration changed")
    }

    @MainActor @objc private func applicationDidBecomeActive() {
        recheckCapturePermission()
        followRecordingDevicePermission()
    }

    /// The Microphone permission for the chosen recording device may have been granted or revoked
    /// (in Settings, or System Settings › Privacy & Security): capture moves to the device, or
    /// back to the system output. Never prompts.
    @MainActor
    func followRecordingDevicePermission() {
        guard !SceneBackendRuntimeContext.isActive, ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              let recordingDevice else { return }
        captureLock.lock()
        let recordsDevice = inputCapture != nil
        let running = recordsDevice || stream != nil || processTap != nil
        captureLock.unlock()
        let wantsDevice = backendCandidates().first == .inputDevice(uid: recordingDevice.uid)
            && AudioInputDevices.deviceID(uid: recordingDevice.uid) != nil
        guard running, wantsDevice != recordsDevice else { return }
        restartSystemAudioCapture(reason: wantsDevice ? "the Microphone permission was granted" : "the Microphone permission was revoked")
    }

    /// Starts capture if a permission was granted since the last check. Never prompts, so it is
    /// safe to call whenever the app activates or the Permissions page appears.
    @MainActor
    func recheckCapturePermission() {
        guard !SceneBackendRuntimeContext.isActive, ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        guard permissionGate.becameGranted() else { return }
        OWELog.info(.audio, "System audio permission granted; starting system audio capture.")
        restartScheduler.reset()
        if demand.isDemanded, isRecordingEnabled { restartScheduler.requestRestart() }
    }

    /// WE's "Toggle audio recording" hotkey: off stops capture whatever the wallpapers need, so
    /// audio-reactive wallpapers hear silence; on starts it again when one needs it. Not saved:
    /// every launch records.
    @MainActor var isRecordingEnabled = true {
        didSet {
            guard isRecordingEnabled != oldValue else { return }
            OWELog.info(.audio, "Audio recording turned \(isRecordingEnabled ? "on" : "off").")
            if isRecordingEnabled {
                restartSystemAudioCapture(reason: "audio recording turned on")
            } else {
                stopSystemAudioCapture()
            }
        }
    }

    /// Starts capture when the first consumer arrives and stops it once the last one has been
    /// gone for the demand's grace period.
    @MainActor
    private func demandDidChange(active: Bool) {
        guard active else { return stopSystemAudioCapture() }
        captureLock.lock()
        let running = stream != nil || processTap != nil || inputCapture != nil
        captureLock.unlock()
        guard !running else { return }
        restartSystemAudioCapture(reason: "a wallpaper needs audio")
    }

    /// Stops the capture and cancels any queued start; the next demand starts a new one.
    @MainActor
    private func stopSystemAudioCapture() {
        restartScheduler.reset()
        let current = takeRunningCapture()
        resetAudioLevels()
        guard current.stream != nil || current.tap != nil || current.input != nil else { return }
        OWELog.info(.audio, "No wallpaper needs audio; stopping system audio capture.")
        Task { await Self.stop(current) }
    }

    /// The default output device changed (`OutputDeviceChangeMonitor`): a new capture follows it.
    @MainActor
    func outputDeviceDidChange() {
        guard !SceneBackendRuntimeContext.isActive, ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        restartSystemAudioCapture(reason: "the default output device changed")
    }

    @MainActor
    private func restartSystemAudioCapture(reason: String) {
        guard isRecordingEnabled, demand.isDemanded, permissionGate.canCapture() else { return }
        OWELog.info(.audio, "Restarting system audio capture: \(reason).")
        restartScheduler.requestRestart()
    }

    /// Without this, visuals stay frozen on the last buffer that arrived before capture stopped.
    private func resetAudioLevels() {
        levelLock.lock()
        level = 0
        levelLock.unlock()
        audioSpectrumAnalyzer.reset()
    }

    var audioLevel: Double {
        levelLock.lock()
        defer { levelLock.unlock() }
        return level
    }

    private typealias RunningCapture = (stream: SCStream?, tap: ProcessTapAudioCapture?, input: InputDeviceAudioCapture?)

    private func takeRunningCapture() -> RunningCapture {
        captureLock.lock()
        defer { captureLock.unlock() }
        let current = (stream, processTap, inputCapture)
        stream = nil
        processTap = nil
        inputCapture = nil
        return current
    }

    private static func stop(_ capture: RunningCapture) async {
        capture.tap?.stop()
        capture.input?.stop()
        guard let stream = capture.stream else { return }
        do { try await stream.stopCapture() } catch {
            OWELog.debug(.audio, "Stopping capture stream failed: \(error.localizedDescription)")
        }
    }

    /// Called only by `restartScheduler`, which guarantees a single start in flight; the previous
    /// capture is stopped before a new one is created.
    @MainActor
    private func startSystemAudioCapture() {
        let previous = takeRunningCapture()
        resetAudioLevels()
        let candidates = backendCandidates()
        guard !candidates.isEmpty else {
            // Revoked while the start was queued. Touching ScreenCaptureKit now would prompt.
            Task { await Self.stop(previous) }
            restartScheduler.reset()
            restartScheduler.finished(success: true)
            return
        }
        Task { [weak self] in
            await Self.stop(previous)
            let success = await self?.startCapture(trying: candidates) ?? false
            await MainActor.run { [weak self] in
                guard let self else { return }
                // The last consumer left while the capture was starting.
                if success, !self.demand.isDemanded || !self.isRecordingEnabled { self.stopSystemAudioCapture() }
                if self.restartScheduler.finished(success: success) {
                    OWELog.error(.audio, "Giving up on system audio capture after \(self.restartScheduler.maxFailures) failed attempts; it restarts on the next wake, display change or permission change.")
                }
            }
        }
    }

    /// Tries each backend in turn; a tap that can't start falls back to ScreenCaptureKit.
    private func startCapture(trying candidates: [SystemAudioBackend]) async -> Bool {
        for backend in candidates {
            switch backend {
            case .inputDevice(let uid):
                if startInputDevice(uid: uid) { return true }
            case .processTap:
                if startProcessTap() { return true }
            case .screenCapture:
                if await createAndStartStream() { return true }
            }
        }
        return false
    }

    private func startProcessTap() -> Bool {
        let tap = ProcessTapAudioCapture(
            consume: { [weak self] left, right in self?.consume(left: left, right: right) },
            onInterruption: { [weak self] reason in
                Task { @MainActor [weak self] in self?.restartSystemAudioCapture(reason: reason) }
            })
        do {
            try tap.start()
        } catch {
            OWELog.error(.audio, "Failed to start Core Audio process tap audio capture: \(error)")
            return false
        }
        captureLock.lock()
        processTap = tap
        captureLock.unlock()
        OWELog.info(.audio, "Core Audio process tap audio capture started.")
        return true
    }

    private func startInputDevice(uid: String) -> Bool {
        let capture = InputDeviceAudioCapture(
            uid: uid,
            consume: { [weak self] left, right in self?.consume(left: left, right: right) },
            onInterruption: { [weak self] reason in
                Task { @MainActor [weak self] in self?.restartSystemAudioCapture(reason: reason) }
            })
        do {
            try capture.start()
        } catch {
            OWELog.error(.audio, "Failed to record from the chosen audio recording device, recording the system output instead: \(error)")
            return false
        }
        captureLock.lock()
        inputCapture = capture
        captureLock.unlock()
        OWELog.info(.audio, "Recording device audio capture started.")
        return true
    }

    private func createAndStartStream() async -> Bool {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            OWELog.error(.audio, "Unable to read shareable content: \(error.localizedDescription)")
            return false
        }
        guard let display = content.displays.first else {
            OWELog.error(.audio, "No shareable display found for ScreenCaptureKit audio capture.")
            return false
        }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let stream = SCStream(filter: filter, configuration: Self.streamConfiguration(), delegate: self)
        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))
            // Takes the video frames (one 2×2 frame a second) and drops them at once; without a
            // screen output ScreenCaptureKit logs every frame it has nowhere to send.
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global(qos: .utility))
            try await stream.startCapture()
        } catch {
            OWELog.error(.audio, "Failed to start ScreenCaptureKit audio capture: \(error.localizedDescription)")
            return false
        }
        setCurrentStream(stream)
        OWELog.info(.audio, "ScreenCaptureKit audio capture started.")
        return true
    }

    /// ScreenCaptureKit has no audio-only stream, so the video side is made as cheap as it gets:
    /// a 2×2 frame at most once a second, without the cursor. The default captures the whole
    /// display at its refresh rate, and an animated wallpaper dirties it every frame.
    static func streamConfiguration() -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = false
        configuration.sampleRate = Int(CaptureFormatConverter.outputSampleRate)
        configuration.channelCount = 2
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.showsCursor = false
        return configuration
    }

    private func setCurrentStream(_ stream: SCStream) {
        captureLock.lock()
        self.stream = stream
        captureLock.unlock()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        captureLock.lock()
        let wasCurrent = stream === self.stream
        if wasCurrent { self.stream = nil }
        captureLock.unlock()
        guard wasCurrent else { return }
        OWELog.error(.audio, "ScreenCaptureKit audio capture stopped: \(error.localizedDescription)")
        resetAudioLevels()
        Task { @MainActor [weak self] in self?.restartSystemAudioCapture(reason: "stream stopped") }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of outputType: SCStreamOutputType) {
        guard outputType == .audio else { return }
        feedScreenCaptureAudio(sampleBuffer)
    }

    // MARK: - Consumers

    /// WE's `g_AudioSpectrum*` source. Fed on the audio thread; the analyzer owns its own lock.
    private let audioSpectrumAnalyzer = AudioSpectrumAnalyzer(sampleRate: CaptureFormatConverter.outputSampleRate)

    /// The latest frame a scene's spectrum clock advanced to, without advancing anything.
    var audioSpectrumSnapshot: AudioSpectrumSnapshot { audioSpectrumAnalyzer.snapshot }

    /// WE's "Recording threshold" (`GlobalSettings.audioRecordingThreshold`), applied to the
    /// spectrum from the next captured buffer.
    var recordingThreshold: Double {
        get { audioSpectrumAnalyzer.recordingThreshold }
        set { audioSpectrumAnalyzer.recordingThreshold = newValue }
    }

    /// WE's "Recording volume" (`GlobalSettings.audioRecordingVolume`), applied to the spectrum
    /// from the next captured buffer.
    var recordingVolume: Double {
        get { audioSpectrumAnalyzer.recordingVolume }
        set { audioSpectrumAnalyzer.recordingVolume = newValue }
    }

    /// A consumer's own spectrum smoothing over this capture (`AudioSpectrumClock`).
    func makeAudioSpectrumClock(publishes: Bool) -> AudioSpectrumClock {
        audioSpectrumAnalyzer.makeClock(publishes: publishes)
    }

    /// The pipeline both backends feed, on their audio thread: 48 kHz float stereo, one buffer per
    /// channel (`CaptureFormatConverter.outputFormat`). Pass the same buffer twice for mono.
    private func consume(left: UnsafeBufferPointer<Float>, right: UnsafeBufferPointer<Float>) {
        audioSpectrumAnalyzer.ingest(left: left, right: right)
        let sampleCount = left.count + right.count
        guard sampleCount > 0 else { return }
        let squaredSum = Self.sumOfSquares(left) + Self.sumOfSquares(right)
        let normalizedLevel = min(Double(sqrt(squaredSum / Float(sampleCount))) * 8, 1)
        levelLock.lock()
        level = normalizedLevel
        levelLock.unlock()
    }

    private static func sumOfSquares(_ samples: UnsafeBufferPointer<Float>) -> Float {
        guard let base = samples.baseAddress, !samples.isEmpty else { return 0 }
        var sum: Float = 0
        vDSP_svesq(base, 1, &sum, vDSP_Length(samples.count))
        return sum
    }

    /// Splits the stream's buffer (non-interleaved float32) into its channels for `consume`.
    private func feedScreenCaptureAudio(_ sampleBuffer: CMSampleBuffer) {
        var sizeNeeded = 0
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &sizeNeeded, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0,
            blockBufferOut: nil) == noErr, sizeNeeded > 0 else { return }
        let listMemory = UnsafeMutableRawPointer.allocate(byteCount: sizeNeeded,
                                                          alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { listMemory.deallocate() }
        let listPointer = listMemory.bindMemory(to: AudioBufferList.self, capacity: 1)
        var retainedBlock: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: listPointer, bufferListSize: sizeNeeded,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &retainedBlock)
        guard status == noErr else {
            OWELog.debug(.audio, "Audio buffer list unavailable (status \(status))")
            return
        }
        let buffers = UnsafeMutableAudioBufferListPointer(listPointer)
        func channel(_ buffer: AudioBuffer) -> UnsafeBufferPointer<Float> {
            guard let data = buffer.mData else { return UnsafeBufferPointer(start: nil, count: 0) }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            return UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count)
        }
        guard let first = buffers.first else { return }
        let left = channel(first)
        let right = buffers.count > 1 ? channel(buffers[1]) : left
        withExtendedLifetime(retainedBlock) {
            consume(left: left, right: right)
        }
    }
}
