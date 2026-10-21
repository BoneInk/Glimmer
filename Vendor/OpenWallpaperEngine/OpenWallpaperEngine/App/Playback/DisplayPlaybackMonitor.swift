import AppKit
import Combine
import IOKit.ps

/// Evaluates Settings › Performance › Playback for each display (`PlaybackRules`) and hands the
/// result to the app (`WallpaperViewModel.displayPlayback`, the wallpaper windows).
///
/// Cheap by construction: it re-evaluates on the events that change the answer (an application
/// activated, hidden, launched or quit, a Space or the screens changed, the displays slept or
/// woke, the screen locked or unlocked, the user's session was switched away from or back to,
/// the power source changed), at most ten times a second. Windows moved or zoomed within an
/// application post no event, so while a rule about windows or other applications' audio is on
/// it also looks twice a second; with those rules off, or the displays asleep, it doesn't poll.
/// Application Rules follow launching, quitting and activating an application, and a window
/// entering full screen (a Space change); "is playing audio" follows Core Audio's listeners
/// (`ProcessAudioOutputWatch`). Only "is maximized" polls, once a second and only while one of
/// its applications runs, since zooming a window posts no event: a window-list read costs about
/// 0.1 ms of CPU.
///
/// While `watchesCoverage` is on (always, in the app) it also follows which displays windows cover
/// (`DesktopWindowLayout.coveredDisplays`) and polls for it, since moving a window posts no event.
///
/// Besides each display's playback, the answer names what the first matching rule with a load
/// action loads (`onLoad`, `ApplicationRuleLoader`).
///
/// The main thread only gathers what AppKit owns (the displays, the active application) and
/// applies a changed answer. Reading the window list, Core Audio and the power source, and
/// evaluating the rules, happen on `scanQueue`; the poll timer runs there too, so an unchanged
/// desktop never wakes the main thread.
@MainActor
final class DisplayPlaybackMonitor {
    /// Events closer together than this are evaluated once.
    static let throttle: TimeInterval = 0.1
    /// How often windows and audio are looked at while a rule needs them.
    static let pollInterval: TimeInterval = 0.5
    /// How often the windows are looked at while only an "is maximized" application rule needs
    /// them.
    static let maximizedRulePollInterval: TimeInterval = 1

    private let sources: DisplayPlaybackSources
    private let apply: ([String: DisplayPlayback]) -> Void
    private let onLoad: (ApplicationRuleLoad?) -> Void
    private let onCoverage: (Set<String>) -> Void
    private(set) var rules = PlaybackRules()
    private(set) var displaysAsleep = false
    /// The screen is locked, or this user's session isn't the one in front: every display pauses
    /// (`SystemPlaybackConditions.sessionInactive`).
    private(set) var session = DesktopSessionState()
    /// Video memory ran out (`VideoMemoryWatch`, only while its setting is on).
    private(set) var videoMemoryExhausted = false
    /// The last states handed to `apply`.
    private(set) var states: [String: DisplayPlayback]?
    /// The last load handed to `onLoad`.
    private(set) var load: ApplicationRuleLoad?
    /// The displays windows cover (`DesktopWindowLayout.coveredDisplays`), last handed to
    /// `onCoverage`.
    private(set) var coveredDisplays: Set<String> = []
    /// Whether to follow which displays windows cover, whatever the rules: a covered display's
    /// wallpaper stops drawing frames nobody sees (`SceneWallpaperInstance`).
    var watchesCoverage = false {
        didSet {
            guard watchesCoverage != oldValue else { return }
            updatePolling()
            evaluate()
        }
    }
    private var evaluationPending = false
    private var pollTimer: DispatchSourceTimer?
    private var pollTimerInterval: TimeInterval?
    /// An application named by an "is maximized" rule runs, so its windows are polled.
    private var maximizedRuleApplicationRuns = false
    /// Stops following Core Audio's processes; set while an "is playing audio" rule is on.
    private var stopObservingAudioProcesses: (() -> Void)?
    /// Where the expensive reads run; nil reads everything on the calling thread (tests).
    private let scanQueue: DispatchQueue?
    /// What the scan needs from the main thread, and the last answer, shared with `scanQueue`.
    private let shared = Shared()
    /// Answers from scans started before the latest are dropped.
    private var generation: UInt64 = 0
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var settingsCancellable: AnyCancellable?
    private var powerSource: CFRunLoopSource?

