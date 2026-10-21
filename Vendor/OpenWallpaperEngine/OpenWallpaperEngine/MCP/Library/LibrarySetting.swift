import Foundation
import OWEControlProtocol

/// One app setting `settings_get` lists and `settings_set` changes: its snake_case key, what it
/// takes and what it does. `all` is the allow-list (`docs/mcp.md`); settings that are about
/// security, the system or the app's own upkeep are refused by `named(_:)` with the reason and
/// where in the app to change them.
struct LibrarySetting: Equatable {
    enum Kind: Equatable {
        case bool
        case number(minimum: Double, maximum: Double, wholeNumbers: Bool)
        case choice([String])
        /// A button that applies one of the values (the quality presets); there is no value to read.
        case action([String])
    }

    let key: String
    let kind: Kind
    /// What it does, in one line.
    let summary: String
    /// Earlier names of a choice's values, by the value they now set (lowercase); not listed.
    let aliases: [String: String]

    private init(_ key: String, _ kind: Kind, _ summary: String, aliases: [String: String] = [:]) {
        self.key = key
        self.kind = kind
        self.summary = summary
        self.aliases = aliases
    }

    // MARK: - The allow-list

    private static let running = "keep_running"

    static let all: [LibrarySetting] = playback + quality + optimizations + appearance + playlists

    /// Settings › Performance › Playback.
    private static let playback: [LibrarySetting] = [
        LibrarySetting("other_application_focused", .choice([running, "mute", "pause", "pause_all"]),
                       "What wallpapers do while another app's window is active: pause pauses that window's display, pause_all every display."),
        LibrarySetting("other_application_maximized", .choice([running, "mute", "pause", "pause_all", "stop"]),
                       "What wallpapers do while another app's window fills their display; stop frees the wallpaper's memory."),
        LibrarySetting("other_application_fullscreen", .choice([running, "mute", "pause", "pause_all", "stop"]),
                       "What wallpapers do while another app is in full screen on their display."),
        LibrarySetting("other_application_playing_audio", .choice([running, "mute", "pause"]),
                       "What wallpapers do while another app plays sound."),
        LibrarySetting("display_asleep", .choice([running, "pause", "stop"]),
                       "What wallpapers do while the displays sleep."),
        LibrarySetting("laptop_on_battery", .choice([running, "pause", "stop"]),
                       "What wallpapers do while the Mac runs on battery."),
    ]

    /// Settings › Performance › Quality.
    private static let quality: [LibrarySetting] = [
        LibrarySetting("quality_preset", .action(["low", "medium", "high", "ultra"]),
                       "A preset button: sets the quality settings, the FPS and quality_efficiency in one step."),
        LibrarySetting("anti_aliasing", .choice(["none", "msaa_x2", "msaa_x4", "msaa_x8"]),
                       "Multisampling of scenes' edges; more samples cost more GPU time and memory."),
        LibrarySetting("post_processing", .choice(["disabled", "enabled", "ultra", "display_hdr"]),
                       "Bloom in scenes: ultra draws HDR scenes' bloom in HDR, display_hdr also sends HDR to the display (only where a display shows HDR)."),
        LibrarySetting("texture_resolution", .choice(["high_quality", "high_performance", "automatic"]),
                       "Wallpaper Engine's Texture Resolution: high_performance loads textures and runs effects at half size."),
        LibrarySetting("scene_detail", .choice(["match_display", "full"]),
                       "Effect Detail: match_display runs each layer's effects at most at its size on screen; full runs them at the texture's size."),
        LibrarySetting("render_resolution", .choice(["your_display", "uhd4k", "full"]),
                       "The size scenes are drawn at: your_display the display's own pixels, uhd4k 4K at the display's shape fitted to it, full the wallpaper's authored size.",
                       aliases: ["display": "your_display", "retina": "your_display", "4k": "uhd4k"]),
        LibrarySetting("upscaling", .choice(["off", "bilinear"]),
                       "bilinear draws scenes at render_scale and scales them up bilinearly: fewer pixels, softer.",
                       aliases: ["metalfx": "bilinear"]),
        LibrarySetting("render_scale", .choice(["50", "67", "75"]),
                       "The percentage of each side scenes render at while upscaling."),
        LibrarySetting("shadows", .choice(["disabled", "low", "medium", "high", "ultra"]),
                       "Shadows cast by wallpapers' lights."),
        LibrarySetting("volumetrics", .choice(["disabled", "low", "medium", "high", "ultra"]),
                       "Light shafts from wallpapers' volumetric lights."),
        LibrarySetting("fps", .number(minimum: 10, maximum: GlobalSettings.unlimitedFPS, wholeNumbers: true),
                       "The most frames a second scene and web wallpapers draw; 240 means no limit. Set here, it wins over quality_efficiency's cap, as the FPS slider does."),
        LibrarySetting("quality_efficiency", .number(minimum: Double(QualityEfficiency.stops.lowerBound),
                                                     maximum: Double(QualityEfficiency.stops.upperBound), wholeNumbers: true),
                       "The Quality ↔ Efficiency slider: 1 is quality, 5 efficiency (capped motion, fewer redraws, smaller blurs)."),
        LibrarySetting("particle_budget", .choice(["low", "medium", "high", "unlimited"]),
                       "The most particles one scene may hold: 10,000, 25,000, 50,000 or no limit."),
        LibrarySetting("reflections", .bool, "Lets scenes draw their reflection effects."),
    ]

