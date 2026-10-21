import Foundation

/// The conditions that hold for every display at once.
struct SystemPlaybackConditions: Equatable {
    /// Another application plays sound ("Other application playing audio").
    var otherApplicationPlayingAudio = false
    /// The displays sleep ("Display asleep"); macOS sleeps them together.
    var displaysAsleep = false
    /// The Mac runs on its battery ("Laptop on battery").
    var onBattery = false
    /// The bundle identifiers of the running applications, for the application rules.
    var runningApplications: Set<String> = []
    /// The bundle identifiers of the processes playing sound (Application Rules' "is playing
    /// audio"), helpers included; read only while such a rule is on.
    var audioProcesses: Set<String> = []
    /// Video memory ran out with "Pause when VRAM is exhausted" on (`VideoMemoryWatch`).
    var videoMemoryExhausted = false
    /// The screen is locked, or another user's session is in front (fast user switching). Nobody
    /// sees the desktop then, so every display pauses, as WE pauses on Windows' session
    /// notifications (`WTSRegisterSessionNotification`).
    var sessionInactive = false
}

/// Settings › Performance › Playback, evaluated for each display, as WE does with several
/// monitors: the rules about other applications' windows (focused, maximized, fullscreen) act on
/// the display the window is on, and the others on every display.
///
/// WE's actions (`ui/dist/scripts/scripts.js`, the settings controller's `k(multimonitor, …)`):
/// on a multi-monitor system the window rules offer "Pause per monitor" (the stored value `pause`)
/// and "Pause all" (`pauseall`); with one monitor only "Pause". So `pause` pauses the display
/// whose window triggered it, and `pauseAll` pauses every display. "Stop" acts on the display too.
/// When several rules apply, the most restrictive action wins.
///
/// Application Rules (`ApplicationRule`) go through the same evaluation: "is running" and "is
/// playing audio" act on every display, "is focused", "is maximized" and "is fullscreen" on the
/// display of the application's window, and each playback action combines with the other rules'
/// as theirs do (the most restrictive wins). WE's settings don't say how several matching rules
/// combine, so this keeps that precedence. Load actions can't be ordered by restrictiveness: the
/// first matching rule in the list loads (`load(conditions:system:)`), and its playback still
/// combines with the other rules'.
struct PlaybackRules: Equatable {
    var focused: GSPlayback
    var maximized: GSPlayback
    var fullscreen: GSPlayback
    var playingAudio: GSPlayback
    var displayAsleep: GSPlayback
    var onBattery: GSPlayback
    /// The application rules that can act (enabled, with an action).
    var applicationRules: [ApplicationRule]

    init(focused: GSPlayback = .keepRunning, maximized: GSPlayback = .keepRunning,
         fullscreen: GSPlayback = .keepRunning, playingAudio: GSPlayback = .keepRunning,
         displayAsleep: GSPlayback = .keepRunning, onBattery: GSPlayback = .keepRunning,
         applicationRules: [ApplicationRule] = []) {
        self.applicationRules = applicationRules.filter(\.isActive)
        self.focused = focused
        self.maximized = maximized
        self.fullscreen = fullscreen
        self.playingAudio = playingAudio
        self.displayAsleep = displayAsleep
        self.onBattery = onBattery
    }

    init(_ settings: GlobalSettings) {
        self.init(focused: settings.otherApplicationFocused, maximized: settings.otherApplicationMaximized,
                  fullscreen: settings.otherApplicationFullscreen, playingAudio: settings.otherApplicationPlayingAudio,
                  displayAsleep: settings.displayAsleep, onBattery: settings.laptopOnBattery,
                  applicationRules: settings.applicationRules)
    }

    /// Some rule looks at other applications' windows, so they have to be watched.
    var watchesWindows: Bool { [focused, maximized, fullscreen].contains { $0 != .keepRunning } }

    /// Some application rule needs the window list. "Is focused" and "is fullscreen" follow the
    /// workspace's events (launch, quit, activation, Space changes, which is how a window enters
    /// full screen); "is maximized" also needs a slow poll (`applicationRulesPollWindows`).
    var applicationRulesWatchWindows: Bool { applicationRules.contains { $0.condition.watchesWindows } }

