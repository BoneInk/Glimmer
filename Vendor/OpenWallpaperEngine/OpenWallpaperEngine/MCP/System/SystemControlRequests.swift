import Foundation
import OWEControlProtocol

/// The control channel's requests for the system features OWE drives: iPhone and iPad Live Photo
/// export (`SystemControlRequests+Export`), the screen saver (`+ScreenSaver`) and the lock-screen
/// picture (`docs/mcp.md`). Each does what Scene Edit / Export's modes and the Settings
/// controls do, through `SystemControlService`; none opens System Settings or asks macOS for a
/// permission, and the Screen Saver plugin is turned on only by Set as Screen Saver, as the mode does it.
@MainActor
final class SystemControlRequests: ControlRequestGroup {
    let methods: Set<String> = [
        "devices_list", "export_settings_get", "export_live_photo", "export_android", "android_send_wifi",
        "screensaver_get", "screensaver_set_layers", "screensaver_set", "screensaver_stop_using",
        "lock_screen_get", "lock_screen_set", "lock_screen_refresh",
    ]

    let service: SystemControlService

    init(service: SystemControlService) {
        self.service = service
    }

    static func make(app: AppDelegate, model: AppControlModel) -> SystemControlRequests {
        SystemControlRequests(service: AppSystemControlService(app: app, model: model))
    }

    func result(for method: String, _ params: ControlParameters, lookup: ControlLookup) async throws -> JSONValue {
        switch method {
        case "devices_list": return try devices(params)
        case "export_settings_get": return try exportSettings(params, lookup: lookup)
        case "export_live_photo": return try await exportLivePhoto(params, lookup: lookup)
        case "export_android": return try await exportAndroid(params, lookup: lookup)
        case "android_send_wifi": return try await sendAndroidOverWiFi(params, lookup: lookup)
        case "screensaver_get": return try screenSaver(params, lookup: lookup)
        case "screensaver_set_layers": return try setScreenSaverLayers(params, lookup: lookup)
        case "screensaver_set": return try await setScreenSaver(params, lookup: lookup)
        case "screensaver_stop_using": return try stopUsingScreenSaver()
        case "lock_screen_get": return lockScreen()
        case "lock_screen_set": return try setLockScreen(params)
        case "lock_screen_refresh": return try refreshLockScreen()
        default:
            throw ControlError(.unknownMethod, "The app doesn't know \"\(method)\".")
        }
    }

    // MARK: - Lock screen

    /// The setting's state, the wallpaper it follows and each display's picture.
    private func lockScreen(message: String? = nil) -> JSONValue {
        let state = service.lockScreen
        let follows = state.follows.map { "\"\($0.title)\"" } ?? "no wallpaper"
        var sentence = state.enabled
            ? "Show Wallpaper on Lock Screen is on: each display's lock screen shows a picture of the wallpaper it shows (\(follows) on the selected display): a scene's snapshot, a video's frame or a web page's snapshot, or its preview until there is one."
            : "Show Wallpaper on Lock Screen is off: the lock screens show your own desktop pictures."
        if !state.mayChangeDesktopPicture { sentence += " This copy runs isolated and never changes the desktop picture." }
        return [
            "enabled": .bool(state.enabled),
            "may_change_desktop_picture": .bool(state.mayChangeDesktopPicture),
            "follows": state.follows.map(ControlLookup.json) ?? .null,
            "displays": .array(state.displays.map { display in
                [
                    "id": .string(display.id), "name": .string(display.name),
                    "wallpaper": display.wallpaper.map(ControlLookup.json) ?? .null,
                    "picture": display.picture.map { .string($0.path(percentEncoded: false)) } ?? .null,
                    "is_lock_screen_picture": .bool(display.isLockScreenPicture),
                ]
            }),
            "message": .string(message ?? sentence),
        ]
    }

    private func setLockScreen(_ params: ControlParameters) throws -> JSONValue {
        let enabled = try params.requiredBool("enabled")
        let state = service.lockScreen
        let changed = state.enabled != enabled
        service.setLockScreenEnabled(enabled)
        var message = enabled
            ? (changed ? "Turned on Show Wallpaper on Lock Screen: each display's lock screen shows a picture of its wallpaper." : "Show Wallpaper on Lock Screen was already on.")
            : (changed ? "Turned off Show Wallpaper on Lock Screen: your own desktop pictures are back." : "Show Wallpaper on Lock Screen was already off.")
        if !state.mayChangeDesktopPicture { message += " This copy runs isolated, so it changes no picture." }
        return lockScreen(message: message)
    }

    private func refreshLockScreen() throws -> JSONValue {
        let state = service.lockScreen
        guard state.mayChangeDesktopPicture else {
            throw ControlError(.unavailable, "This copy of Open Wallpaper Engine runs isolated and never changes the desktop picture.")
        }
        guard state.enabled else {
            throw ControlError(.refused, "Show Wallpaper on Lock Screen is off. Turn it on with lock_screen_set (enabled: true), which shows the pictures at once.")
        }
        service.refreshLockScreen()
        let follows = state.follows.map { " (\"\($0.title)\" on the selected display)" } ?? ""
        return lockScreen(message: "Drawing each display's lock-screen picture again from the wallpaper it shows\(follows). A scene with no snapshot yet shows its preview until the running scene captures one.")
    }

    // MARK: - Writing

    static func date(_ date: Date?) -> JSONValue {
        date.map { .string($0.formatted(.iso8601)) } ?? .null
    }

    /// A list of names for a message: "a", "a and b", "a, b and c".
    static func sentenceList(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
    }
}
