import Foundation
import JavaScriptCore
@testable import OpenWallpaperEngine

/// The replay's script host: WE's full prelude (baseclasses.js and the jsmodules) and every error.
final class SceneScriptReplayScriptHost: SceneScriptHost {
    let identity: SceneScriptIdentity
    let prelude: SceneScriptPrelude
    private(set) var errors: [SceneScriptError] = []

    init(wallpaperID: String, prelude: SceneScriptPrelude) {
        identity = SceneScriptIdentity(wallpaperID: wallpaperID, screenID: "replay-screen")
        self.prelude = prelude
    }

    func runtime(_ runtime: SceneScriptRuntime, didReport error: SceneScriptError) {
        errors.append(error)
    }
}

/// The renderer stand-in: the wallpaper's objects described by the app's own
/// `SceneScriptSceneDescriber` (as the renderer's `SceneScriptSceneMirror` describes them),
/// `createLayer` from the wallpaper's own files, and every command scripts issued.
final class SceneScriptReplayObjectHost: SceneScriptObjectHost {
    let wallpaper: SceneScriptReplayWallpaper
    let scene: SceneScriptSceneDescription
    private let describer: SceneScriptSceneDescriber
    private(set) var commands: [SceneScriptObjectCommand] = []
    private(set) var created = 0
    private var nextID = SceneScriptSceneDescriber.firstCreatedID
    /// Authored JSON by object id, for `createLayer(layer)` copies.
    private var configurations: [Int: [String: SceneJSON]] = [:]
    /// What each object is, by id, for the cursor pass stand-in.
    private(set) var kinds: [Int: SceneScriptObjectDescription.Kind] = [:]
    /// Filled once the object model placed the scene: object id by slot.
    var objectIDsBySlot: [Int: Int] = [:]

    init(wallpaper: SceneScriptReplayWallpaper) throws {
        self.wallpaper = wallpaper
        let document = try wallpaper.sceneDocument()
        describer = SceneScriptSceneDescriber(userProperties: try wallpaper.sceneUserProperties(), file: wallpaper.file)
        scene = describer.scene(document)
        for (index, fields) in SceneScriptSceneDescriber.objects(of: document).enumerated() {
            configurations[SceneScriptSceneDescriber.objectID(fields, index: index)] = fields
        }
        for object in scene.objects { kinds[object.id] = object.kind }
    }

    func sceneScriptScene() -> SceneScriptSceneDescription { scene }

    func sceneScriptDescribeLayer(_ source: SceneScriptLayerSource) -> SceneScriptObjectDescription? {
        var copying: [String: SceneJSON]?
        if case .copy(let slot) = source, let id = objectIDsBySlot[slot] { copying = configurations[id] }
        guard let made = describer.layer(source, id: nextID, copying: copying) else { return nil }
        configurations[nextID] = made.json
        kinds[nextID] = made.description.kind
        nextID += 1
        created += 1
        return made.description
    }

    func sceneScriptPerform(_ command: SceneScriptObjectCommand) {
        commands.append(command)
    }

    func takeCommands() -> [SceneScriptObjectCommand] {
        defer { commands.removeAll() }
        return commands
    }
}

/// A media session the replay drives frame by frame.
final class SceneScriptReplayMediaSource: MediaSessionSource {
    private var subscribers: [Int: (MediaSessionState) -> Void] = [:]
    private var nextID = 0

    func subscribe(_ update: @escaping (MediaSessionState) -> Void) -> Int {
        nextID += 1
        subscribers[nextID] = update
        return nextID
    }

    func unsubscribe(_ id: Int) { subscribers[id] = nil }

    func send(_ state: MediaSessionState) {
        for update in subscribers.values { update(state) }
    }
}

/// Installs `Tests/Fixtures/SceneScript/replay-harness/replay.js` (property sampling and
/// determinism; see that file) after the object model, and binds sites to it.
final class SceneScriptReplaySupport: SceneScriptRuntimeExtension {
    struct InstallError: Error, CustomStringConvertible {
        var description: String
    }

