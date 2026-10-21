import Foundation
import JavaScriptCore
import XCTest
@testable import OpenWallpaperEngine

/// A runtime the way a wallpaper builds it for property binding (docs/scenescript-plan.md WP8):
/// WE's prelude with its jsmodules, the module compiler, the engine, object model and binding
/// extensions, and the sites `SceneScriptSiteBuilder` finds in a scene.json text.
final class SceneScriptBindingFixture {
    let objectHost: FakeSceneScriptObjectHost
    let scriptHost: SceneScriptBindingTestHost
    let model: SceneScriptObjectModel
    let binding = SceneScriptBindingExtension()
    let engine: SceneScriptEngineExtension
    let runtime: SceneScriptRuntime
    /// What `registerAudioBuffers` arrays hold from the next frame on.
    let audio: SceneScriptBindingAudio
    private let storageDirectory: URL
    private(set) var sites: [SceneScriptSite] = []

    init(objects: [SceneScriptObjectDescription], settings: [SceneScriptSceneField: [Float]] = [:],
         now: @escaping () -> Date = Date.init) throws {
        objectHost = FakeSceneScriptObjectHost(scene: SceneScriptSceneDescription(objects: objects, settings: settings))
        scriptHost = SceneScriptBindingTestHost()
        model = SceneScriptObjectModel(host: objectHost)
        storageDirectory = FileManager.default.temporaryDirectory
            .appending(path: "owe-binding-storage-\(UUID().uuidString)", directoryHint: .isDirectory)
        engine = SceneScriptEngineExtension(storage: SceneScriptStorage(directory: storageDirectory),
                                            now: now, consoleSink: { _, _ in })
        let audio = SceneScriptBindingAudio()
        self.audio = audio
        let buffers = SceneScriptAudioBuffersExtension(spectrum: { audio.spectrum })
        runtime = try SceneScriptRuntime(host: scriptHost, compiler: SceneScriptModuleTransformer(),
                                         extensions: [engine, buffers, model, binding])
    }

    deinit {
        runtime.tearDown()
        do {
            if FileManager.default.fileExists(atPath: storageDirectory.path) {
                try FileManager.default.removeItem(at: storageDirectory)
            }
        } catch {
            XCTFail("removing \(storageDirectory.path) failed: \(error)")
        }
    }

    /// Builds the sites of `sceneJSON`, adds them and loads.
    func load(_ sceneJSON: String, userProperties: SceneScriptUserProperties = SceneScriptUserProperties(),
              file: StaticString = #filePath, line: UInt = #line) throws {
        let document = try SceneScriptSiteBuilder.document(from: Data(sceneJSON.utf8))
        let builder = SceneScriptSiteBuilder(wallpaperID: "wp", userProperties: userProperties,
                                             slot: { [model] in model.slot(forObjectID: $0) })
        sites = builder.sites(in: document)
        binding.add(sites, to: runtime)
        runtime.load(userProperties: userProperties.payload())
    }

    func frames(_ count: Int, deltaTime: Double = 1.0 / 60) {
        for _ in 0..<count { runtime.frame(deltaTime: deltaTime) }
    }

    /// The id of the site at `path` of the object named `object` (nil: a scene site).
    func id(_ object: String?, _ path: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        let prefix = object.map { "wp/\($0)#" } ?? "wp/scene/"
        let site = sites.first { $0.instance.id.hasPrefix(prefix) && $0.property.path == path }
        XCTAssertNotNil(site, "no site \(object ?? "scene") \(path)", file: file, line: line)
        return site?.instance.id ?? ""
    }

    /// The value a script last applied (`record.value`).
    func value(_ object: String?, _ path: String) -> JSValue? {
        runtime.value(of: id(object, path))
    }

    func table(_ slot: Int, _ field: SceneScriptObjectField) -> [Float] { model.store!.table[slot, field] }

    @discardableResult
    func evaluate(_ script: String) -> JSValue? { runtime.context.evaluateScript(script) }

    var errors: [SceneScriptError] { scriptHost.errors }
}

/// The spectrum a fixture's audio buffers hold: silence, or every band at `level`.
final class SceneScriptBindingAudio {
    var spectrum = AudioSpectrumSnapshot.silent

    func set(level: Float) {
        let bands = { (count: Int) in [Float](repeating: level, count: count) }
        spectrum = AudioSpectrumSnapshot(left16: bands(16), right16: bands(16), left32: bands(32), right32: bands(32),
                                         left64: bands(64), right64: bands(64), average16: bands(16),
                                         average32: bands(32), average64: bands(64))
    }
}

/// WE's whole prelude (jsmodules too, for `import * as WEMath`), and every reported error.
final class SceneScriptBindingTestHost: SceneScriptHost {
    let identity = SceneScriptIdentity(wallpaperID: "wp", screenID: "screen-1")
    let prelude = SceneScriptPrelude.load()
    private(set) var errors: [SceneScriptError] = []

    func runtime(_ runtime: SceneScriptRuntime, didReport error: SceneScriptError) {
        errors.append(error)
    }
}

extension SceneScriptUserProperties {
    /// From project.json `general.properties` text.
    static func parsing(_ json: String) throws -> SceneScriptUserProperties {
        SceneScriptUserProperties(definitions: try decodeTolerant(SceneJSON.self, from: Data(json.utf8)))
    }
}
