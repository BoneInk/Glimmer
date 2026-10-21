import CoreAudio
import Foundation

/// Reads Core Audio's process objects (macOS 14.2 and later): one per process that uses audio,
/// with its process id, bundle identifier and whether it is playing sound. Public API, no
/// permission needed. Safe on any thread.
@available(macOS 14.2, *)
enum CoreAudioProcessObjects {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    /// The process objects; the failing status when the list can't be read.
    static func list() -> Result<[AudioObjectID], OSStatusError> {
        var address = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size)
        guard status == noErr else { return .failure(OSStatusError(status: status)) }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        status = AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids)
        guard status == noErr else { return .failure(OSStatusError(status: status)) }
        return .success(Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size)))
    }

    /// The process's id; nil once it has quit.
    static func pid(of process: AudioObjectID) -> pid_t? {
        integer(process, kAudioProcessPropertyPID)
    }

    /// Whether the process is playing sound; nil once it has quit.
    static func isRunningOutput(_ process: AudioObjectID) -> Bool? {
        (integer(process, kAudioProcessPropertyIsRunningOutput) as UInt32?).map { $0 != 0 }
    }

    /// The process's bundle identifier; nil for a process without a bundle, or once it has quit.
    static func bundleIdentifier(of process: AudioObjectID) -> String? {
        var address = address(kAudioProcessPropertyBundleID)
        var result: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &result) == noErr else { return nil }
        let identifier = result?.takeRetainedValue() as String?
        return identifier?.isEmpty == false ? identifier : nil
    }

    /// A process that quits between the list and this read has no properties: not a failure.
    private static func integer<Value: FixedWidthInteger>(_ object: AudioObjectID,
                                                          _ selector: AudioObjectPropertySelector) -> Value? {
        var address = address(selector)
        var result: Value = 0
        var size = UInt32(MemoryLayout<Value>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result) == noErr else { return nil }
        return result
    }
}

/// A Core Audio call's failing status.
struct OSStatusError: Error, CustomStringConvertible {
    var status: OSStatus
    var description: String { "OSStatus \(status)" }
}
