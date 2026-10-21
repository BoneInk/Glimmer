import AVFoundation
import CoreAudio

/// Audio from a recording device (WE's "Audio recording device" set to anything but its default):
/// an IO block on the device itself reads its first input stream and converts each buffer to the
/// consumer pipeline's format (`CaptureFormatConverter`). It needs the Microphone permission, which
/// covers every input device, loopback drivers such as BlackHole included.
///
/// Threading as `ProcessTapAudioCapture`: one owner starts and stops it in turn, and `ioQueue`
/// alone touches `converter` while the device runs.
final class InputDeviceAudioCapture {
    typealias Consumer = ProcessTapAudioCapture.Consumer

    struct StartError: Error, CustomStringConvertible {
        let description: String
    }

    private let uid: String
    private let consume: Consumer
    /// Called with a reason when the device went away or changed its format. Any queue.
    private let onInterruption: (String) -> Void
    private let ioQueue = DispatchQueue(label: "com.owe.audio.input-device", qos: .userInteractive)
    private let listenerQueue = DispatchQueue(label: "com.owe.audio.input-device-listeners")

    private var isStarted = false
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var listeners: [(address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []

    // IO queue only while the device runs.
    private var converter: CaptureFormatConverter?
    private var inputBuffer: UnsafeMutableAudioBufferListPointer?

    init(uid: String, consume: @escaping Consumer, onInterruption: @escaping (String) -> Void) {
        self.uid = uid
        self.consume = consume
        self.onInterruption = onInterruption
    }

    deinit {
        stop()
    }

    /// Throws, with everything already torn down, when the device isn't connected or can't start.
    func start() throws {
        isStarted = true
        do {
            try startDevice()
        } catch {
            stop()
            throw error
        }
    }

    private func startDevice() throws {
        guard let device = AudioInputDevices.deviceID(uid: uid) else {
            throw StartError(description: "the recording device \(uid) isn't connected")
        }
        deviceID = device
        var streamFormat = try Self.firstInputStreamFormat(of: device)
        guard let format = AVAudioFormat(streamDescription: &streamFormat),
              let converter = CaptureFormatConverter(inputFormat: format) else {
            throw StartError(description: "unsupported input format \(streamFormat)")
        }
        self.converter = converter
        inputBuffer = AudioBufferList.allocate(maximumBuffers: 1)

        try check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, device, ioQueue) { [weak self] _, input, _, _, _ in
            self?.process(input)
        }, "create the IO block")
        addListener(kAudioDevicePropertyDeviceIsAlive, reason: "the recording device went away")
        addListener(kAudioDevicePropertyNominalSampleRate, reason: "the recording device's sample rate changed")
        addListener(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput,
                    reason: "the recording device's channels changed")
        try check(AudioDeviceStart(device, ioProcID), "start the recording device")
    }

    /// The virtual (float) format of the device's first input stream, which is the format of the
    /// first buffer the IO block receives.
    static func firstInputStreamFormat(of device: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                 mScope: kAudioObjectPropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size)
        guard status == noErr, size >= UInt32(MemoryLayout<AudioObjectID>.size) else {
            throw StartError(description: "the recording device has no input stream (status \(status))")
        }
        var streams = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &streams)
        guard status == noErr, let first = streams.first else {
            throw StartError(description: "reading the recording device's streams failed (status \(status))")
        }
        var formatAddress = AudioObjectPropertyAddress(mSelector: kAudioStreamPropertyVirtualFormat,
                                                       mScope: kAudioObjectPropertyScopeGlobal,
                                                       mElement: kAudioObjectPropertyElementMain)
        var format = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioObjectGetPropertyData(first, &formatAddress, 0, nil, &formatSize, &format)
        guard status == noErr else {
            throw StartError(description: "reading the recording device's format failed (status \(status))")
        }
        return format
    }

    /// Stops and destroys everything `start()` created. Safe to call more than once.
    func stop() {
        guard isStarted else { return }
        isStarted = false
        for listener in listeners {
            var address = listener.address
            let status = AudioObjectRemovePropertyListenerBlock(deviceID, &address, listenerQueue, listener.block)
            if status != noErr { OWELog.debug(.audio, "Removing a recording device listener failed (status \(status))") }
        }
        listeners = []
        if deviceID != kAudioObjectUnknown, let ioProcID {
            logFailure(AudioDeviceStop(deviceID, ioProcID), "stop the recording device")
            logFailure(AudioDeviceDestroyIOProcID(deviceID, ioProcID), "destroy the IO block")
        }
        ioProcID = nil
        deviceID = AudioObjectID(kAudioObjectUnknown)
        // The device is stopped, so this drains the last IO block before its buffers go away.
        ioQueue.sync {
            converter = nil
            if let inputBuffer { free(inputBuffer.unsafeMutablePointer) }
            inputBuffer = nil
        }
    }

    // MARK: - IO

    private func process(_ input: UnsafePointer<AudioBufferList>) {
        guard let converter, let inputBuffer else { return }
        let all = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = all.first else { return }
        inputBuffer[0] = first
        let bytesPerFrame = converter.inputFormat.streamDescription.pointee.mBytesPerFrame
        guard bytesPerFrame > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: converter.inputFormat,
                                         bufferListNoCopy: inputBuffer.unsafePointer, deallocator: nil) else { return }
        pcm.frameLength = min(first.mDataByteSize / bytesPerFrame, pcm.frameCapacity)
        guard let output = converter.convert(pcm), let channels = output.floatChannelData else { return }
        let count = Int(output.frameLength)
        consume(UnsafeBufferPointer(start: channels[0], count: count),
                UnsafeBufferPointer(start: channels[1], count: count))
    }

    // MARK: - Core Audio helpers

    private func addListener(_ selector: AudioObjectPropertySelector,
                             scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, reason: String) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.onInterruption(reason) }
        let status = AudioObjectAddPropertyListenerBlock(deviceID, &address, listenerQueue, block)
        guard status == noErr else {
            OWELog.error(.audio, "Unable to watch for \(reason) (status \(status)); the recording won't follow it.")
            return
        }
        listeners.append((address, block))
    }

    private func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else { throw StartError(description: "unable to \(step) (status \(status))") }
    }

    private func logFailure(_ status: OSStatus, _ step: String) {
        guard status != noErr else { return }
        OWELog.debug(.audio, "Recording device teardown: unable to \(step) (status \(status))")
    }
}
