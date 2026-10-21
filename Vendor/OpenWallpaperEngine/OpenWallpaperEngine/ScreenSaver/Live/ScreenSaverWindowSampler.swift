#if DEBUG
import AppKit
import CoreGraphics

/// Lab builds only (a Debug app with the screen saver extension embedded, `Scripts/build-saver-lab.sh`): while a
/// screen saver or lock session runs, whichever saver shows, logs each display's on-screen window
/// stack as it changes, to compare what the window server shows on a display without the
/// password prompt for the app's saver and for Apple's. A session starts on `didstart` or
/// `screenIsLocked` and ends on unlock, or on `didstop` while unlocked. Sampled every 0.5 s for
/// 15 s after `didstart`, `screenIsLocked` and `willstop` (a key during a locked screen saver),
/// else every 2 s; only rows that appeared or went away since the display's last sample are
/// logged ("Window sample"), and the first sample of a session in full. It reads only
/// `CGWindowListCopyWindowInfo`'s numbers, owners, levels, bounds, alpha and sharing state,
/// which need no permission (window names would need Screen Recording).
@MainActor
final class ScreenSaverWindowSampler {
    static let shared = ScreenSaverWindowSampler()

    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var locked = false
    private var saverRuns = false
    private var burstUntil: TimeInterval = 0
    private var previous: [String: Set<String>] = [:]
    private var session = 0

    /// Whether this is the lab's app: a Debug build with the screen saver extension embedded.
    static var isLab: Bool {
        guard let plugIns = Bundle.main.builtInPlugInsURL else { return false }
        return FileManager.default.fileExists(atPath: plugIns.appending(path: "OpenWallpaperEngineSaverExtension.appex")
            .path(percentEncoded: false))
    }

    func startIfLab() {
        guard Self.isLab, observers.isEmpty else { return }
        let center = DistributedNotificationCenter.default()
        let events: [(Notification.Name, String)] = [
            (ScreenSaverLiveNames.didStart, "didstart"), (ScreenSaverLiveNames.willStop, "willstop"),
            (ScreenSaverLiveNames.didStop, "didstop"), (ScreenSaverLiveNames.screenLocked, "locked"),
            (ScreenSaverLiveNames.screenUnlocked, "unlocked"),
        ]
        for (name, event) in events {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handle(event) }
            })
        }
        OWELog.info(.app, "Window sample: on (lab build)")
    }

    private func handle(_ event: String) {
        let wasActive = locked || saverRuns
        switch event {
        case "didstart": saverRuns = true
        case "willstop", "didstop": saverRuns = false
        case "locked": locked = true
        case "unlocked": locked = false; saverRuns = false
        default: break
        }
        let active = locked || saverRuns
        OWELog.info(.app, "Window sample: \(event) (locked \(locked), saver \(saverRuns))")
        if ["didstart", "locked", "willstop"].contains(event) {
            burstUntil = ProcessInfo.processInfo.systemUptime + 15
        }
        if active, !wasActive {
            session += 1
            previous = [:]
        }
        if active {
            sample()
            schedule()
        } else {
            timer?.invalidate()
            timer = nil
            OWELog.info(.app, "Window sample: session \(session) over")
        }
    }

    private func schedule() {
        timer?.invalidate()
        let interval = ProcessInfo.processInfo.systemUptime < burstUntil ? 0.5 : 2
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.locked || self.saverRuns else { return }
                self.sample()
                self.schedule()
            }
        }
    }

    private func sample() {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return }
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        let time = String(format: "%.1f", ProcessInfo.processInfo.systemUptime)
        for id in ids.prefix(Int(count)) {
            let bounds = CGDisplayBounds(id)
            let display = CGDisplayCreateUUIDFromDisplayID(id).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String } ?? "\(id)"
            var rows: [(Int, String)] = []
            for window in list {
                guard let dictionary = window[kCGWindowBounds as String] as? NSDictionary,
                      let rect = CGRect(dictionaryRepresentation: dictionary), rect.intersects(bounds) else { continue }
                let number = window[kCGWindowNumber as String] as? Int ?? 0
                let layer = window[kCGWindowLayer as String] as? Int ?? 0
                let owner = window[kCGWindowOwnerName as String] as? String ?? "?"
                let pid = window[kCGWindowOwnerPID as String] as? Int ?? 0
                let alpha = window[kCGWindowAlpha as String] as? Double ?? 1
                let sharing = window[kCGWindowSharingState as String] as? Int ?? -1
                let onscreen = window[kCGWindowIsOnscreen as String] as? Bool ?? false
                rows.append((layer, "win=\(number) layer=\(layer) owner=\(owner) pid=\(pid) bounds=\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width))x\(Int(rect.height)) alpha=\(String(format: "%.2f", alpha)) sharing=\(sharing) onscreen=\(onscreen)"))
            }
            // Front to back, as the list comes.
            let current = Set(rows.map(\.1))
            if let before = previous[display] {
                let added = rows.map(\.1).filter { !before.contains($0) }
                let removed = before.subtracting(current).sorted()
                for row in removed { OWELog.info(.app, "Window sample s\(session) t=\(time) display=\(display) - \(row)") }
                for row in added { OWELog.info(.app, "Window sample s\(session) t=\(time) display=\(display) + \(row)") }
            } else {
                for (index, row) in rows.enumerated() {
                    OWELog.info(.app, "Window sample s\(session) t=\(time) display=\(display) = #\(index) \(row)")
                }
            }
            previous[display] = current
        }
    }
}
#endif
