import Foundation
import Metal

extension Notification.Name {
    /// A wallpaper's command buffer failed for lack of video memory (posted from its completion
    /// handler, on any thread).
    static let videoMemoryCommandBufferFailed = Notification.Name("OpenWallpaperEngine.videoMemoryCommandBufferFailed")
}

/// Advanced › "Pause when VRAM is exhausted": samples the GPU once a second while the setting is
/// on, listens for out-of-memory command buffers and (with unified memory) critical memory
/// pressure, and reports when `VideoMemoryGauge` says video memory ran out or recovered. The app
/// hands that to `DisplayPlaybackMonitor`, which pauses every display the way the other playback
/// rules do. Off, it reads nothing and reports nothing.
@MainActor
final class VideoMemoryWatch {
    static let sampleInterval: TimeInterval = 1

    /// What it reads from the GPU; injectable for tests.
    struct Device {
        var allocated: () -> UInt64
        var budget: () -> UInt64
        var hasUnifiedMemory: Bool

        static func system() -> Device? {
            guard let device = MTLCreateSystemDefaultDevice() else { return nil }
            return Device(allocated: { UInt64(device.currentAllocatedSize) },
                          budget: { device.recommendedMaxWorkingSetSize },
                          hasUnifiedMemory: device.hasUnifiedMemory)
        }
    }

    private let device: Device?
    private let now: () -> TimeInterval
    private let onChange: (Bool) -> Void
    /// Whether it starts the timer, pressure source and observer (off in tests, which tick by hand).
    private let schedules: Bool
    private(set) var gauge = VideoMemoryGauge()
    private(set) var isEnabled = false
    private var criticalPressure = false
    private var outOfMemorySinceSample = false
    private var timer: DispatchSourceTimer?
    private var pressureSource: DispatchSourceMemoryPressure?
    private var observer: NSObjectProtocol?

    init(device: Device?, schedules: Bool = true,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         onChange: @escaping (Bool) -> Void) {
        self.device = device
        self.schedules = schedules
        self.now = now
        self.onChange = onChange
    }

    var exhausted: Bool { gauge.exhausted }

    /// Turns the watch on or off with the setting. Off clears a pause it caused.
    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
            if schedules { startSources() }
        } else {
            stopSources()
            criticalPressure = false
            outOfMemorySinceSample = false
            if gauge.exhausted {
                gauge = VideoMemoryGauge()
                OWELog.info(.app, "Video memory watch off; resuming wallpapers")
                onChange(false)
            }
        }
    }

    /// One reading of the device; the timer calls it once a second.
    func sample() {
        guard isEnabled, let device else { return }
        let sample = VideoMemoryGauge.Sample(allocated: device.allocated(), budget: device.budget(),
                                             criticalPressure: device.hasUnifiedMemory && criticalPressure,
                                             outOfMemoryError: outOfMemorySinceSample)
        outOfMemorySinceSample = false
        guard gauge.update(sample, now: now()) else { return }
        if gauge.exhausted {
            OWELog.info(.app, "Video memory exhausted (\(VideoMemoryGauge.reason(sample))); pausing wallpapers")
        } else {
            OWELog.info(.app, "Video memory recovered (\(VideoMemoryGauge.reason(sample))); resuming wallpapers")
        }
        onChange(gauge.exhausted)
    }

    /// The system's memory pressure changed.
    func setCriticalPressure(_ critical: Bool) {
        criticalPressure = critical
        if critical { sample() }
    }

    /// A command buffer failed for lack of memory.
    func noteOutOfMemory() {
        guard isEnabled else { return }
        outOfMemorySinceSample = true
        sample()
    }

    /// The user resumed by hand: lift the pause, and don't pause again for the hold time.
    func userResumed() {
        guard gauge.userResumed(now: now()) else { return }
        OWELog.info(.app, "Wallpapers resumed by the user while video memory was exhausted")
        onChange(false)
    }

    /// Whether `error` (a command buffer's) means video memory ran out.
    nonisolated static func isOutOfMemory(_ error: Error?) -> Bool {
        guard let error = error as? MTLCommandBufferError else { return false }
        return error.code == .outOfMemory || error.code == .memoryless
    }

    // MARK: - Sources

    private func startSources() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        let interval = DispatchTimeInterval.milliseconds(Int(Self.sampleInterval * 1000))
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.sample() } }
        timer.resume()
        self.timer = timer

        if device?.hasUnifiedMemory == true {
            let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
            source.setEventHandler { [weak self, weak source] in
                guard let event = source?.data else { return }
                MainActor.assumeIsolated { self?.setCriticalPressure(event.contains(.critical)) }
            }
            source.resume()
            pressureSource = source
        }

        observer = NotificationCenter.default.addObserver(forName: .videoMemoryCommandBufferFailed, object: nil,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.noteOutOfMemory() }
        }
    }

    private func stopSources() {
        timer?.cancel()
        timer = nil
        pressureSource?.cancel()
        pressureSource = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
}
