import Foundation

/// WE's values of the scene settings (scene.json's `general`) a scene doesn't author, as the
/// player reads them (`SceneGeneralDefaults`, `SceneCameraDefaults`, `SceneFogDefaults`: the scene
/// settings constructor in `wallpaper64.exe`). An edit back to the value the scene shows is dropped.
public enum SceneGeneralSetting {
    public static let defaults: [String: SceneJSONValue] = [
        // Bloom and HDR bloom.
        "bloom": .bool(true), "hdr": .bool(false),
        "bloomstrength": .number(2), "bloomthreshold": .number(0.65), "bloomtint": .string("1 1 1"),
        "bloomhdrstrength": .number(2), "bloomhdrthreshold": .number(1), "bloomhdrfeather": .number(0.1),
        "bloomhdrscatter": .number(1.619), "bloomhdriterations": .number(8),
        // General.
        "clearcolor": .string("0 0 0"), "ambientcolor": .string("0 0 0"), "skylightcolor": .string("0 0 0"),
        "transparentsorting": .bool(false),
        // Camera.
        "fov": .number(50), "perspectiveoverridefov": .number(95), "nearz": .number(0.1), "farz": .number(10000),
        "zoom": .number(1),
        "camerashake": .bool(false), "camerashakeamplitude": .number(0.5), "camerashakespeed": .number(3),
        "camerashakeroughness": .number(1),
        "cameraparallax": .bool(false), "cameraparallaxamount": .number(0.5), "cameraparallaxdelay": .number(0.1),
        "cameraparallaxmouseinfluence": .number(0.5),
        // Fog.
        "fogdistance": .bool(false), "fogdistancecolor": .string("0 0 0"),
        "fogdistancestart": .number(1), "fogdistanceend": .number(5),
        "fogdistancestartdensity": .number(0), "fogdistanceenddensity": .number(1),
        "fogheight": .bool(false), "fogheightcolor": .string("0 0 0"),
        "fogheightstart": .number(1), "fogheightend": .number(-3),
        "fogheightstartdensity": .number(0), "fogheightenddensity": .number(1),
        // Physics: global gravity and wind, as WE 2.8 writes them into a new scene.
        "gravitydirection": .string("0 -1 0"), "gravitystrength": .number(1),
        "windenabled": .bool(false), "winddirection": .string("0.707 0.707 0"), "windstrength": .number(1),
    ]
}

extension SceneEditSession {
    /// The scene setting as the scene now has it: the edit, else the authored value (a bound or
    /// scripted setting's `value`), else WE's default.
    public func generalValue(_ name: String) -> SceneJSONValue? {
        overlay.generalSetting(name) ?? SceneFieldBinding.literal(of: authored.general[name])
            ?? SceneGeneralSetting.defaults[name]
    }

    /// How the authored setting gets its value; one a user property sets isn't edited here.
    public func generalBinding(_ name: String) -> SceneFieldBinding {
        SceneFieldBinding(authored.general[name])
    }

    public func generalNumber(_ name: String) -> Double {
        generalValue(name)?.doubleValue ?? 0
    }

    public func generalBool(_ name: String) -> Bool {
        generalValue(name)?.boolValue ?? false
    }

    public func generalVector(_ name: String, count: Int) -> [Double] {
        SceneVector.components(generalValue(name), fallback: Array(repeating: 0, count: count))
    }

    /// Sets the scene setting `general.<name>` as one undo step; the value the scene authored
    /// (or WE's default for one it doesn't) drops the edit. A user-bound setting is left alone.
    public func setGeneral(_ value: SceneJSONValue?, for name: String, actionName: String, coalescing: Bool = false) {
        if case .userProperty = generalBinding(name) { return }
        let shown = SceneFieldBinding.literal(of: authored.general[name]) ?? SceneGeneralSetting.defaults[name]
        var next = overlay
        next.setGeneralSetting(name, to: value.flatMap { Self.same($0, shown) ? nil : $0 })
        commit(next, actionName: actionName, coalescingKey: coalescing ? "general:\(name)" : nil)
    }

    // MARK: Project settings

    /// `general.orthogonalprojection`'s width and height as the scene now has them; nil for a 3D
    /// (perspective) scene or one sized automatically to its first image.
    public var projectResolution: SIMD2<Int>? {
        guard let projection = overlay.generalSetting("orthogonalprojection") ?? authored.general["orthogonalprojection"],
              projection["auto"]?.boolValue != true,
              let width = projection["width"]?.doubleValue, let height = projection["height"]?.doubleValue,
              width >= 1, height >= 1 else { return nil }
        return SIMD2(Int(width), Int(height))
    }

    /// Sets the scene's resolution (`general.orthogonalprojection`), as WE's Project Settings do.
    public func setProjectResolution(_ size: SIMD2<Int>, actionName: String) {
        guard size.x >= 1, size.y >= 1 else { return }
        setGeneral(.object(["width": .number(Double(size.x)), "height": .number(Double(size.y))]),
                   for: "orthogonalprojection", actionName: actionName)
    }

    /// The project's title as edited; nil keeps project.json's.
    public var projectTitle: String? { overlay.project?.title }

    /// Sets the project's title (project.json `title`); `authored`, or an empty title, drops the edit.
    public func setProjectTitle(_ title: String, authored: String?, actionName: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var next = overlay
        var project = next.project ?? SceneProjectEdits()
        project.title = trimmed.isEmpty || trimmed == authored ? nil : trimmed
        next.project = project.isEmpty ? nil : project
        commit(next, actionName: actionName, coalescingKey: "project:title")
    }
}

/// The editor's edits of project.json besides the user properties (WE's Project Settings): kept
/// in the overlay (`SceneEditOverlay.project`), written into project.json by Save as New Wallpaper
/// and, for a wallpaper of the user's own, by File › Save.
public struct SceneProjectEdits: Codable, Hashable, Sendable {
    /// project.json `title`.
    public var title: String?

    public init(title: String? = nil) {
        self.title = title
    }

    public var isEmpty: Bool { title == nil }

    /// Writes the edits into a decoded project.json.
    public func apply(to project: inout [String: Any]) {
        if let title { project["title"] = title }
    }
}
