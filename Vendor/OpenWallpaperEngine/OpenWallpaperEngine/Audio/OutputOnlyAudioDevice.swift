import CoreAudio
import Foundation

/// The default output device without its inputs: a private stacked aggregate (what Audio MIDI
/// Setup calls a Multi-Output Device) whose one sub-device is the system's default output device,
/// following it when it changes. Wallpaper sound plays through it: scene sound layers
/// (`ManualRenderingOutput`) and video wallpapers' players (`WallpaperAVPlayer`).
///
/// Why: a client of a device that also records (a USB or Bluetooth headset, a display's
/// microphone) makes coreaudiod check the Microphone permission, because a new IO proc uses the
/// device's input streams by default. The app declares a Microphone usage for WE's "Audio
/// recording device", so macOS then asks for the microphone as soon as a wallpaper plays sound,
/// and the HAL call that started the sound (`AudioComponentInstanceNew` for `AVAudioEngine`'s
/// output, `AudioQueueStart` for `AVPlayer`) waits in coreaudiod until the prompt is answered.
/// A stacked aggregate has no input streams, so nothing ever asks for the microphone unless the
/// user chooses a recording device (`InputDeviceAudioCapture`).
///
/// Thread safety: `lock` owns `aggregateID`; the device is made, re-pointed and destroyed on
/// `queue`. Making it is one HAL call that doesn't use any input, so it never waits on a prompt.
final class OutputOnlyAudioDevice: @unchecked Sendable {
    /// Its UID: stable for the app's life, so a player keeps it across device changes.
    let uid = "app.openwallpaperengine.output.\(UUID().uuidString)"
    private let queue = DispatchQueue(label: "com.owe.audio.output-device")
    private let lock = NSLock()
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var listener: AudioObjectPropertyListenerBlock?
    private var defaultOutputAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                                  mElement: kAudioObjectPropertyElementMain)

    /// Makes the device now (one quick HAL call, no input), then follows the default output device.
    init() {
        queue.sync { make() }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.defaultOutputDidChange() }
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultOutputAddress,
                                                         queue, listener)
        if status == noErr {
            self.listener = listener
        } else {
            OWELog.error(.audio, "Output device: can't watch the default output device (status \(status)); sound stays on the current one.")
        }
    }

    deinit {
        if let listener {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultOutputAddress, queue, listener)
        }
        let id = lock.withLock { aggregateID }
        if id != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(id) }
    }

    /// The aggregate, or nil when it couldn't be made (logged).
    var deviceID: AudioObjectID? {
        let id = lock.withLock { aggregateID }
        return id == kAudioObjectUnknown ? nil : id
    }

    /// Its sample rate now (its output device's), or nil without a device.
    var sampleRate: Float64? {
        guard let id = deviceID else { return nil }
        let rate = Self.nominalSampleRate(of: id)
        return rate > 0 ? rate : nil
    }

    static func nominalSampleRate(of device: AudioObjectID) -> Float64 {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr else { return 0 }
        return rate
    }

    /// A private stacked aggregate of the output device `outputUID`: the stack exposes only its
    /// sub-device's outputs.
    static func aggregateDescription(outputUID: String, uid: String) -> [String: Any] {
        [
            kAudioAggregateDeviceNameKey: "Open Wallpaper Engine output",
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
        ]
    }

    /// The number of input streams `device` has (none for this one).
    static func inputStreamCount(of device: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }

    // MARK: - Queue only

    private func make() {
        guard let outputUID = Self.defaultOutputUID() else {
            OWELog.error(.audio, "Output device: no default output device; wallpaper sound is silent until one is chosen.")
            return
        }
        var id = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(Self.aggregateDescription(outputUID: outputUID, uid: uid) as CFDictionary, &id)
        guard status == noErr, id != kAudioObjectUnknown else {
            OWELog.error(.audio, "Output device: can't make the output-only device for \(outputUID) (status \(status)); wallpaper sound is silent.")
            return
        }
        lock.withLock { aggregateID = id }
        OWELog.info(.audio, "Output device: wallpaper sound plays on \(outputUID) through an output-only device.")
    }

    /// Points the aggregate at the new default output device: its UID stays, so players and IO
    /// procs on it carry on.
    private func defaultOutputDidChange() {
        guard let id = deviceID else { return make() }
        guard let outputUID = Self.defaultOutputUID() else { return }
        var list = [outputUID] as CFArray
        var listAddress = AudioObjectPropertyAddress(mSelector: kAudioAggregateDevicePropertyFullSubDeviceList,
                                                     mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let listStatus = AudioObjectSetPropertyData(id, &listAddress, 0, nil, UInt32(MemoryLayout<CFArray>.size), &list)
        var main = outputUID as CFString
        var mainAddress = AudioObjectPropertyAddress(mSelector: kAudioAggregateDevicePropertyMainSubDevice,
                                                     mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let mainStatus = AudioObjectSetPropertyData(id, &mainAddress, 0, nil, UInt32(MemoryLayout<CFString>.size), &main)
        if listStatus == noErr, mainStatus == noErr {
            OWELog.info(.audio, "Output device: wallpaper sound follows the default output device to \(outputUID).")
        } else {
            OWELog.error(.audio, "Output device: can't move to \(outputUID) (status \(listStatus), \(mainStatus)); sound stays on the previous device.")
        }
    }

    private static func defaultOutputUID() -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return AudioInputDevices.stringProperty(device, kAudioDevicePropertyDeviceUID)
    }
}
