import CoreAudio
import Foundation

/// Reads the system's recording devices and their IDs. Never prompts: listing devices needs no
/// permission, only reading their audio does (Microphone).
enum AudioInputDevices {
    /// Every device with at least one input channel, in Core Audio's order, without this app's own
    /// private aggregate devices (which Core Audio doesn't list anyway).
    static func list() -> [AudioInputDevice] {
        deviceIDs().compactMap { id in
            guard inputChannelCount(of: id) > 0,
                  let uid = stringProperty(id, kAudioDevicePropertyDeviceUID), !uid.isEmpty,
                  !uid.hasPrefix("com.owe.audio.") else { return nil }
            return AudioInputDevice(uid: uid, name: stringProperty(id, kAudioObjectPropertyName) ?? uid)
        }
    }

    /// The device with `uid` that can record now, or nil when it isn't connected.
    static func deviceID(uid: String) -> AudioObjectID? {
        deviceIDs().first { inputChannelCount(of: $0) > 0 && stringProperty($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    static func deviceIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids)
        guard status == noErr else {
            OWELog.error(.audio, "Unable to list the audio devices (status \(status))")
            return []
        }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    /// The channels across the device's input streams (`kAudioDevicePropertyStreamConfiguration`).
    static func inputChannelCount(of device: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioObjectPropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, memory) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

/// Calls `onChange` (on the main queue) whenever a device is connected or disconnected, until it
/// is released. The audio settings refresh their device list with it, and a capture that fell back
/// from a disconnected recording device returns to it when it reconnects.
final class AudioDeviceListMonitor {
    private let queue = DispatchQueue(label: "com.owe.audio.device-list")
    private var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
    private let block: AudioObjectPropertyListenerBlock
    private let isListening: Bool

    init(onChange: @escaping @MainActor () -> Void) {
        block = { _, _ in DispatchQueue.main.async { MainActor.assumeIsolated(onChange) } }
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
        isListening = status == noErr
        if !isListening {
            OWELog.error(.audio, "Unable to watch the audio device list (status \(status)); connected devices show after reopening Settings.")
        }
    }

    deinit {
        guard isListening else { return }
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
    }
}
