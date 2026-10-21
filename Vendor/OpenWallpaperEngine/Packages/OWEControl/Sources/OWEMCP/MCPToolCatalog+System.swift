import Foundation
import OWEControlProtocol

/// The system features OWE drives (`docs/mcp.md`): Scene Edit / Export's iPhone & iPad Export
/// and Screen Saver modes, the screen saver's daily re-recording, and the lock-screen picture. None
/// of them opens System Settings or makes macOS ask the user for a permission.
extension MCPToolCatalog {
    static let systemTools: [MCPTool] = exportTools + androidTools + screenSaverTools + lockScreenTools

    // MARK: - iPhone & iPad Export

    private static let exportTools: [MCPTool] = [
        MCPTool("devices_list", title: "List Export Devices",
                description: "The iPhones and iPads Scene Edit / Export's iPhone & iPad Export mode makes Live Photo lock screens for: each device's id (its name), family, screen size in pixels (portrait) and year, newest first. The query narrows them as the mode's device search does (name, family, year or resolution such as \"1320x2868\").",
                input: JSONSchema.object([
                    "query": JSONSchema.string("Words to find in the device's name, family, year or resolution."),
                ]), annotations: .readOnly) { message($0) },
        MCPTool("export_settings_get", title: "Get Export Settings",
                description: "What the iPhone & iPad Export mode remembers (the device, and \"Also Save to Photos Album\" with its album and whether Photos access is granted) and the ranges export_live_photo takes. With wallpaper_id, also the scene's size in scene units, which the crop's centre is measured in.",
                input: JSONSchema.object([
                    "wallpaper_id": JSONSchema.string("A scene wallpaper's id from list_wallpapers, to read its scene size.", minLength: 1),
                ]), annotations: .readOnly) { message($0) },
        MCPTool("export_live_photo", title: "Export Live Photo",
                description: "Renders a scene wallpaper as a Live Photo (a HEIC photo and its MOV) for an iPhone or iPad lock screen, as the iPhone & iPad Export mode's Save does, with the wallpaper's own property values and edits, and waits for it (this takes a while). Returns both files' paths. Without output_folder they stay in the app's cache until the mode's next export; when the user has \"Also Save to Photos Album\" on and Photos access granted, it also goes to that album (never asking for access).",
                input: JSONSchema.object([
                    "wallpaper_id": JSONSchema.string("A scene wallpaper's id from list_wallpapers.", minLength: 1),
                    "device": JSONSchema.string("A device's id from devices_list (any case; a search that finds one device works too). Omit it for the device the export remembers.", minLength: 1),
                    "crop": described(JSONSchema.object([
                        "zoom": JSONSchema.number("1 shows the largest window at the device's shape the scene covers; up to 3 zooms in.", minimum: 1, maximum: 3),
                        "center_x": JSONSchema.number("The window's centre, in scene units from the left (export_settings_get gives the scene's size). Omitted: the middle."),
                        "center_y": JSONSchema.number("The window's centre, in scene units from the top. Omitted: the middle."),
                    ]), "The part of the scene the lock screen shows, as the mode's drag and pinch set it; kept inside the scene."),
                    "clip": described(JSONSchema.object([
                        "start": JSONSchema.number("Seconds into the scene the clip starts. Omitted: the window with the most motion, as the mode picks when it opens.", minimum: 0, maximum: 29),
                        "length": JSONSchema.number("The clip's length in seconds, 1 to 3 (3 by default).", minimum: 1, maximum: 3),
                    ]), "The seconds of the scene the Live Photo moves through."),
                    "settings": described(JSONSchema.object([
                        "quality": JSONSchema.string("How much the movie is compressed: best (the default), high or smaller.", oneOf: ["best", "high", "smaller"]),
                        "save_to_photos": JSONSchema.boolean("false leaves this export out of the Photos album. It can't turn the album on when the user's setting is off."),
                    ]), "The Export Settings."),
                    "output_folder": JSONSchema.string("An existing folder's absolute path to copy the photo and movie into (files of the same name are replaced).", minLength: 1),
                ], required: ["wallpaper_id"]), annotations: .change, longRunning: true) { message($0) },
    ]

    // MARK: - Android export