    private(set) var replay: JSValue?

    func install(into runtime: SceneScriptRuntime) throws {
        let url = Fixtures.url("SceneScript/replay-harness/replay.js")
        let source = try String(contentsOf: url, encoding: .utf8)
        var failure: String?
        let previous = runtime.context.exceptionHandler
        runtime.context.exceptionHandler = { _, exception in failure = exception?.toString() }
        runtime.context.evaluateScript(source, withSourceURL: url)
        runtime.context.exceptionHandler = previous
        if let failure { throw InstallError(description: "replay.js failed: \(failure)") }
        replay = runtime.context.objectForKeyedSubscript("__replay")
    }

    func bind(scriptID: String, type: SceneScriptReplayFieldType, binding: SceneScriptObjectBinding) {
        replay?.invokeMethod("bind", withArguments: [scriptID, type.rawValue, binding.javaScriptObject])
    }

    func setClock(_ date: Date) {
        replay?.invokeMethod("setNow", withArguments: [date.timeIntervalSince1970 * 1000])
    }

    /// One value per bound site, in bind order: a number, a string, `[x, y, z]`, NSNull, or a
    /// dictionary naming a value no property type can hold.
    func sample() -> [Any] {
        replay?.invokeMethod("sample", withArguments: [])?.toArray() ?? []
    }

    /// `shared`'s numeric members.
    func sharedNumbers() -> [(String, Double)] {
        let pairs = replay?.invokeMethod("sharedNumbers", withArguments: [])?.toArray() as? [[Any]] ?? []
        return pairs.compactMap { pair in
            guard pair.count == 2, let key = pair[0] as? String, let value = pair[1] as? NSNumber else { return nil }
            return (key, value.doubleValue)
        }
    }
}

/// The script-visible type of a bound property (docs/scenescript-plan.md §4.3).
enum SceneScriptReplayFieldType: String {
    case number, bool, string, vec2, vec3, vec4, degrees

    var isNumeric: Bool { self != .string }

    /// From the field path and its authored value: layer fields by name, shader constants and
    /// `general.*` by the authored value's shape.
    init(field: String, value: Any) {
        let last = field.split(separator: ".").last.map(String.init) ?? field
        if field.hasPrefix("instanceoverride.") {
            self = last == "colorn" ? .vec3 : .number
            return
        }
        if !field.contains(".") || field.hasPrefix("effects.") && field.split(separator: ".").count == 3 {
            switch last {
            case "text", "font", "name", "horizontalalign", "verticalalign", "anchor", "alignment":
                self = .string
                return
            case "visible", "solid", "perspective", "limitrows", "limitwidth", "opaquebackground":
                self = .bool
                return
            case "origin", "scale", "color", "backgroundcolor": self = .vec3; return
            case "angles": self = .degrees; return
            case "parallaxDepth", "size": self = .vec2; return
            default: break
            }
        }
        if SceneScriptReplayWallpaper.isBool(value) {
            self = .bool
            return
        }
        switch SceneScriptReplayWallpaper.numbers(value)?.count ?? 1 {
        case 2: self = .vec2
        case 3: self = .vec3
        case 4: self = .vec4
        default: self = .number
        }
    }

    /// The initial value `init` receives when the property cannot be read live: vectors as
    /// `{x, y, z}` (a fresh `Vec` is made per call), flags as booleans.
    func initialValue(_ value: Any) -> Any {
        let numbers = SceneScriptReplayWallpaper.numbers(value) ?? []
        func component(_ index: Int) -> Float { index < numbers.count ? numbers[index] : 0 }
        switch self {
        case .string: return value as? String ?? ""
        case .bool: return (value as? NSNumber)?.boolValue ?? true
        case .number: return numbers.first ?? 0
        case .vec2: return ["x": component(0), "y": component(1)]
        case .vec3, .degrees: return ["x": component(0), "y": component(1), "z": component(2)]
        case .vec4: return ["x": component(0), "y": component(1), "z": component(2), "w": component(3)]
        }
    }
}
