import CoreAudio
import Foundation

/// Where the default output device comes from: Core Audio in the app, a fake in tests.
protocol OutputDeviceSource: AnyObject {
    /// The current default output device.
    func currentDeviceID() -> AudioObjectID
    /// Calls `onChange` (on any thread) whenever the default output device may have changed.
    func startObserving(_ onChange: @escaping () -> Void)
    func stopObserving()
}

/// WE's "Reload when changing output device": when the default output device changes, WE reloads
/// the wallpaper so its sounds and its audio visualisation follow the new device.
///
/// A device switch fires a burst of notifications, so a change is acted on once, `debounce`
/// seconds after the last one, and only when the device ID really differs from the last one
/// seen. System audio capture always restarts on a change, so audio-reactive visuals never go
/// silent; the running wallpapers reload (re-routing their sounds) only while `reloadEnabled`.
final class OutputDeviceChangeMonitor {
    typealias Schedule = (_ delay: TimeInterval, _ work: @escaping () -> Void) -> Void

    private let source: OutputDeviceSource
    private let debounce: TimeInterval
    private let schedule: Schedule
    private let reloadEnabled: () -> Bool
    private let restartCapture: () -> Void
    private let reloadWallpapers: () -> Void

    /// Only touched on the scheduler's queue (the main queue in the app).
    private var lastDeviceID: AudioObjectID
    private var generation = 0

    init(source: OutputDeviceSource,
         debounce: TimeInterval = 0.5,
         schedule: @escaping Schedule,
         reloadEnabled: @escaping () -> Bool,
         restartCapture: @escaping () -> Void,
         reloadWallpapers: @escaping () -> Void) {
        self.source = source
        self.debounce = debounce
        self.schedule = schedule
        self.reloadEnabled = reloadEnabled
        self.restartCapture = restartCapture
        self.reloadWallpapers = reloadWallpapers
        lastDeviceID = source.currentDeviceID()
    }

    func start() {
        source.startObserving { [weak self] in
            // Hop onto the scheduler's queue before touching state.
            self?.schedule(0) { self?.deviceMayHaveChanged() }
        }
    }

    func stop() {
        source.stopObserving()
        generation &+= 1
    }

    /// Restarts the debounce window; the latest notification in a burst wins.
    func deviceMayHaveChanged() {
        generation &+= 1
        let current = generation
        schedule(debounce) { [weak self] in
            guard let self, self.generation == current else { return }
            self.settle()
        }
    }

    private func settle() {
        let device = source.currentDeviceID()
        guard device != lastDeviceID else { return }
        lastDeviceID = device
        restartCapture()
        if reloadEnabled() {
            OWELog.info(.audio, "Default output device changed; reloading wallpapers.")
            reloadWallpapers()
        } else {
            OWELog.info(.audio, "Default output device changed; reload is off, only restarting capture.")
        }
    }
}

/// The system's default output device, watched with a Core Audio property listener.
final class CoreAudioOutputDeviceSource: OutputDeviceSource {
    private var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    private var listener: AudioObjectPropertyListenerBlock?
    private let queue = DispatchQueue(label: "com.owe.audio.output-device")

    deinit { stopObserving() }

    func currentDeviceID() -> AudioObjectID {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr ? device : AudioObjectID(kAudioObjectUnknown)
    }

    func startObserving(_ onChange: @escaping () -> Void) {
        stopObserving()
        let block: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
        if status == noErr {
            listener = block
        } else {
            OWELog.debug(.audio, "Watching the default output device failed: \(status)")
        }
    }

    func stopObserving() {
        guard let block = listener else { return }
        listener = nil
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
    }
}