    init(sources: DisplayPlaybackSources,
         scanQueue: DispatchQueue? = DispatchQueue(label: "OpenWallpaperEngine.DisplayPlaybackMonitor", qos: .utility),
         onLoad: @escaping (ApplicationRuleLoad?) -> Void = { _ in },
         onCoverage: @escaping (Set<String>) -> Void = { _ in },
         apply: @escaping ([String: DisplayPlayback]) -> Void) {
        self.sources = sources
        self.scanQueue = scanQueue
        self.onLoad = onLoad
        self.onCoverage = onCoverage
        self.apply = apply
    }

    /// Whether it looks at the desktop on a timer.
    var isPolling: Bool { pollTimer != nil }

    /// Starts following `settings` and the system's events, and evaluates once.
    func start<Settings: Publisher>(settings: Settings) where Settings.Output == GlobalSettings, Settings.Failure == Never {
        session = sources.session()
        observeWorkspace()
        observePowerSource()
        settingsCancellable = settings
            .map { PlaybackRules($0) }
            .removeDuplicates()
            .sink { [weak self] rules in MainActor.assumeIsolated { self?.setRules(rules) } }
        evaluate()
    }

    func stop() {
        for observer in observers { observer.center.removeObserver(observer.token) }
        observers.removeAll()
        settingsCancellable = nil
        if let powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .defaultMode) }
        powerSource = nil
        pollTimer?.cancel()
        pollTimer = nil
        pollTimerInterval = nil
        stopObservingAudioProcesses?()
        stopObservingAudioProcesses = nil
    }

    func setRules(_ rules: PlaybackRules) {
        self.rules = rules
        updatePolling()
        updateAudioProcessObservation()
        evaluate()
    }

    func setDisplaysAsleep(_ asleep: Bool) {
        displaysAsleep = asleep
        updatePolling()
        evaluate()
    }

    /// The screen locked (true) or unlocked.
    func setScreenLocked(_ locked: Bool) {
        setSession(DesktopSessionState(screenLocked: locked, active: session.active))
    }

    /// This user's session became the one in front (true) or was switched away from. Coming back
    /// also reads the lock again, which may have changed while another session was in front.
    func setSessionActive(_ active: Bool) {
        let locked = active ? sources.session().screenLocked : session.screenLocked
        setSession(DesktopSessionState(screenLocked: locked, active: active))
    }

    private func setSession(_ next: DesktopSessionState) {
        guard next != session else { return }
        session = next
        OWELog.info(.app, "Session \(next.active ? "active" : "switched away"), screen \(next.screenLocked ? "locked" : "unlocked")")
        updatePolling()
        evaluate()
    }

    /// Nobody sees this session's desktop.
    var sessionInactive: Bool { session.screenLocked || !session.active }

    func setVideoMemoryExhausted(_ exhausted: Bool) {
        guard exhausted != videoMemoryExhausted else { return }
        videoMemoryExhausted = exhausted
        evaluate()
    }

    /// Evaluates soon, once for a burst of events.
    func setNeedsEvaluation() {
        guard !evaluationPending else { return }
        evaluationPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.throttle) { [weak self] in
            MainActor.assumeIsolated {
                self?.evaluationPending = false
                self?.evaluate()
            }
        }
    }

    /// Evaluates the rules now (with a scan queue, the answer comes back on the main thread
    /// shortly); hands the states on when they changed.
    func evaluate() {
        let inputs = Inputs(rules: rules, displays: sources.displays(), frontmostPID: sources.frontmostPID(),
                            ignoresWebKitAudio: rules.watchesAudio && sources.showsWebWallpaper(),
                            displaysAsleep: displaysAsleep,
                            applications: rules.watchesApplications ? sources.applications() : [:],
                            videoMemoryExhausted: videoMemoryExhausted,
                            sessionInactive: sessionInactive,
                            watchesCoverage: watchesCoverage)
        shared.set(inputs: inputs)
        let maximizedRuns = !rules.maximizedRuleApplications.isDisjoint(with: inputs.applications.values)
        if maximizedRuns != maximizedRuleApplicationRuns {
            maximizedRuleApplicationRuns = maximizedRuns
            updatePolling()
        }
        generation &+= 1
        let generation = generation
        guard let scanQueue, inputs.needsScan else {
            finish(Self.playback(inputs, sources: sources), generation: generation)
            return
        }
        let sources = sources
        scanQueue.async { [weak self] in
            let next = Self.playback(inputs, sources: sources)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finish(next, generation: generation) }
            }
        }
    }

    private func finish(_ next: Outcome, generation: UInt64) {
        guard generation == self.generation, next != shared.outcome else { return }
        shared.set(outcome: next)
        if next.load != load {
            load = next.load
            onLoad(next.load)
        }
        if next.covered != coveredDisplays {
            coveredDisplays = next.covered
            OWELog.debug(.app, "Covered displays: \(next.covered.sorted().joined(separator: ", "))")
            onCoverage(next.covered)
        }
        guard next.states != states else { return }
        states = next.states
        let summary: [String] = next.states.keys.sorted().map { (screen: String) -> String in "\(screen)=\(next.states[screen] ?? .run)" }
        OWELog.debug(.app, "Playback per display: \(summary.joined(separator: ", "))")
        apply(next.states)
    }

    /// What the rules ask for: each display's playback, and what a load action loads.
    struct Outcome: Equatable {
        var states: [String: DisplayPlayback]
        var load: ApplicationRuleLoad?
        var covered: Set<String> = []
    }

    /// The rules' answer for `inputs`, reading the windows, audio and power as they need.
    /// Runs on the scan queue.
    nonisolated private static func playback(_ inputs: Inputs, sources: DisplayPlaybackSources) -> Outcome {
        let rules = inputs.rules
        let windowRules = rules.watchesWindows || rules.applicationRulesWatchWindows
        let windows = windowRules || inputs.watchesCoverage ? sources.windows() : []
        let conditions = windowRules
            ? DesktopWindowLayout.conditions(windows: windows, displays: inputs.displays,
                                             frontmostPID: inputs.frontmostPID, ignoredPIDs: [sources.ownPID],
                                             bundleIdentifiers: inputs.applications)
            : [:]
        let system = SystemPlaybackConditions(
            otherApplicationPlayingAudio: rules.watchesAudio && sources.otherApplicationPlayingAudio(inputs.ignoresWebKitAudio),
            displaysAsleep: inputs.displaysAsleep,
            onBattery: rules.watchesPower && sources.onBattery(),
            runningApplications: Set(inputs.applications.values),
            audioProcesses: rules.applicationRulesWatchAudio ? sources.audioProcesses() : [],
            videoMemoryExhausted: inputs.videoMemoryExhausted,
            sessionInactive: inputs.sessionInactive)
        return Outcome(states: rules.playback(displays: inputs.displays.map(\.id), conditions: conditions, system: system),
                       load: rules.load(conditions: conditions, system: system),
                       covered: inputs.watchesCoverage
                        ? DesktopWindowLayout.coveredDisplays(windows: windows, displays: inputs.displays) : [])
    }

    /// One poll on the scan queue: hops to the main thread only when the answer changed.
    nonisolated private static func poll(_ shared: Shared, sources: DisplayPlaybackSources,
                                         monitor: DisplayPlaybackMonitor?) {
        guard let inputs = shared.inputs else { return }
        let next = playback(inputs, sources: sources)
        guard next != shared.outcome else { return }
        DispatchQueue.main.async { [weak monitor] in
            // The main thread may have moved on (new rules, displays); evaluate afresh.
            MainActor.assumeIsolated { monitor?.evaluate() }
        }
    }

    /// What an evaluation reads on the main thread.
    struct Inputs {
        var rules: PlaybackRules
        var displays: [DesktopDisplay]
        var frontmostPID: pid_t?
        var ignoresWebKitAudio: Bool
        var displaysAsleep: Bool
        /// The running applications' bundle identifiers by process, read while an application
        /// rule is on.
        var applications: [pid_t: String] = [:]
        var videoMemoryExhausted = false
        var sessionInactive = false
        var watchesCoverage = false

        /// Whether the answer needs a read that is too slow for the main thread.
        var needsScan: Bool {
            rules.watchesWindows || rules.applicationRulesWatchWindows || rules.watchesAudio || rules.watchesPower
                || watchesCoverage
        }
    }

    private final class Shared: @unchecked Sendable {
        private let lock = NSLock()
        private var _inputs: Inputs?
        private var _outcome: Outcome?
        var inputs: Inputs? { lock.lock(); defer { lock.unlock() }; return _inputs }
        var outcome: Outcome? { lock.lock(); defer { lock.unlock() }; return _outcome }
        func set(inputs: Inputs) { lock.lock(); _inputs = inputs; lock.unlock() }
        func set(outcome: Outcome) { lock.lock(); _outcome = outcome; lock.unlock() }
    }

    // MARK: - Events

    /// The poll's interval while a rule needs it; nil: no poll.
    var neededPollInterval: TimeInterval? {
        guard !displaysAsleep, !sessionInactive else { return nil }
        if rules.watchesWindows || rules.watchesAudio || watchesCoverage { return Self.pollInterval }
        if maximizedRuleApplicationRuns { return Self.maximizedRulePollInterval }
        return nil
    }

    private func updatePolling() {
        let needed = neededPollInterval
        guard needed != pollTimerInterval else { return }
        pollTimer?.cancel()
        pollTimer = nil
        pollTimerInterval = needed
        if let needed {
            let queue = scanQueue ?? DispatchQueue.main
            let timer = DispatchSource.makeTimerSource(queue: queue)
            let interval = DispatchTimeInterval.milliseconds(Int(needed * 1000))
            timer.schedule(deadline: .now() + interval, repeating: interval,
                           leeway: .milliseconds(Int(needed * 500)))
            let shared = shared
            let sources = sources
            timer.setEventHandler { [weak self] in Self.poll(shared, sources: sources, monitor: self) }
            timer.resume()
            pollTimer = timer
        }
    }

    /// Follows Core Audio's processes while an "is playing audio" rule is on.
    private func updateAudioProcessObservation() {
        let needed = rules.applicationRulesWatchAudio
        guard needed != (stopObservingAudioProcesses != nil) else { return }
        if needed {
            stopObservingAudioProcesses = sources.observeAudioProcesses { [weak self] in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.setNeedsEvaluation() } }
            }
        } else {
            stopObservingAudioProcesses?()
            stopObservingAudioProcesses = nil
        }
    }

    private func observeWorkspace() {
        let workspace = sources.workspaceNotifications
        let changes: [Notification.Name] = [
            NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification, NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
        ]
        for name in changes {
            observe(workspace, name) { $0.setNeedsEvaluation() }
        }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.setDisplaysAsleep(true) }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.setDisplaysAsleep(false) }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.setSessionActive(false) }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.setSessionActive(true) }
        let distributed = sources.distributedNotifications
        observe(distributed, DesktopSessionState.screenLockedNotification) { $0.setScreenLocked(true) }
        observe(distributed, DesktopSessionState.screenUnlockedNotification) { $0.setScreenLocked(false) }
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { $0.setNeedsEvaluation() }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ handler: @escaping @MainActor (DisplayPlaybackMonitor) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self)
            }
        }
        observers.append((center, token))
    }

    /// The battery rule follows the power source; IOKit calls back on the main run loop.
    private func observePowerSource() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        // Optional: nil only without IOKit's power-source service (then the rule sees mains power).
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<DisplayPlaybackMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.setNeedsEvaluation() }
        }, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        powerSource = source
    }
}