    /// Settings › Optimizations.
    private static let optimizations: [LibrarySetting] = [
        LibrarySetting("sync_properties_across_displays", .bool,
                       "One set of user properties for a wallpaper on every display; off, each display keeps its own."),
        LibrarySetting("video_framework", .choice(["avkit", "metal"]),
                       "avkit plays videos with Apple's player; metal draws them through the scene renderer so their effects apply."),
        LibrarySetting("audio_output", .bool, "Plays the wallpapers' own sound; off silences every wallpaper."),
        LibrarySetting("reload_on_output_device_change", .bool,
                       "Reloads the wallpapers and their audio when the sound output changes."),
        LibrarySetting("media_integration", .bool,
                       "Lets wallpapers show the title, artist and cover of what is playing now."),
        LibrarySetting("optimise_textures", .bool, "Compresses scenes' images once in the background to save GPU memory."),
        LibrarySetting("cheaper_shadows", .bool, "Draws shadow maps at half size."),
        LibrarySetting("web_standard_resolution", .bool,
                       "Draws web wallpapers at standard resolution, a quarter of the pixels on Retina."),
        LibrarySetting("reduced_resolution_particles", .bool,
                       "Draws large glowing particle effects of 2D scenes at half resolution."),
        LibrarySetting("process_priority", .choice(["normal", "below_normal"]),
                       "below_normal lets other apps go first."),
        LibrarySetting("pause_on_vram_exhausted", .bool, "Pauses every wallpaper while the GPU is out of video memory."),
    ]

    /// Settings › General and the wallpaper details' placement.
    private static let appearance: [LibrarySetting] = [
        LibrarySetting("appearance", .choice(["light", "dark", "follow_system"]), "Whether the app's windows are light or dark."),
        LibrarySetting("adjust_menu_bar_tint", .bool,
                       "While a video or web wallpaper plays, sets the desktop picture to a frame of it so the menu bar's tint matches."),
        LibrarySetting("wallpaper_placement", .choice(["fill", "fit", "center", "stretch", "zoom"]),
                       "How video and web wallpapers fit their displays, as the details panel's Placement does."),
    ]

    /// The playlist view's app-wide toggles.
    private static let playlists: [LibrarySetting] = [
        LibrarySetting("playlist_rotate", .bool, "The active playlist rotates by itself (Rotate automatically)."),
        LibrarySetting("playlist_shuffle", .bool, "Playlists play in random order."),
        LibrarySetting("playlist_repeat", .bool, "A playlist starts over after its last wallpaper."),
    ]

    // MARK: - Refused

    private static let security = "is security-relevant, so it stays the user's to change in the app"

