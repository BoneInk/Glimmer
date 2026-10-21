import Foundation
import JavaScriptCore
@testable import OpenWallpaperEngine

/// A renderer stand-in for the object model: a fixed scene, `createLayer` descriptions from a
/// closure, and every command it was asked to perform.
final class FakeSceneScriptObjectHost: SceneScriptObjectHost {
    var scene: SceneScriptSceneDescription
    var describe: (SceneScriptLayerSource) -> SceneScriptObjectDescription?
    private(set) var described: [SceneScriptLayerSource] = []
    private(set) var commands: [SceneScriptObjectCommand] = []

    init(scene: SceneScriptSceneDescription,
         describe: @escaping (SceneScriptLayerSource) -> SceneScriptObjectDescription? = { _ in nil }) {
        self.scene = scene
        self.describe = describe
    }

    func sceneScriptScene() -> SceneScriptSceneDescription { scene }

    func sceneScriptDescribeLayer(_ source: SceneScriptLayerSource) -> SceneScriptObjectDescription? {
        described.append(source)
        return describe(source)
    }

    func sceneScriptPerform(_ command: SceneScriptObjectCommand) {
        commands.append(command)
    }

    func takeCommands() -> [SceneScriptObjectCommand] {
        defer { commands.removeAll() }
        return commands
    }
}

/// A runtime with the object model over `host`'s scene.
struct SceneScriptObjectFixture {
    let host: FakeSceneScriptObjectHost
    let scriptHost: TestSceneScriptHost
    let model: SceneScriptObjectModel
    let runtime: SceneScriptRuntime

    init(_ host: FakeSceneScriptObjectHost, capacity: SceneScriptObjectStore.Capacity = .standard) throws {
        self.host = host
        scriptHost = TestSceneScriptHost()
        model = SceneScriptObjectModel(host: host, capacity: capacity)
        runtime = try SceneScriptRuntime(host: scriptHost, compiler: TestSceneScriptCompiler(), extensions: [model])
    }

    var store: SceneScriptObjectStore { model.store! }

    @discardableResult
    func evaluate(_ script: String) -> JSValue? {
        runtime.context.evaluateScript(script)
    }

    func add(_ id: String, slot: Int?, binding: SceneScriptObjectBinding? = nil, initialValue: Any = NSNull(),
             _ source: String) {
        if let binding { model.bind(scriptID: id, to: binding) }
        runtime.add(SceneScriptInstance(id: id, source: source, initialValue: initialValue, objectSlot: slot))
    }

    func table(_ slot: Int, _ field: SceneScriptObjectField) -> [Float] { store.table[slot, field] }
}

extension SceneScriptObjectDescription {
    /// An object for tests, with values in table units.
    static func make(_ kind: Kind, id: Int, name: String, parentID: Int? = nil,
                     values: [SceneScriptObjectField: [Float]] = [:],
                     strings: [SceneScriptStringField: String] = [:],
                     effects: [Effect] = [], animations: [SceneScriptAnimationDescription] = [],
                     textureAnimation: SceneScriptAnimationDescription? = nil,
                     config: String? = nil) -> SceneScriptObjectDescription {
        var description = SceneScriptObjectDescription(kind: kind, id: id, name: name, parentID: parentID)
        description.values = values
        description.strings = strings
        description.effects = effects
        description.animations = animations
        description.textureAnimation = textureAnimation
        description.initialConfigurationJSON = config
        return description
    }
}
