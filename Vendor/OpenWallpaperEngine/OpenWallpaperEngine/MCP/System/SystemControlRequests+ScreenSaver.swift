import Foundation
import OWEControlProtocol

/// The screen saver: Scene Edit / Export's Screen Saver mode (its layer and property choices, Set
/// as Screen Saver, Stop Using as Screen Saver).
extension SystemControlRequests {
    /// Choosing it in macOS is the user's: OWE only opens that pane for them.
    static let pickInSystemSettings = "To use it, pick \"Open Wallpaper Engine\" in System Settings › Screen Saver if it isn't your screen saver yet."

    func screenSaver(_ params: ControlParameters, lookup: ControlLookup) throws -> JSONValue {
        let state = service.screenSaver
        var result: [String: JSONValue] = [
            "plugin_enabled": .bool(state.pluginEnabled),
            "selection": state.selection.map(Self.json) ?? .null,
            // Settings › General › Screen Saver Same as Wallpaper: on while nothing is set.
            "same_as_wallpaper": .bool(state.selection == nil),
        ]
        var message = state.pluginEnabled ? "The Screen Saver plugin is on" : "The Screen Saver plugin is off"
        if let selection = state.selection {
            let name = selection.wallpaper.map { "\"\($0.title)\"" } ?? "a wallpaper no longer in the library"
            message += selection.wallpaper?.type == "video"
                ? "; \(name) is the screen saver, its video drawn live by the app."
                : "; \(name) is the screen saver, drawn live with its screen saver choices."
        } else {
            message += state.pluginEnabled ? "; it draws the desktop's wallpapers live (nothing is set as the screen saver)." : "."
        }
        if let id = try params.string("wallpaper_id") {
            let wallpaper = try lookup.wallpaper(id)
            result["wallpaper"] = try screenSaverWallpaper(wallpaper, selection: state.selection)
        }
        result["message"] = .string(message + " " + Self.pickInSystemSettings)
        return .object(result)
    }

    /// The wallpaper's screen saver version: its layers as the screen saver shows them and its
    /// user properties, from the screen saver's own choices or the wallpaper's values.
    private func screenSaverWallpaper(_ wallpaper: ControlWallpaper, selection: SystemScreenSaverSelection?) throws -> JSONValue {
        var object: [String: JSONValue] = ["wallpaper": ControlLookup.json(wallpaper)]
        let isSelected = selection?.wallpaper.map { $0.folder.standardizedFileURL == wallpaper.folder.standardizedFileURL } ?? false
        object["is_screen_saver"] = .bool(isSelected)
        guard wallpaper.type == "scene" else {
            object["eligible"] = false
            return .object(object)
        }
        object["eligible"] = true
        let values = try service.screenSaverValues(of: wallpaper)
        object["own_choices"] = .bool(values.isOwn)
        object["layers"] = .array(try service.layers(of: wallpaper).map { Self.json($0, values: values.values) })
        let properties = WallpaperPropertyReset.values(removingSceneInspectorEditsFrom: values.values)
        object["properties"] = .object(properties.mapValues { .string($0) })
        return .object(object)
    }

    /// The mode's layer switches and user properties, saved as the screen saver's own choices.
    func setScreenSaverLayers(_ params: ControlParameters, lookup: ControlLookup) throws -> JSONValue {
        let wallpaper = try lookup.sceneWallpaper(params.required("wallpaper_id"))
        let layerItems = try params.objects("layers")
        let propertyItems = try params.objects("properties")
        guard !layerItems.isEmpty || !propertyItems.isEmpty else {
            throw ControlError(.invalidParams, "Give layers to show or hide, properties to set, or both.")
        }
        let layers = try service.layers(of: wallpaper)
        var changes: [String: String] = [:]
        var described: [String] = []
        for item in layerItems {
            let layer = try Self.layer(try item.required("layer"), in: layers, wallpaper: wallpaper)
            let visible = try item.requiredBool("visible")
            changes[sceneObjectVisibilityKey(objectID: layer.id)] = visible ? "true" : "false"
            described.append("\(visible ? "showed" : "hid") \"\(layer.name)\"")
        }
        if !propertyItems.isEmpty {
            let properties = lookup.model.properties(of: wallpaper)
            for item in propertyItems {
                let key = try item.required("key")
                guard let property = properties.first(where: { $0.key == key }) else {
                    let keys = properties.filter { !["text", "group", ""].contains($0.type) }.map(\.key).sorted().joined(separator: ", ")
                    throw ControlError(.notFound, "\"\(wallpaper.title)\" has no user property \"\(key)\". "
                                       + (keys.isEmpty ? "It has none to set." : "Its properties: \(keys)."))
                }
                guard let value = item.raw["value"] else { throw ControlError(.invalidParams, "properties: \(key) needs a value.") }
                let stored = try ControlUserPropertyValue.stored(value, for: property)
                changes[key] = stored
                described.append("set \(key) to \(stored)")
            }
        }
        var values = try service.screenSaverValues(of: wallpaper).values
        values.merge(changes) { _, new in new }
        let saved = try service.setScreenSaverValues(values, of: wallpaper)
        let message = saved
            ? "Saved the screen saver's choices for \"\(wallpaper.title)\": \(Self.sentenceList(described)). The desktop is unchanged; the screen saver draws it with them while it is set as the screen saver (screensaver_set)."
            : "These are \"\(wallpaper.title)\"'s own values, which the screen saver follows until its choices differ, so nothing was saved."
        return [
            "wallpaper": ControlLookup.json(wallpaper),
            "saved": .bool(saved),
            "layers": .array(layers.map { Self.json($0, values: values) }),
            "properties": .object(WallpaperPropertyReset.values(removingSceneInspectorEditsFrom: values).mapValues { .string($0) }),
            "message": .string(message),
        ]
    }

