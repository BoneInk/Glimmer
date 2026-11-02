import AppKit
import Foundation
import IOKit.pwr_mgt
import SystemConfiguration

/// Keep the visible lock screen alive through loginwindow's short idle timeout,
/// while retaining the user's ordinary display sleep deadline. One lease serves
/// every display; repeated host updates must not extend it indefinitely.
@MainActor
final class GWLockScreenDisplaySleepGuard {
    private static let settingsKey = "State:/IOKit/PowerManagement/CurrentSettings" as CFString
    private var visible: Set<String> = []
    private var sleeping = false
    private var started: TimeInterval?
    private var assertion: IOPMAssertionID?
    private var expiry: Task<Void, Never>?
    private var store: SCDynamicStore?
    private var observers: [NSObjectProtocol] = []
    private let intervalOverride: (() -> TimeInterval?)?

    init(interval: (() -> TimeInterval?)? = nil) { intervalOverride = interval }

    #if GW_DIAGNOSTIC_ENTRY
    var diagnosticAssertionID: IOPMAssertionID? { assertion }
    var diagnosticSystemInterval: TimeInterval? { configuredInterval() }
    var assertionIsActive: Bool {
        guard let assertion,
              let properties = IOPMAssertionCopyProperties(assertion)?.takeRetainedValue() as? [String: Any]
        else { return false }
        return (properties[kIOPMAssertionLevelKey] as? NSNumber)?.intValue == kIOPMAssertionLevelOn
    }
    #endif

    func update(_ key: String, request: GWRequest) {
        if request.keepsLockScreenVisible { visible.insert(key) }
        else { visible.remove(key) }
        reconcile()
    }

    func remove(_ key: String) { visible.remove(key); reconcile() }
    func removeAll() { visible.removeAll(); reconcile() }
    func setSleeping(_ value: Bool) { sleeping = value; reconcile() }

    private func reconcile() {
        guard !visible.isEmpty else {
            sleeping = false
            started = nil
            releaseAssertion()
            stopObserving()
            return
        }
        if sleeping { started = nil; releaseAssertion(); return }
        guard started == nil else { return }
        started = ProcessInfo.processInfo.systemUptime
        if observers.isEmpty { startObserving() }
        refreshDeadline()
    }

    private func refreshDeadline() {
        guard let started else { return }
        releaseAssertion()
        guard let interval = configuredInterval(), interval.isFinite, interval >= 0 else {
            GWLog("lock-screen display sleep protection unavailable: no system idle timeout")
            return
        }
        let remaining = interval == 0 ? 0 : interval - (ProcessInfo.processInfo.systemUptime - started)
        guard interval == 0 || remaining > 0 else { return }
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithDescription(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            "Glimmer visible lock-screen wallpaper" as CFString,
            nil, nil, nil, remaining,
            kIOPMAssertionTimeoutActionTurnOff as CFString, &id)
        guard result == kIOReturnSuccess else {
            GWLog("lock-screen display sleep protection failed: \(result)")
            return
        }
        assertion = id
        GWLog("lock-screen display sleep protection active timeout=\(remaining) displays=\(visible.count)")
        if remaining > 0 {
            expiry = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
                self?.releaseAssertion()
                GWLog("lock-screen display sleep protection reached system idle timeout")
            }
        }
    }

    private func configuredInterval() -> TimeInterval? {
        if let intervalOverride { return intervalOverride() }
        guard let settings = SCDynamicStoreCopyValue(store, Self.settingsKey) as? [String: Any],
              let minutes = settings["Display Sleep Timer"] as? NSNumber else { return nil }
        return minutes.doubleValue * 60
    }

    private func releaseAssertion() {
        expiry?.cancel(); expiry = nil
        if let assertion {
            IOPMAssertionRelease(assertion)
            self.assertion = nil
            GWLog("lock-screen display sleep protection released")
        }
    }

    private func startObserving() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setSleeping(true) }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setSleeping(false) }
            })
        }
        var context = SCDynamicStoreContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        store = SCDynamicStoreCreate(nil, "Glimmer lock-screen display sleep" as CFString, { _, _, info in
            guard let info else { return }
            MainActor.assumeIsolated {
                Unmanaged<GWLockScreenDisplaySleepGuard>.fromOpaque(info).takeUnretainedValue().refreshDeadline()
            }
        }, &context)
        if let store {
            SCDynamicStoreSetNotificationKeys(store, [Self.settingsKey] as CFArray, nil)
            SCDynamicStoreSetDispatchQueue(store, .main)
        }
    }

    private func stopObserving() {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        if let store { SCDynamicStoreSetDispatchQueue(store, nil) }
        store = nil
    }
}
