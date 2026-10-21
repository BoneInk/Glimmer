import AVFoundation
import CoreAudio

/// System audio through a Core Audio process tap (macOS 14.2+): a global stereo tap, a private
/// aggregate device that reads it, and an IO block that converts each buffer to the consumer
/// pipeline's format (`CaptureFormatConverter`). Needs only the System Audio Recording permission.
///
/// Threading: `start()` and `stop()` are called by one owner, never concurrently (at most one
/// capture exists and `SystemAudioCapture` starts and stops it in turn). The IO block runs on
/// `ioQueue`, which alone touches `converter` and `tapBuffers` while the device runs.
final class ProcessTapAudioCapture {
    /// Receives 48 kHz non-interleaved float stereo (left, right) on the IO queue.
    typealias Consumer = (UnsafeBufferPointer<Float>, UnsafeBufferPointer<Float>) -> Void

    struct StartError: Error, CustomStringConvertible {
        let description: String
    }

    static var isSupported: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    private let consume: Consumer
    /// Called with a reason when the capture no longer matches the hardware (the default output
    /// device or its sample rate changed) and should be restarted. Runs on an arbitrary queue.
    private let onInterruption: (String) -> Void
    private let ioQueue = DispatchQueue(label: "com.owe.audio.process-tap", qos: .userInteractive)
    private let listenerQueue = DispatchQueue(label: "com.owe.audio.process-tap-listeners")

    /// Set by `start()`, cleared by `stop()`; `stop()` does nothing while it's false, so the
    /// `deinit` after an explicit `stop()` never waits on the IO queue.
    private var isStarted = false
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var listeners: [(object: AudioObjectID, address: AudioObjectPropertyAddress,
                             block: AudioObjectPropertyListenerBlock)] = []

    // IO queue only while the device runs.
    private var converter: CaptureFormatConverter?
    private var tapBuffers: UnsafeMutableAudioBufferListPointer?

    init(consume: @escaping Consumer, onInterruption: @escaping (String) -> Void) {
        self.consume = consume
        self.onInterruption = onInterruption
    }

    deinit {
        stop()
    }

