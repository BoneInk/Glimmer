import Foundation

/// macOS's System Audio Recording permission (TCC service `kTCCServiceAudioCapture`), which a
/// Core Audio process tap needs. System Settings lists it under Screen & System Audio Recording ›
/// System Audio Recording Only.
///
/// macOS has no public API to read or request it, so this uses the `TCCAccessPreflight` and
/// `TCCAccessRequest` functions of the TCC framework, looked up at run time. When they are
/// missing the status is `.unknown`: the tap may still start, and macOS then shows its prompt the
/// first time the tap delivers audio.
enum SystemAudioRecordingPermission {
    enum Status: Equatable {
        case authorized
        case denied
        case notDetermined
        /// The TCC functions could not be loaded.
        case unknown
    }

    private static let service = "kTCCServiceAudioCapture" as CFString
    private static let frameworkPath = "/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC"

    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias Request = @convention(c) (CFString, CFDictionary?,
                                                @escaping @convention(block) (Bool) -> Void) -> Void

    /// Never prompts.
    static var status: Status {
        guard let preflight: Preflight = symbol("TCCAccessPreflight") else { return .unknown }
        return status(preflightResult: preflight(service, nil))
    }

    /// `TCCAccessPreflight`'s result: 0 granted, 1 denied, anything else not asked yet.
    static func status(preflightResult: Int) -> Status {
        switch preflightResult {
        case 0: return .authorized
        case 1: return .denied
        default: return .notDetermined
        }
    }

    /// Shows the system prompt if the user hasn't answered it yet; a denial is only changed in
    /// System Settings. `completion` runs on an arbitrary queue. Returns false, without calling
    /// `completion`, when the TCC functions could not be loaded.
    @discardableResult
    static func request(completion: @escaping (Bool) -> Void) -> Bool {
        guard let request: Request = symbol("TCCAccessRequest") else { return false }
        request(service, nil) { granted in completion(granted) }
        return true
    }

    /// `dlopen` is reference counted and returns the already loaded image, so looking the symbol
    /// up on every call keeps no global state and costs little.
    private static func symbol<T>(_ name: String) -> T? {
        guard let handle = dlopen(frameworkPath, RTLD_NOW) else {
            OWELog.debug(.audio, "Unable to load the TCC framework for the System Audio Recording permission.")
            return nil
        }
        guard let pointer = dlsym(handle, name) else {
            OWELog.debug(.audio, "TCC framework has no \(name); the System Audio Recording permission can't be read.")
            return nil
        }
        return unsafeBitCast(pointer, to: T.self)
    }
}
