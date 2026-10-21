import JavaScriptCore
import XCTest
@testable import OpenWallpaperEngine

/// Walks WE's typings (lib.sceneScript.d.ts): every member of the object-model interfaces has an
/// implementation on the object scripts get, or is an explicit stub that logs once.
///
/// `Tests/Fixtures/SceneScript/object-model-members.json` holds the member names so CI (without a
/// WE install) runs the walk; `testFixtureMatchesTheTypings` re-derives them from the d.ts when one
/// is present and fails when WE's typings grew.
final class SceneScriptObjectTypingsTests: XCTestCase {
    /// Interface → JS expression for an object that implements it (the scene has one layer of
    /// each kind). Interfaces an object only reaches through a stub map to nil.
    private static let implementations: [String: [String]] = [
        "IObject": ["image", "effect", "material", "thisScene"],
        "ILayer": ["image", "text", "sound", "particle", "model", "group", "camera"],
        "IImageLayer": ["image"],
        "IEffectLayer": ["image", "text"],
        "ITextLayer": ["text"],
        "ISoundLayer": ["sound"],
        "IParticleSystem": ["particle"],
        "IParticleSystemInstance": ["particle.instance"],
        "IModelLayer": ["model"],
        "ICamera": ["camera"],
        "IEffect": ["effect"],
        "IMaterial": ["material"],
        "ITextureAnimation": ["image.getTextureAnimation()"],
        "IVideoTexture": ["image.getVideoTexture()"],
        "IAnimationLayer": ["image.getAnimationLayer(0)"],
        "IAnimation": ["image.getAnimation('timeline')"],
        "IScene": ["thisScene"],
        "IModelData": ["modelData"],
    ]

    /// What `ILayer` extends (the d.ts names `IModel`, meaning `IModelLayer`).
    private static let layerParts = ["IObject", "IImageLayer", "ISoundLayer", "IEffectLayer", "ITextLayer",
                                     "IParticleSystem", "IModelLayer", "ICamera"]

    private func members() throws -> [String: [String]] {
        let data = try Fixtures.data("SceneScript/object-model-members.json")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(root["interfaces"] as? [String: [String]])
    }

    func testEveryTypedMemberIsImplementedOrAnExplicitStub() throws {
        _ = try Fixtures.assets()
        let effect = SceneScriptObjectDescription.Effect(
            name: "fx", visible: true, materials: [.init(constants: [.init(name: "alpha", value: [1])])])
        let kinds: [SceneScriptObjectDescription.Kind] = [.image, .text, .sound, .particle, .model, .group, .camera]
        let objects = kinds.enumerated().map { index, kind in
            var object = SceneScriptObjectDescription.make(
                kind, id: index + 1, name: kind.rawValue, effects: kind == .image ? [effect] : [],
                animations: kind == .image ? [.init(name: "timeline", fps: 30, frameCount: 30, duration: 1)] : [],
                textureAnimation: kind == .image ? .init(name: "", fps: 8, frameCount: 8, duration: 1) : nil)
            // The image is a puppet, so its animation layers (`IAnimationLayer`) are reachable.
            // and its texture is a video (`IVideoTexture`).
            if kind == .image { object.rig = SceneScriptRigTests.rig; object.videoDuration = 1 }
            return object
        }
        let f = try SceneScriptObjectFixture(FakeSceneScriptObjectHost(scene: SceneScriptSceneDescription(objects: objects)))
        f.evaluate("""
            var __objects = {};
            thisScene.enumerateLayers().forEach(function (layer) { __objects[layer.name] = layer; });
            var effect = __objects.image.getEffect(0), material = effect.getMaterial(0);
            var image = __objects.image, text = __objects.text, sound = __objects.sound, particle = __objects.particle,
                model = __objects.model, group = __objects.group, camera = __objects.camera;
            var modelData = thisScene.createModelData({ shapes: [{ vertexBuffer: new Float32Array(9),
                vertexFormat: [IModelData.POSITION], material: 'materials/model.json' }] });
            var __requiresArgument = { createModelData: 'Shapes missing.' };
            function __check(target, member) {
                if (target === null || target === undefined) return 'no object';
                if (!(member in target)) return 'missing';
                try {
                    var value = target[member];
                    if (typeof value === 'function') value.call(target);
                } catch (error) {
                    // A member that needs its argument throws WE's own message without one.
                    if (__requiresArgument[member] === error.message) return 'ok';
                    return 'throws ' + error;
                }
                return 'ok';
            }
            """)
        var failures: [String] = []
        let typed = try members()
        for (interface, own) in typed {
            // `ILayer extends IObject, IImageLayer, ISoundLayer, …`: every layer has the whole union.
            let names = interface == "ILayer" ? Self.layerParts.flatMap { typed[$0] ?? [] } + own : own
            guard let targets = Self.implementations[interface] else {
                failures.append("\(interface): no implementation mapped")
                continue
            }
            for target in targets {
                for member in names {
                    let result = f.evaluate("__check(\(target), '\(member)')")?.toString() ?? "nil"
                    if result != "ok" { failures.append("\(interface).\(member) on \(target): \(result)") }
                }
            }
        }
        XCTAssertEqual(failures.sorted(), [])
        XCTAssertTrue(f.scriptHost.errors.isEmpty, "\(f.scriptHost.errors)")
    }

    func testFixtureMatchesTheTypings() throws {
        let candidates = [URL(fileURLWithPath: "/Volumes/980Pro/dd-scenescript/spec/lib.sceneScript.d.ts")]
            + WallpaperEngineAssets.searchDirectories.map {
                $0.deletingLastPathComponent().appending(path: "ui/dist/monaco/autocomplete/lib.sceneScript.d.ts")
            }
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw XCTSkip("WE's lib.sceneScript.d.ts is not present")
        }
        let parsed = Self.interfaceMembers(in: try String(contentsOf: url, encoding: .utf8))
        let fixture = try members()
        for (interface, names) in fixture {
            XCTAssertEqual(parsed[interface], names, "\(interface) in \(url.path)")
        }
    }

    /// Member names per interface: comments stripped, then every `name(`, `name:` or `name?:` at the
    /// start of a line of the interface body.
    static func interfaceMembers(in source: String) -> [String: [String]] {
        var text = source.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"//[^\n]*"#, with: "", options: .regularExpression)
        let header = try! NSRegularExpression(pattern: #"interface\s+(\w+)(?:\s+extends\s+[^{]+)?\s*\{"#)
        let member = try! NSRegularExpression(pattern: #"^\s*(?:static\s+)?(?:readonly\s+)?([A-Za-z_]\w*)\s*\??\s*[(:]"#,
                                              options: .anchorsMatchLines)
        let ns = text as NSString
        var result: [String: [String]] = [:]
        for match in header.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: match.range(at: 1))
            var depth = 1
            var end = match.range.location + match.range.length
            while depth > 0 && end < ns.length {
                let character = ns.character(at: end)
                if character == UInt16(UInt8(ascii: "{")) { depth += 1 }
                if character == UInt16(UInt8(ascii: "}")) { depth -= 1 }
                end += 1
            }
            let bodyStart = match.range.location + match.range.length
            let body = ns.substring(with: NSRange(location: bodyStart, length: max(0, end - 1 - bodyStart)))
            let names = member.matches(in: body, range: NSRange(location: 0, length: (body as NSString).length))
                .map { (body as NSString).substring(with: $0.range(at: 1)) }
            result[name] = Array(Set(names)).sorted()
        }
        return result
    }
}
