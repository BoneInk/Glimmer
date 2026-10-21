import XCTest
import OWESceneEditing
@testable import OpenWallpaperEngine

/// The script editor's snippets (Snippets › Replace Script) run in the app's SceneScript runtime
/// on the field each is written for, with WE's prelude (WEColor for Rainbow Color), and raise no
/// error over half a second of frames.
final class WallpaperEditorScriptSnippetTests: XCTestCase {
    private static let image = SceneScriptObjectDescription.make(
        .image, id: 1, name: "Image",
        values: [.alpha: [1], .origin: [400, 300, 0], .scale: [1, 1, 1], .angles: [0, 0, 0], .color: [1, 1, 1],
                 .size: [100, 100]])
    private static let sound = SceneScriptObjectDescription.make(.sound, id: 2, name: "Sound")

    /// The field a snippet goes on, and the value it starts from (scene.json form).
    private static func field(_ field: SceneScriptSnippet.Field) -> (name: String, value: String) {
        switch field {
        case .color: return ("color", "\"1 1 1\"")
        case .number: return ("alpha", "1")
        case .origin: return ("origin", "\"400 300 0\"")
        case .angles: return ("angles", "\"0 0 0\"")
        case .layer: return ("visible", "true")
        }
    }

    func testEverySnippetRunsWithoutErrors() throws {
        _ = try Fixtures.assets()
        for snippet in SceneScriptSnippet.all {
            let f = try SceneScriptBindingFixture(objects: [Self.image, Self.sound])
            let (name, value) = Self.field(snippet.field)
            let scene = "{\"objects\": [{\"id\": 1, \"name\": \"Image\", \"size\": \"100 100\", "
                + "\"\(name)\": {\"script\": \(SceneScriptBindingTests.literal(snippet.source)), \"value\": \(value)}}, "
                + "{\"id\": 2, \"name\": \"Sound\", \"sound\": [\"sounds/a.mp3\"]}]}"
            try f.load(scene)
            f.frames(30)
            XCTAssertTrue(f.errors.isEmpty, "\(snippet.id): \(f.errors)")
        }
    }

    func testTheSnippetsSyntaxIsValid() {
        for snippet in SceneScriptSnippet.all {
            XCTAssertEqual(SceneScriptSyntaxCheck.diagnostics(of: snippet.source), [], "\(snippet.id)")
        }
    }
}