    /// Settings a client may ask for that stay in the app, with why and where they are.
    static let refused: [String: String] = [
        "auto_start": "Launch at login \(security): Settings › General › Start with macOS.",
        "launch_at_login": "Launch at login \(security): Settings › General › Start with macOS.",
        "start_with_macos": "Launch at login \(security): Settings › General › Start with macOS.",
        "restart_after_crashing": "Restart after crashing \(security): Settings › Optimizations › Restart after crashing.",
        "crash_reporting": "Open Wallpaper Engine has no crash reporting: it sends no crash reports anywhere, so there is nothing to change.",
        "update_channel": "Updates are security-relevant, so they stay the user's to change in the app: Settings › Updates.",
        "automatic_updates": "Updates are security-relevant, so they stay the user's to change in the app: Settings › Updates.",
        "web_wallpaper_trust": "Trusting a web wallpaper \(security): apply it once in the app and answer its question.",
        "trusted_wallpapers": "Trusting a web wallpaper \(security): apply it once in the app and answer its question.",
        "plugins": "Plugins are installed and removed in the app only: Settings › Plugins. plugin_status reads them.",
        "mcp_server": "Plugins are installed and removed in the app only: Settings › Plugins. plugin_status reads them.",
        "chromium_engine": "Plugins are installed and removed in the app only: Settings › Plugins. plugin_status reads them.",
        "depth_map_generation": "Plugins are installed and removed in the app only: Settings › Plugins. plugin_status reads them.",
        "language": "The language applies after a restart and is the user's to choose: Settings › General › Language.",
        "log_level": "The log level is a diagnostics setting: Settings › Diagnostics.",
        "screen_saver": "The screen saver is set with the screen saver tools, or in Settings › Plugins › Screen Saver.",
        "lock_screen_picture": "The lock screen picture is set with the lock screen tools, or in Settings › General › Show Wallpaper on Lock Screen.",
        "application_rules": "Application rules are a list of apps: edit them in Settings › Performance › Application Rules.",
        "auto_refresh": "Open Wallpaper Engine has no control for auto refresh, so it isn't changed from here.",
    ]

    /// The allow-listed setting with this key; a refused or unknown key is a `ControlError`
    /// saying why.
    static func named(_ key: String) throws -> LibrarySetting {
        let normalized = key.trimmingCharacters(in: .whitespaces).lowercased()
        if let setting = all.first(where: { $0.key == normalized }) { return setting }
        if let reason = refused[normalized] { throw ControlError(.refused, reason) }
        throw ControlError(.notFound, "There is no setting \"\(key)\". Settings: \(all.map(\.key).joined(separator: ", ")).")
    }

    // MARK: - Values

    /// `value` as this setting takes it: a bool, a number in range, or one of the choices (as
    /// text, case-insensitive). Text from a client ("true", "30") is read as its type.
    func parse(_ value: JSONValue) throws -> JSONValue {
        let text = value.stringValue?.trimmingCharacters(in: .whitespaces)
        switch kind {
        case .bool:
            if let flag = value.boolValue { return .bool(flag) }
            switch text?.lowercased() {
            case "true": return .bool(true)
            case "false": return .bool(false)
            default: throw ControlError(.invalidParams, "\(key) takes true or false.")
            }
        case let .number(minimum, maximum, wholeNumbers):
            guard let number = value.doubleValue ?? text.flatMap(Double.init), number.isFinite else {
                throw ControlError(.invalidParams, "\(key) takes a number from \(Self.format(minimum)) to \(Self.format(maximum)).")
            }
            guard (minimum...maximum).contains(number) else {
                throw ControlError(.invalidParams, "\(key) must be from \(Self.format(minimum)) to \(Self.format(maximum)); \(Self.format(number)) is out of range.")
            }
            guard !wholeNumbers || number.rounded() == number else {
                throw ControlError(.invalidParams, "\(key) takes a whole number.")
            }
            return .number(number)
        case let .choice(values), let .action(values):
            let written = text ?? value.doubleValue.map(Self.format) ?? ""
            let given = aliases[written.lowercased()] ?? written
            guard let match = values.first(where: { $0.caseInsensitiveCompare(given) == .orderedSame }) else {
                throw ControlError(.invalidParams, "\(key) takes one of: \(values.joined(separator: ", ")).")
            }
            return .string(match)
        }
    }

    /// The setting as `settings_get` lists it, with `value`.
    func json(value: JSONValue) -> JSONValue {
        var object: [String: JSONValue] = ["key": .string(key), "value": value, "description": .string(summary)]
        switch kind {
        case .bool:
            object["type"] = "boolean"
        case let .number(minimum, maximum, wholeNumbers):
            object["type"] = wholeNumbers ? "integer" : "number"
            object["minimum"] = .number(minimum)
            object["maximum"] = .number(maximum)
        case let .choice(values):
            object["type"] = "choice"
            object["values"] = .array(values.map { .string($0) })
        case let .action(values):
            object["type"] = "action"
            object["values"] = .array(values.map { .string($0) })
        }
        return .object(object)
    }

    private static func format(_ number: Double) -> String {
        number.rounded() == number ? String(Int(number)) : String(number)
    }
}