    /// The export's choices, which `android_send_wifi` takes too when it exports first.
    private static let androidExportChoices: [String: JSONValue] = [
        "mode": JSONSchema.string("How scenes are exported: high_quality (Dynamic, full-size textures), balanced (Dynamic, textures at half size; the default) or pre_rendered (a video).", oneOf: ["high_quality", "balanced", "pre_rendered"]),
        "options": described(JSONSchema.object([
            "pixel_art": JSONSchema.boolean("Pixel art optimization: textures keep every pixel, uncompressed, with nearest filtering (Dynamic)."),
            "texture_reduction": JSONSchema.integer("Divides colour textures' sides by 1, 2 or 4 (Dynamic); the mode sets it otherwise.", minimum: 1, maximum: 4),
            "cropping": JSONSchema.string("Video Cropping (pre_rendered): phone fits a 9:16 portrait screen (the default); original keeps the scene's shape.", oneOf: ["phone", "original"]),
            "video_preset": JSONSchema.string("Video Preset (pre_rendered): full_hd (1080 pixels on the short side, the default), uhd_4k (2160) or original (the scene's own size).", oneOf: ["original", "full_hd", "uhd_4k"]),
            "fps": JSONSchema.integer("Frames per second of the video (pre_rendered): 24, 30 (the default) or 60.", minimum: 24, maximum: 60),
            "alignment": JSONSchema.number("Where the portrait crop sits across the scene (pre_rendered): 0 left, 0.5 centre (the default), 1 right.", minimum: 0, maximum: 1),
        ]), "The dialog's advanced and video settings."),
    ]

    private static let androidTools: [MCPTool] = [
        MCPTool("export_android", title: "Export for Android",
                description: "Wallpaper Engine's \"Export .mpkg\" for its Android app, as Scene Edit / Export's Android Export does: writes one <title>.mpkg per wallpaper (unique names) into output_folder and waits for it (a pre-rendered scene takes a while). Videos are packed as they are; scenes are Dynamic (the scene itself, rendered on the device: high_quality or balanced) or pre_rendered (a 30 s H.264 loop of the scene). Web and application wallpapers are skipped with the reason. Returns each package's path, size and preview, and what was skipped or failed. The user copies the files to the device and imports them in the app.",
                input: JSONSchema.object(androidExportChoices.merging([
                    "wallpaper_id": JSONSchema.string("A wallpaper's id from list_wallpapers. Give this or wallpaper_ids.", minLength: 1),
                    "wallpaper_ids": JSONSchema.stringArray("Several wallpapers' ids from list_wallpapers, exported in this order.", maxItems: 200),
                    "output_folder": JSONSchema.string("An existing folder's absolute path for the packages. Omitted: the app's export cache folder.", minLength: 1),
                ]) { $1 }), annotations: .change, longRunning: true) { message($0) },
        MCPTool("android_send_wifi", title: "Send to Android over Wi-Fi",
                description: "The Android export's \"Send over Wi-Fi\": starts a small web server on the Mac's local network (not the internet) that serves only these packages, behind a random 128-bit token in the URL, for 15 minutes, and returns the URL and when it expires. Open the URL in a browser on the Android device (same Wi-Fi): it lists every package with a Download button and Download All; then import each file in the Wallpaper Engine app. Give package_paths (what export_android returned), or wallpaper_id / wallpaper_ids to export them first (with mode, options and output_folder as export_android takes them; a pre-rendered scene takes a while). A new call replaces the previous one. The first phone that connects may make macOS ask whether the app may accept incoming connections.",
                input: JSONSchema.object(androidExportChoices.merging([
                    "package_paths": JSONSchema.stringArray("Absolute paths of .mpkg packages export_android wrote, in the order the page lists them.", maxItems: 200),
                    "wallpaper_id": JSONSchema.string("A wallpaper's id from list_wallpapers, exported first. Give this, wallpaper_ids or package_paths.", minLength: 1),
                    "wallpaper_ids": JSONSchema.stringArray("Several wallpapers' ids from list_wallpapers, exported first in this order.", maxItems: 200),
                    "output_folder": JSONSchema.string("With wallpaper ids: an existing folder's absolute path for the packages. Omitted: the app's export cache folder.", minLength: 1),
                    "address": JSONSchema.string("One of the Mac's local-network IPv4 addresses to serve on (the result lists them). Omitted: the primary interface's.", minLength: 7),
                ]) { $1 }), annotations: .change, longRunning: true) { message($0) },
    ]

    // MARK: - Screen saver

