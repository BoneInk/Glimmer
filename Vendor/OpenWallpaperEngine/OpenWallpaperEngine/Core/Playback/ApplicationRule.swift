import Foundation

/// Settings › Performance › Application Rules: WE's per-application playback rules. Each rule
/// names an application (by bundle identifier, as WE names it by its executable) and what the
/// wallpaper does while that application meets the rule's condition.
///
/// WE's conditions and actions are the settings dialog's (`ui/dist/scripts/scripts.js`,
/// `conditionLabels` and `actionLabels`): "is running", "is focused", "is maximized", "is
/// fullscreen" and "is playing audio"; mute, pause (per display or all), stop (per display or
/// all), and load a wallpaper, a playlist or a profile. WE's `loadprofile` loads a saved monitor
/// profile (the displays' wallpapers and layout, `DisplayProfileLoading`), not a performance
/// profile. A loaded wallpaper, playlist or profile stays while the rule matches; then what was
/// shown before comes back (`ApplicationRuleLoader`).
struct ApplicationRule: Codable, Equatable, Identifiable {
    /// When a rule applies.
    enum Condition: String, Codable, CaseIterable, Identifiable {
        var id: Self { self }
        /// The application is running: acts on every display.
        case running
        /// The application is the active one: acts on the display its front window is on.
        case focused
        /// One of the application's windows fills a display's visible area (zoomed, or sized to
        /// the area between the menu bar and the Dock) without covering the whole display: acts
        /// on that display.
        case maximized
        /// One of the application's windows covers a whole display (a full-screen Space or a
        /// borderless full-screen game): acts on that display.
        case fullscreen
        /// The application plays sound: acts on every display, as WE's does (no per-display
        /// pause). Needs macOS 14.2's Core Audio process objects; earlier systems never match.
        case playingAudio

        /// The condition looks at windows, so the window list has to be read.
        var watchesWindows: Bool { [.focused, .maximized, .fullscreen].contains(self) }

        /// Whether a pause or stop it triggers can be limited to one display. WE offers "per
        /// monitor" and "all" only for the window conditions.
        var actsPerDisplay: Bool { watchesWindows }

        /// The actions WE offers for the condition: not "Stop" while an application plays audio.
        var offersStop: Bool { self != .playingAudio }
    }

    /// What a rule does while it applies. The raw values of the playback actions are the stored
    /// `GSPlayback` values the rules were saved with before the load actions existed.
    enum Action: String, Codable, CaseIterable, Identifiable {
        var id: Self { self }
        /// Does nothing; a rule with it is inactive.
        case keepRunning
        case mute
        /// Pauses the display the condition is on (every display for "is running" and "is
        /// playing audio").
        case pause
        case pauseAll
        /// Stops (hides, freeing memory) the display the condition is on.
        case stop
        case stopAll
        /// Shows a wallpaper from the library on every display (`file`: its folder).
        case loadWallpaper
        /// Starts a playlist (`file`: its id).
        case loadPlaylist
        /// Loads a saved display profile (`file`: its name).
        case loadProfile

        /// What it does to the display it applies to, and whether it spreads to every display;
        /// nil for the actions that load something.
        var playback: (state: DisplayPlayback, everyDisplay: Bool)? {
            switch self {
            case .keepRunning: return (.run, false)
            case .mute: return (.mute, false)
            case .pause: return (.pause, false)
            case .pauseAll: return (.pause, true)
            case .stop: return (.stop, false)
            case .stopAll: return (.stop, true)
            case .loadWallpaper, .loadPlaylist, .loadProfile: return nil
            }
        }

        /// What it loads; nil for the playback actions.
        var loadKind: ApplicationRuleLoad.Kind? {
            switch self {
            case .loadWallpaper: return .wallpaper
            case .loadPlaylist: return .playlist
            case .loadProfile: return .profile
            default: return nil
            }
        }
    }

    var id = UUID()
    /// The application's bundle identifier, e.g. `com.apple.FinalCut`.
    var bundleIdentifier: String
    /// The application's name when it was picked, shown while it isn't installed.
    var name: String
    var condition = Condition.running
    var action = Action.pause
    /// What a load action loads, as WE's rule stores it in `file`: the wallpaper's folder
    /// (`WEWallpaper.identityPath`), the playlist's id, or the profile's name.
    var file: String?
    /// The wallpaper's, playlist's or profile's name when it was picked, shown while it is gone.
    var fileName: String?
    var isEnabled = true

    init(id: UUID = UUID(), bundleIdentifier: String, name: String, condition: Condition = .running,
         action: Action = .pause, file: String? = nil, fileName: String? = nil, isEnabled: Bool = true) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.condition = condition
        self.action = action
        self.file = file
        self.fileName = fileName
        self.isEnabled = isEnabled
    }

    /// Whether the rule can act at all: a load action needs something to load.
    var isActive: Bool {
        guard isEnabled, action != .keepRunning, !bundleIdentifier.isEmpty else { return false }
        return action.loadKind == nil || !(file ?? "").isEmpty
    }

    /// What the rule loads while it applies; nil for a playback action.
    var load: ApplicationRuleLoad? {
        guard let kind = action.loadKind, let file, !file.isEmpty else { return nil }
        return ApplicationRuleLoad(kind: kind, file: file)
    }

    /// Whether the audio process `processBundleIdentifier` is the application's: the
    /// application itself, or one of its helpers, whose identifiers extend the application's
    /// (`com.google.Chrome.helper` for `com.google.Chrome`).
    func ownsAudioProcess(_ processBundleIdentifier: String) -> Bool {
        processBundleIdentifier == bundleIdentifier || processBundleIdentifier.hasPrefix(bundleIdentifier + ".")
    }
}

extension ApplicationRule {
    enum CodingKeys: String, CodingKey {
        case id, bundleIdentifier, name, condition, action, file, fileName, isEnabled
    }

    /// A rule needs its application; any other field that is missing or unknown keeps its default.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let bundleIdentifier = try container.decode(String.self, forKey: .bundleIdentifier)
        self.init(bundleIdentifier: bundleIdentifier, name: bundleIdentifier)
        func read<Value: Decodable>(_ key: CodingKeys, _ value: inout Value) {
            do {
                if let stored = try container.decodeIfPresent(Value.self, forKey: key) { value = stored }
            } catch {
                OWELog.error(.settings, "Application rule \(bundleIdentifier): \(key.stringValue) can't be read and keeps its default: \(error)")
            }
        }
        read(.id, &id)
        read(.name, &name)
        read(.condition, &condition)
        read(.action, &action)
        read(.file, &file)
        read(.fileName, &fileName)
        read(.isEnabled, &isEnabled)
    }
}

/// Reads stored application rules one at a time, so one unreadable rule doesn't drop the others.
struct ApplicationRuleList: Decodable {
    var rules: [ApplicationRule] = []

    init() {}

    init(from decoder: Decoder) throws {
        rules = try [Element](from: decoder).compactMap(\.rule)
    }

    private struct Element: Decodable {
        var rule: ApplicationRule?

        init(from decoder: Decoder) throws {
            do {
                rule = try ApplicationRule(from: decoder)
            } catch {
                OWELog.error(.settings, "An application rule can't be read and is left out: \(error)")
                rule = nil
            }
        }
    }
}