    func setScreenSaver(_ params: ControlParameters, lookup: ControlLookup) async throws -> JSONValue {
        let wallpaper = try lookup.wallpaper(params.required("wallpaper_id"))
        guard ["scene", "video", "web"].contains(wallpaper.type) else {
            throw ControlError(.unsupported, "\"\(wallpaper.title)\" is a \(wallpaper.type) wallpaper; Set as Screen Saver takes scenes, videos and web wallpapers.")
        }
        let set = try await service.setScreenSaver(wallpaper)
        var message: String
        switch wallpaper.type {
        case "scene":
            message = "\"\(wallpaper.title)\" is the screen saver, drawn live with its screen saver choices (screensaver_set_layers)."
        case "video":
            message = "\"\(wallpaper.title)\" is the screen saver, its video drawn live by the app (a WebM video through the Chromium engine)."
        default:
            message = "\"\(wallpaper.title)\" is the screen saver, drawn live through the Chromium engine."
        }
        if set.enabledPlugin {
            message += " The Screen Saver plugin was off, so this turned it on (which installs the saver), as the Screen Saver mode does."
        }
        return [
            "wallpaper": ControlLookup.json(wallpaper),
            "selection": Self.json(set.selection),
            "enabled_plugin": .bool(set.enabledPlugin),
            "same_as_wallpaper": false,
            "message": .string(message + " Screen Saver Same as Wallpaper is now off. " + Self.pickInSystemSettings),
        ]
    }

    func stopUsingScreenSaver() throws -> JSONValue {
        let state = service.screenSaver
        guard let selection = state.selection else {
            return ["stopped": false, "same_as_wallpaper": true,
                    "message": "Nothing is set as the screen saver; it already follows the desktop's wallpapers (Screen Saver Same as Wallpaper is on)."]
        }
        service.stopUsingScreenSaver()
        let title = selection.wallpaper.map { "\"\($0.title)\"" } ?? "The wallpaper"
        return ["stopped": true, "same_as_wallpaper": true,
                "message": .string("\(title) is no longer the screen saver; it follows the desktop's wallpapers again (Screen Saver Same as Wallpaper is on).")]
    }

    // MARK: Lookup and writing

    /// A layer by its id, or by its name when only one layer has it.
    static func layer(_ name: String, in layers: [SystemSceneLayer], wallpaper: ControlWallpaper) throws -> SystemSceneLayer {
        if let id = Int(name), let layer = layers.first(where: { $0.id == id }) { return layer }
        let named = layers.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        if named.count == 1 { return named[0] }
        if named.count > 1 {
            throw ControlError(.invalidParams, "\"\(wallpaper.title)\" has \(named.count) layers named \"\(name)\"; give one's id: "
                               + named.map { String($0.id) }.joined(separator: ", ") + ".")
        }
        let known = layers.prefix(40).map { "\($0.id) (\($0.name))" }.joined(separator: ", ")
        throw ControlError(.notFound, "\"\(wallpaper.title)\" has no layer \"\(name)\". Its layers: \(known)\(layers.count > 40 ? ", …" : "").")
    }

    /// A layer as the screen saver shows it: its own choice, else scene.json's.
    static func json(_ layer: SystemSceneLayer, values: [String: String]) -> JSONValue {
        let visible = values[sceneObjectVisibilityKey(objectID: layer.id)].map { $0 != "false" } ?? layer.authoredVisible
        return [
            "id": .number(Double(layer.id)), "name": .string(layer.name), "kind": .string(layer.kind),
            "visible": .bool(visible), "authored_visible": .bool(layer.authoredVisible),
        ]
    }

    static func json(_ selection: SystemScreenSaverSelection) -> JSONValue {
        [
            "wallpaper": selection.wallpaper.map(ControlLookup.json) ?? .null,
            "folder": .string(selection.folder),
            "kind": .string(selection.kind.rawValue),
            "picked": date(selection.picked),
        ]
    }
}