    /// The applications of "is maximized" rules: zooming or resizing a window posts no event, so
    /// while one of them runs the window list is looked at on a slow timer.
    var maximizedRuleApplications: Set<String> {
        Set(applicationRules.filter { $0.condition == .maximized }.map(\.bundleIdentifier))
    }

    /// Some application rule waits for an application's sound (Core Audio's process objects,
    /// followed through their property listeners rather than a poll).
    var applicationRulesWatchAudio: Bool { applicationRules.contains { $0.condition == .playingAudio } }

    /// Some application rule is on, so the running applications have to be known.
    var watchesApplications: Bool { !applicationRules.isEmpty }

    /// The "playing audio" rule is on, so other applications' sound has to be watched.
    var watchesAudio: Bool { playingAudio != .keepRunning }

    /// The battery rule is on.
    var watchesPower: Bool { onBattery != .keepRunning }

    /// What each of `displays` does. A display missing from `conditions` has no window condition.
    func playback(displays: [String], conditions: [String: DisplayConditions],
                  system: SystemPlaybackConditions) -> [String: DisplayPlayback] {
        var everywhere = DisplayPlayback.run
        if system.otherApplicationPlayingAudio { everywhere = max(everywhere, DisplayPlayback(playingAudio)) }
        if system.displaysAsleep { everywhere = max(everywhere, DisplayPlayback(displayAsleep)) }
        if system.onBattery { everywhere = max(everywhere, DisplayPlayback(onBattery)) }
        for rule in applicationRules where !rule.condition.actsPerDisplay && Self.matches(rule, system: system) {
            if let effect = rule.action.playback { everywhere = max(everywhere, effect.state) }
        }
        if system.videoMemoryExhausted { everywhere = max(everywhere, .pause) }
        if system.sessionInactive { everywhere = max(everywhere, .pause) }

        var local: [String: DisplayPlayback] = [:]
        for display in displays {
            var playback = DisplayPlayback.run
            let displayConditions = conditions[display] ?? DisplayConditions()
            for action in triggeredActions(displayConditions) {
                if action == .pauseAll {
                    everywhere = max(everywhere, .pause)
                } else {
                    playback = max(playback, DisplayPlayback(action))
                }
            }
            for rule in applicationRules where rule.condition.actsPerDisplay && Self.matches(rule, on: displayConditions) {
                guard let effect = rule.action.playback else { continue }
                if effect.everyDisplay {
                    everywhere = max(everywhere, effect.state)
                } else {
                    playback = max(playback, effect.state)
                }
            }
            local[display] = playback
        }
        return local.mapValues { max($0, everywhere) }
    }

    /// What the first matching application rule with a load action loads; nil when none matches.
    /// `conditions` has every display's window conditions.
    func load(conditions: [String: DisplayConditions], system: SystemPlaybackConditions) -> ApplicationRuleLoad? {
        for rule in applicationRules {
            guard let load = rule.load else { continue }
            let matches = rule.condition.actsPerDisplay
                ? conditions.values.contains { Self.matches(rule, on: $0) }
                : Self.matches(rule, system: system)
            if matches { return load }
        }
        return nil
    }

    /// The settings' window rules that apply to a display's conditions.
    private func triggeredActions(_ conditions: DisplayConditions) -> [GSPlayback] {
        var actions: [GSPlayback] = []
        if conditions.focused { actions.append(focused) }
        if conditions.maximized { actions.append(maximized) }
        if conditions.fullscreen { actions.append(fullscreen) }
        return actions
    }

    /// Whether a window rule's application meets its condition on a display.
    private static func matches(_ rule: ApplicationRule, on conditions: DisplayConditions) -> Bool {
        switch rule.condition {
        case .focused: return conditions.focusedApplication == rule.bundleIdentifier
        case .maximized: return conditions.maximizedApplications.contains(rule.bundleIdentifier)
        case .fullscreen: return conditions.fullscreenApplications.contains(rule.bundleIdentifier)
        case .running, .playingAudio: return false
        }
    }

    /// Whether a rule about every display has its application running or playing sound.
    private static func matches(_ rule: ApplicationRule, system: SystemPlaybackConditions) -> Bool {
        switch rule.condition {
        case .running: return system.runningApplications.contains(rule.bundleIdentifier)
        case .playingAudio: return system.audioProcesses.contains { rule.ownsAudioProcess($0) }
        case .focused, .maximized, .fullscreen: return false
        }
    }
}