    /// Throws, with everything already torn down, when any step fails.
    func start() throws {
        guard #available(macOS 14.2, *) else {
            throw StartError(description: "process taps need macOS 14.2")
        }
        isStarted = true
        do {
            try startTap()
        } catch {
            stop()
            throw error
        }
    }

    @available(macOS 14.2, *)
    private func startTap() throws {
        let description = Self.tapDescription()
        try check(AudioHardwareCreateProcessTap(description, &tapID), "create the process tap")
        let tapUID = description.uuid.uuidString

        let outputDevice: AudioObjectID = try Self.property(
            AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
            default: AudioObjectID(kAudioObjectUnknown))
        let outputUID: String = try Self.property(outputDevice, kAudioDevicePropertyDeviceUID,
                                                  default: "" as CFString) as String
        try check(AudioHardwareCreateAggregateDevice(
            Self.aggregateDescription(outputUID: outputUID, tapUID: tapUID) as CFDictionary, &aggregateID),
                  "create the aggregate device")

        var streamDescription: AudioStreamBasicDescription = try Self.property(
            tapID, kAudioTapPropertyFormat, default: AudioStreamBasicDescription())
        // The aggregate device clocks the tap with drift compensation, so its buffers arrive at
        // the device's rate. Reading it is optional: the tap's own rate is the fallback.
        if let rate: Float64 = try? Self.property(aggregateID, kAudioDevicePropertyNominalSampleRate,
                                                  default: Float64(0)), rate > 0 {
            streamDescription.mSampleRate = rate
        }
        guard let format = AVAudioFormat(streamDescription: &streamDescription),
              let converter = CaptureFormatConverter(inputFormat: format) else {
            throw StartError(description: "unsupported tap format \(streamDescription)")
        }
        self.converter = converter
        tapBuffers = AudioBufferList.allocate(maximumBuffers: Int(format.isInterleaved ? 1 : format.channelCount))

        try check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, ioQueue) { [weak self] _, input, _, _, _ in
            self?.process(input)
        }, "create the IO block")
        addListener(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
                    reason: "the default output device changed")
        addListener(aggregateID, kAudioDevicePropertyNominalSampleRate, reason: "the output sample rate changed")
        addListener(aggregateID, kAudioDevicePropertyDeviceIsAlive, reason: "the output device went away")
        try check(AudioDeviceStart(aggregateID, ioProcID), "start the aggregate device")
    }

    /// Every process's output, including this app's own sounds: WE's loopback capture hears its
    /// own wallpapers too, and the ScreenCaptureKit path keeps `excludesCurrentProcessAudio` off.
    /// Private, so no other app sees the tap; unmuted, so playback is untouched.
    @available(macOS 14.2, *)
    static func tapDescription() -> CATapDescription {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "Open Wallpaper Engine system audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        return description
    }

    /// A private aggregate device clocked by the default output device, with the tap as its input.
    static func aggregateDescription(outputUID: String, tapUID: String) -> [String: Any] {
        [
            kAudioAggregateDeviceNameKey: "Open Wallpaper Engine system audio",
            kAudioAggregateDeviceUIDKey: "com.owe.audio.process-tap.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]]
        ]
    }

    /// Stops and destroys everything `start()` created. Safe to call more than once.
    func stop() {
        guard isStarted else { return }
        isStarted = false
        for listener in listeners {
            var address = listener.address
            let status = AudioObjectRemovePropertyListenerBlock(listener.object, &address, listenerQueue, listener.block)
            if status != noErr { OWELog.debug(.audio, "Removing a process tap listener failed (status \(status))") }
        }
        listeners = []
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                logFailure(AudioDeviceStop(aggregateID, ioProcID), "stop the aggregate device")
                logFailure(AudioDeviceDestroyIOProcID(aggregateID, ioProcID), "destroy the IO block")
            }
            logFailure(AudioHardwareDestroyAggregateDevice(aggregateID), "destroy the aggregate device")
        }
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if #available(macOS 14.2, *), tapID != kAudioObjectUnknown {
            logFailure(AudioHardwareDestroyProcessTap(tapID), "destroy the process tap")
        }
        tapID = AudioObjectID(kAudioObjectUnknown)
        // The device is stopped, so this drains the last IO block before its buffers go away.
        ioQueue.sync {
            converter = nil
            if let tapBuffers { free(tapBuffers.unsafeMutablePointer) }
            tapBuffers = nil
        }
    }

    // MARK: - IO

    private func process(_ input: UnsafePointer<AudioBufferList>) {
        guard let converter, let tapBuffers else { return }
        let all = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard Self.copyTrailingBuffers(from: all, into: tapBuffers), let first = tapBuffers.first else { return }
        let bytesPerFrame = converter.inputFormat.streamDescription.pointee.mBytesPerFrame
        guard bytesPerFrame > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: converter.inputFormat,
                                         bufferListNoCopy: tapBuffers.unsafePointer, deallocator: nil) else { return }
        pcm.frameLength = min(first.mDataByteSize / bytesPerFrame, pcm.frameCapacity)
        guard let output = converter.convert(pcm), let channels = output.floatChannelData else { return }
        let count = Int(output.frameLength)
        consume(UnsafeBufferPointer(start: channels[0], count: count),
                UnsafeBufferPointer(start: channels[1], count: count))
    }

    /// Points `target`'s buffers at the last `target.count` buffers of `all`. The aggregate device
    /// lists its sub-device's own input streams (a headset's microphone, say) before its taps, so
    /// the tap's buffers are the trailing ones. False when `all` has too few buffers.
    static func copyTrailingBuffers(from all: UnsafeMutableAudioBufferListPointer,
                                    into target: UnsafeMutableAudioBufferListPointer) -> Bool {
        let count = target.count
        guard count > 0, all.count >= count else { return false }
        let offset = all.count - count
        for index in 0..<count { target[index] = all[offset + index] }
        return true
    }

    // MARK: - Core Audio helpers

    private func addListener(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, reason: String) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.onInterruption(reason) }
        let status = AudioObjectAddPropertyListenerBlock(object, &address, listenerQueue, block)
        guard status == noErr else {
            OWELog.error(.audio, "Unable to watch for \(reason) (status \(status)); the process tap won't follow it.")
            return
        }
        listeners.append((object, address, block))
    }

    private static func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                    default value: T) throws -> T {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var result = value
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &result) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        guard status == noErr else {
            throw StartError(description: "reading property \(Self.fourCharacterCode(selector)) failed (status \(status))")
        }
        return result
    }

    private func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else { throw StartError(description: "unable to \(step) (status \(status))") }
    }

    private func logFailure(_ status: OSStatus, _ step: String) {
        guard status != noErr else { return }
        OWELog.debug(.audio, "Process tap teardown: unable to \(step) (status \(status))")
    }

    private static func fourCharacterCode(_ value: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }
        return String(bytes: bytes, encoding: .ascii) ?? String(value)
    }
}