    private static let screenSaverTools: [MCPTool] = [
        MCPTool("screensaver_get", title: "Get Screen Saver",
                description: "The screen saver: whether the Screen Saver plugin is on, and the wallpaper set as the screen saver (kind live: drawn live, a scene with its screen saver choices, a video as it is; and when it was picked), or none while it draws the desktop's wallpapers live; same_as_wallpaper is Settings › General › \"Screen Saver Same as Wallpaper\", on exactly while nothing is set. With wallpaper_id, also that wallpaper's screen saver version: its layers as the screen saver shows them and its user property values, from the Screen Saver mode's saved choices or else the wallpaper's own.",
                input: JSONSchema.object([
                    "wallpaper_id": JSONSchema.string("A wallpaper's id from list_wallpapers.", minLength: 1),
                ]), annotations: .readOnly) { message($0) },
        MCPTool("screensaver_set_layers", title: "Set Screen Saver Layers",
                description: "Shows or hides a scene's layers and sets its user properties in its screen saver version only, as Scene Edit / Export's Screen Saver mode does: saved as the screen saver's own choices for that wallpaper, never touching the desktop. The screen saver draws it with them while it is set as the screen saver.",
                input: JSONSchema.object([
                    "wallpaper_id": JSONSchema.string("A scene wallpaper's id from list_wallpapers.", minLength: 1),
                    "layers": JSONSchema.objectArray("Layers to show or hide.", item: JSONSchema.object([
                        "layer": JSONSchema.string("The layer's id or name, from screensaver_get.", minLength: 1),
                        "visible": JSONSchema.boolean("true shows it, false hides it."),
                    ], required: ["layer", "visible"]), maxItems: 500),
                    "properties": JSONSchema.objectArray("User properties to set, checked as set_user_property checks them.", item: JSONSchema.object([
                        "key": JSONSchema.string("The property's key, from get_wallpaper.", minLength: 1),
                        "value": JSONSchema.string("The value as text, as set_user_property takes it."),
                    ], required: ["key", "value"]), maxItems: 200),
                ], required: ["wallpaper_id"]), annotations: .idempotent) { message($0) },
        MCPTool("screensaver_set", title: "Set as Screen Saver",
                description: "\"Set as Screen Saver\" from the Screen Saver mode: a scene becomes the screen saver, drawn live with its screen saver choices while the screen saver runs; a video wallpaper is drawn live as it is; a web wallpaper or WebM video is drawn live through the Chromium engine (refused while it isn't installed). Nothing is recorded. It turns the Screen Saver plugin on when it is off, as the mode does, and turns \"Screen Saver Same as Wallpaper\" off. The user picks \"Open Wallpaper Engine\" in System Settings › Screen Saver.",
                input: JSONSchema.object([
                    "wallpaper_id": JSONSchema.string("A scene, video or web wallpaper's id from list_wallpapers.", minLength: 1),
                ], required: ["wallpaper_id"]), annotations: .change, longRunning: true) { message($0) },
        MCPTool("screensaver_stop_using", title: "Stop Using as Screen Saver",
                description: "\"Stop Using as Screen Saver\": the screen saver goes back to drawing the desktop's wallpapers live, which turns Settings › General › \"Screen Saver Same as Wallpaper\" on.",
                annotations: .change) { message($0) },
    ]

    // MARK: - Lock screen

    private static let lockScreenTools: [MCPTool] = [
        MCPTool("lock_screen_get", title: "Get Lock Screen",
                description: "Settings › General › \"Show Wallpaper on Lock Screen\": whether it is on, the selected display's wallpaper, and each display's wallpaper and desktop picture (which the lock screen shows), and whether this copy may change the desktop picture.",
                annotations: .readOnly) { message($0) },
        MCPTool("lock_screen_set", title: "Set Lock Screen",
                description: "Turns \"Show Wallpaper on Lock Screen\" on (each display's lock screen shows a picture of the wallpaper it shows) or off (the user's own desktop pictures come back), as Settings › General does.",
                input: JSONSchema.object([
                    "enabled": JSONSchema.boolean("true turns it on, false off."),
                ], required: ["enabled"]), annotations: .idempotent) { message($0) },
        MCPTool("lock_screen_refresh", title: "Refresh Lock Screen",
                description: "Draws each display's lock-screen picture again now from the wallpaper it shows (a scene's latest snapshot, a video's frame, a web page's snapshot, or the preview until there is one), as turning the setting on does. The setting must be on.",
                annotations: .change) { message($0) },
    ]

    /// `schema` (an object) with a description, for an object nested in a tool's arguments.
    private static func described(_ schema: JSONValue, _ description: String) -> JSONValue {
        guard case .object(var object) = schema else { return schema }
        object["description"] = .string(description)
        return .object(object)
    }
}
