import CoreGraphics
import Foundation
import IOKit.ps

/// What power, battery and thermal state allow: whether library preparation may run, and how far
/// playback should lean towards efficiency (N10). A pure function of `PowerState`, so the rules are
/// testable; `PowerPolicyMonitor` feeds it live state.
struct PowerState: Equatable, Sendable {
    var onBattery: Bool = false
    /// 0…1, nil when unknown (no battery).
    var batteryLevel: Double?
    var lowPowerMode: Bool = false
    var thermal: ProcessInfo.ThermalState = .nominal
    /// Seconds since the last user input.
    var userIdleSeconds: TimeInterval = 0
}

struct PowerPolicy: Equatable, Sendable {
    /// Library preparation on battery waits for this much user idle…
    static let libraryIdleSeconds: TimeInterval = 120
    /// …and more than this charge.
    static let libraryMinimumBattery = 0.5
    /// The frame rate cap at `.critical`.
    static let criticalFrameRateCap = 30

    let state: PowerState

    init(_ state: PowerState) { self.state = state }

    /// Library preparation: always on AC; on battery only after 2 minutes of idle with more than
    /// 50 % charge. Paused at `.critical` either way.
    var allowsLibraryPreparation: Bool {
        if state.thermal == .critical { return false }
        guard state.onBattery else { return true }
        guard let level = state.batteryLevel else { return false }
        return state.userIdleSeconds >= Self.libraryIdleSeconds && level > Self.libraryMinimumBattery
    }

    /// Steps the Quality↔Efficiency slider's effective position moves towards efficiency:
    /// one for Low Power Mode or `.serious`, two at `.critical`.
    var efficiencySteps: Int {
        var steps = 0
        if state.lowPowerMode { steps = 1 }
        switch state.thermal {
        case .serious: steps = max(steps, 1)
        case .critical: steps = 2
        default: break
        }
        return steps
    }

    /// Applies `efficiencySteps` to a slider stop (1 = quality … `stops` = efficiency).
    func effectiveStop(_ stop: Int, stops: Int = 5) -> Int {
        min(stops, max(1, stop + efficiencySteps))
    }

    /// The frame rate cap, nil for none.
    var frameRateCap: Int? {
        state.thermal == .critical ? Self.criticalFrameRateCap : nil
    }
}

/// A live `PowerPolicy`: `PowerPolicyMonitor`, or a stand-in in tests.
protocol PowerPolicySource: AnyObject, Sendable {
    var policy: PowerPolicy { get }
    @discardableResult func observe(_ body: @escaping @Sendable (PowerPolicy) -> Void) -> UUID
    func removeObserver(_ id: UUID)
}

/// Watches power source, Low Power Mode and thermal state and reports a new `PowerPolicy` when its
/// decisions change. Event driven; user idle is polled only while library preparation is waiting
/// on it (on battery), once every 15 s, on a utility queue.
final class PowerPolicyMonitor: PowerPolicySource, @unchecked Sendable {
    static let shared = PowerPolicyMonitor()

    private let queue = DispatchQueue(label: "owe.power-policy", qos: .utility)
    private let lock = NSLock()
    private var _policy: PowerPolicy
    private var observers: [UUID: @Sendable (PowerPolicy) -> Void] = [:]
    private var tokens: [NSObjectProtocol] = []
    private var runLoopSource: CFRunLoopSource?
    private var idleTimer: DispatchSourceTimer?
    private var started = false

    init() { _policy = PowerPolicy(Self.readState()) }

    var policy: PowerPolicy { lock.lock(); defer { lock.unlock() }; return _policy }

    /// Adds an observer called on the monitor's queue whenever the policy's decisions change.
    /// Starts monitoring on first use.
    @discardableResult
    func observe(_ body: @escaping @Sendable (PowerPolicy) -> Void) -> UUID {
        let id = UUID()
        lock.lock(); observers[id] = body; lock.unlock()
        startIfNeeded()
        return id
    }

    func removeObserver(_ id: UUID) { lock.lock(); observers[id] = nil; lock.unlock() }

    /// Gates the pool's library jobs on this policy.
    func drive(_ pool: PreparationPool) {
        pool.setLibraryGate { [weak self] in self?.policy.allowsLibraryPreparation ?? true }
        observe { [weak pool] _ in pool?.reevaluate() }
    }

    private func startIfNeeded() {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        lock.unlock()
        let center = NotificationCenter.default
        for name in [ProcessInfo.thermalStateDidChangeNotification,
                     Notification.Name.NSProcessInfoPowerStateDidChange] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.refresh()
            })
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<PowerPolicyMonitor>.fromOpaque(context).takeUnretainedValue().refresh()
        }, context)?.takeRetainedValue() {
            runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }
        refresh()
    }

    /// Re-reads the state off the calling thread and notifies when a decision changed.
    func refresh() {
        queue.async { [self] in
            let next = PowerPolicy(Self.readState())
            lock.lock()
            let previous = _policy
            _policy = next
            let changed = previous.allowsLibraryPreparation != next.allowsLibraryPreparation
                || previous.efficiencySteps != next.efficiencySteps
                || previous.frameRateCap != next.frameRateCap
                // The battery quality (`BatteryQuality`) follows these two.
                || previous.state.onBattery != next.state.onBattery
                || previous.state.lowPowerMode != next.state.lowPowerMode
            let callbacks = Array(observers.values)
            lock.unlock()
            updateIdlePolling(for: next)
            if changed { callbacks.forEach { $0(next) } }
        }
    }

    /// Idle only matters on battery while library preparation is held back.
    private func updateIdlePolling(for policy: PowerPolicy) {
        let needed = policy.state.onBattery && !policy.allowsLibraryPreparation && policy.state.thermal != .critical
        if needed, idleTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 15, repeating: 15, leeway: .seconds(5))
            timer.setEventHandler { [weak self] in self?.refresh() }
            timer.resume()
            idleTimer = timer
        } else if !needed, let timer = idleTimer {
            timer.cancel()
            idleTimer = nil
        }
    }

    static func readState() -> PowerState {
        var state = PowerState()
        let info = ProcessInfo.processInfo
        state.lowPowerMode = info.isLowPowerModeEnabled
        state.thermal = info.thermalState
        state.userIdleSeconds = CGEventSource.secondsSinceLastEventType(.hidSystemState,
                                                                       eventType: CGEventType(rawValue: ~0)!)
        if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() {
            if let type = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String? {
                state.onBattery = type == kIOPSBatteryPowerValue
            }
            let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] ?? []
            for source in list {
                guard let description = IOPSGetPowerSourceDescription(blob, source)?
                        .takeUnretainedValue() as? [String: Any],
                      description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                      let current = description[kIOPSCurrentCapacityKey] as? Int,
                      let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
                state.batteryLevel = Double(current) / Double(maximum)
            }
        }
        return state
    }
}
