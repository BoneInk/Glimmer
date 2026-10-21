import Foundation

/// A Core Audio device that can record (it has input streams): a microphone, an audio interface,
/// or a loopback driver such as BlackHole. WE's "Audio recording device" lists these beside its
/// default, which on macOS is the system output (`AudioInputDevices`, `ProcessTapAudioCapture`).
struct AudioInputDevice: Codable, Equatable, Hashable, Identifiable {
    /// `kAudioDevicePropertyDeviceUID`: stable across launches and reconnections.
    var uid: String
    /// The name the device had when it was chosen, shown while it is disconnected.
    var name: String

    var id: String { uid }
}
