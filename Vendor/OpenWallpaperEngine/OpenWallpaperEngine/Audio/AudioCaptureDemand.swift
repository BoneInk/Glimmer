import Foundation

/// Counts the consumers that need system audio (an audio-reactive scene or shader, a script's
/// audio buffers, a web page's audio listener, a video's music sync), so capture runs only while
/// one does. The first lease turns demand on at once; after the last one is released demand stays
/// on for `idleGrace` seconds, so switching wallpapers doesn't tear down and rebuild the stream.
///
/// Thread-safe: leases are taken and dropped on the main, render and script threads. `onChange`
/// is always called through `schedule`, on the main actor in the app.
final class AudioCaptureDemand: @unchecked Sendable {
    typealias Schedule = (TimeInterval, @escaping @Sendable () -> Void) -> Void

    let idleGrace: TimeInterval
    private let schedule: Schedule
    /// Owns `count`, `isActive`, `token` and `onChange`.
    private let lock = NSLock()
    private var count = 0
    private var isActive = false
    private var token = 0
    private var onChange: ((Bool) -> Void)?

    init(idleGrace: TimeInterval = 5, schedule: @escaping Schedule) {
        self.idleGrace = idleGrace
        self.schedule = schedule
    }

    /// Whether capture should run now.
    var isDemanded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isActive
    }

    var consumerCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    /// Called with the new state whenever demand turns on or off.
    func observe(_ handler: @escaping (Bool) -> Void) {
        lock.lock()
        onChange = handler
        lock.unlock()
    }

    /// A lease on capture; it is released when dropped or on `release()`.
    func acquire() -> AudioCaptureLease {
        lock.lock()
        count += 1
        token &+= 1
        let turnsOn = !isActive
        isActive = true
        lock.unlock()
        if turnsOn { notify(true) }
        return AudioCaptureLease(demand: self)
    }

    fileprivate func release() {
        lock.lock()
        count = max(count - 1, 0)
        guard count == 0 else {
            lock.unlock()
            return
        }
        token &+= 1
        let expected = token
        lock.unlock()
        schedule(idleGrace) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let turnsOff = self.token == expected && self.count == 0 && self.isActive
            if turnsOff { self.isActive = false }
            self.lock.unlock()
            if turnsOff { self.notify(false) }
        }
    }

    private func notify(_ active: Bool) {
        schedule(0) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let handler = self.onChange
            // A later change supersedes this one; report only the current state.
            let current = self.isActive
            self.lock.unlock()
            guard current == active else { return }
            handler?(active)
        }
    }
}

/// One consumer's hold on system audio capture (`AudioCaptureDemand`).
final class AudioCaptureLease: @unchecked Sendable {
    private weak var demand: AudioCaptureDemand?
    /// Owns `released`.
    private let lock = NSLock()
    private var released = false

    fileprivate init(demand: AudioCaptureDemand) {
        self.demand = demand
    }

    func release() {
        lock.lock()
        let first = !released
        released = true
        lock.unlock()
        if first { demand?.release() }
    }

    deinit { release() }
}
