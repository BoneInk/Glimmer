import Foundation

/// Restarts the Dock, which applies a new icon style or tint only when it starts (there is no
/// public notification for it, docs/theming.md).
public protocol DockRestarting: AnyObject {
    func restartDock() throws
}

/// `killall Dock`: launchd starts the Dock again at once (it is kept alive), which re-reads the
/// icon appearance. Windows and apps are untouched. There is no public relaunch API.
public final class SystemDockRestarter: DockRestarting {
    public init() {}

    public func restartDock() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["Dock"]
        try process.run()
    }
}

/// Runs an action once, `delay` after the last `schedule`. A seam, so tests settle by hand.
public protocol SettleTimer: AnyObject {
    /// Replaces any pending action.
    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void)
    func cancel()
}

/// The main queue's timer.
public final class MainQueueSettleTimer: SettleTimer {
    private var pending: DispatchWorkItem?

    public init() {}

    public func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) {
        pending?.cancel()
        let work = DispatchWorkItem(block: action)
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    public func cancel() {
        pending?.cancel()
        pending = nil
    }
}

/// Restarts the Dock once the icon and folder colour settles: `delay` after the last change (a
/// colour picker being dragged, scheme colour edits, a wallpaper change), at most once per settle,
/// and only when the stored icon values differ from those the Dock last started with.
public final class DockRestartScheduler {
    /// How long the colour must stay put before the Dock restarts.
    public static let settleDelay: TimeInterval = 1.5
    /// The keys the Dock reads when it starts.
    public static let keys: [SystemPreferenceKey] = SystemPreferenceKey.allCases.filter { $0.change == .iconAppearance }

    private let restarter: DockRestarting
    private let timer: SettleTimer
    private let delay: TimeInterval
    private let currentValues: () -> [SystemPreferenceKey: PreferenceValue]
    private let logError: (String) -> Void
    /// The icon values the Dock started with: those at launch, then those of each restart.
    private var dockValues: [SystemPreferenceKey: PreferenceValue]

    /// `writer` reads the stored icon values; the Dock is taken to have started with the current ones.
    public init(restarter: DockRestarting, writer: SystemAppearanceWriter, timer: SettleTimer = MainQueueSettleTimer(),
                delay: TimeInterval = settleDelay, logError: @escaping (String) -> Void = { _ in }) {
        self.restarter = restarter
        self.timer = timer
        self.delay = delay
        self.logError = logError
        currentValues = { [weak writer] in
            var values: [SystemPreferenceKey: PreferenceValue] = [:]
            for key in Self.keys { values[key] = writer?.value(for: key) }
            return values
        }
        dockValues = currentValues()
    }

    /// Whether the Dock shows other icon values than those stored.
    public var isOutOfDate: Bool { currentValues() != dockValues }

    /// The icon values changed (or may have): restarts the Dock `delay` after the last call.
    public func iconPreferencesChanged() {
        timer.schedule(after: delay) { [weak self] in self?.settle() }
    }

    /// Restarts the Dock now when it is out of date (the button, or on quit); drops a pending settle.
    /// Returns whether it restarted.
    @discardableResult
    public func settle() -> Bool {
        timer.cancel()
        let values = currentValues()
        guard values != dockValues else { return false }
        do {
            try restarter.restartDock()
            dockValues = values
            return true
        } catch {
            logError("Theming: restarting the Dock failed: \(error)")
            return false
        }
    }

    /// Drops a pending restart (automatic restarts turned off).
    public func cancel() { timer.cancel() }
}
