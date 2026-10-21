import JavaScriptCore
import XCTest
import OWESceneEditing
@testable import OpenWallpaperEngine

/// The Wallpaper Editor's scripting and user-property authoring in the app: a binding made in the
/// editor reaches the renderer's values, a script attached and applied runs in the scene, the
/// properties it writes read back as the app's sidebar reads them, and the runtime's console
/// reaches the editor.
@MainActor
final class WallpaperEditorScriptingTests: XCTestCase {
    private static let scene = Data("""
    {"camera": {"center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"},
     "general": {"orthogonalprojection": {"width": 1920, "height": 1080}},
     "objects": [{"id": 1, "name": "Image", "image": "a.json", "alpha": 0.75,
                  "effects": [{"file": "effects/blur/effect.json", "visible": true}]},
                 {"id": 2, "name": "Clock", "text": "<Clock>", "pointsize": 32}]}
    """.utf8)

    private static let image = SceneScriptObjectDescription.make(.image, id: 1, name: "Image", values: [.alpha: [0.75]])
    private static let clock = SceneScriptObjectDescription.make(.text, id: 2, name: "Clock", values: [.pointsize: [32]],
                                                                 strings: [.text: "<Clock>"])

    private func session() throws -> SceneEditSession {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        return SceneEditSession(outline: try SceneOutline(sceneData: Self.scene), undoManager: undoManager)
    }

    /// User property values for the resolver.
    private struct Values: SceneValueContext {
        let values: [String: String]
        func userProperty(_ name: String) -> String? { values[name] }
    }

    // MARK: Bindings

    func testABindingMadeInTheEditorReachesTheRenderer() throws {
        let session = try session()
        session.bind("alpha", of: 1, to: SceneUserBinding(name: "fade"), actionName: "Bind")
        session.bind(.effect(0), of: 1, to: SceneUserBinding(name: "mode", condition: "soft"), actionName: "Bind")
        let resolved = try ScenePreparation.resolvedScene(Self.scene, edits: [:], overlay: session.overlay)
        let decoded = try JSONDecoder().decode(WEScene.self, from: resolved)
        let image = try XCTUnwrap(decoded.objects.first)
        let alpha = try XCTUnwrap(image.values[.alpha])
        XCTAssertEqual(alpha.userPropertyName, "fade")
        let source = try XCTUnwrap(alpha.userBindingSource)
        XCTAssertEqual(SceneValueResolver.resolve(source, in: Values(values: ["fade": "0.25"])).float, 0.25)
        XCTAssertEqual(SceneValueResolver.resolve(source, in: Values(values: [:])).float, 0.75,
                       "a property the project doesn't declare yet falls back to the field's value")
        let effect = try XCTUnwrap(image.effects?.first)
        XCTAssertEqual(effect.visibleUserProperty, "mode")
        XCTAssertEqual(effect.visibleCondition, "soft")

        session.undo()
        session.undo()
        let reverted = try JSONDecoder().decode(WEScene.self, from: ScenePreparation.resolvedScene(
            Self.scene, edits: [:], overlay: session.overlay))
        XCTAssertNil(reverted.objects.first?.values[.alpha]?.userPropertyName)
    }

    // MARK: Scripts

    /// What the clock shows after the scene loads with `overlay` and runs a frame.
    private func clockText(_ overlay: SceneEditOverlay) throws -> String? {
        let resolved = try ScenePreparation.resolvedScene(Self.scene, edits: [:], overlay: overlay)
        let fixture = try SceneScriptBindingFixture(objects: [Self.image, Self.clock])
        try fixture.load(String(decoding: resolved, as: UTF8.self))
        fixture.frames(1)
        XCTAssertTrue(fixture.errors.isEmpty, "\(fixture.errors)")
        return fixture.evaluate("thisScene.getLayer('Clock').text")?.toString()
    }

    func testAScriptAttachedAndAppliedChangesTheText() throws {
        let session = try session()
        XCTAssertEqual(try clockText(session.overlay), "<Clock>", "no script yet")
        session.attachScript(SceneScriptAttachment(source: "export function update(value) { return 'hello'; }"),
                             to: "text", of: 2, actionName: "Add Script")
        XCTAssertEqual(try clockText(session.overlay), "hello")

        // Apply a new version: the wallpaper reloads with it and runs it from its start value.
        let before = session.overlay.digest
        session.attachScript(SceneScriptAttachment(source: "export function update(value) { return value + ' world'; }"),
                             to: "text", of: 2, actionName: "Edit Script")
        XCTAssertNotEqual(session.overlay.digest, before, "a new script changes the scene's cache key, so it reloads")
        XCTAssertEqual(try clockText(session.overlay), "<Clock> world")

        session.undo()
        XCTAssertEqual(try clockText(session.overlay), "hello")
        session.removeScript("text", of: 2, actionName: "Remove Script")
        XCTAssertEqual(try clockText(session.overlay), "<Clock>")
    }

    func testTheTextTemplatesRunInTheRuntime() throws {
        _ = try Fixtures.assets() // `createScriptProperties` is WE's baseclasses.js.
        for template in [SceneScriptTemplate.ID.clockText, .dateText] {
            let session = try session()
            session.attachScript(SceneScriptAttachment(source: SceneScriptTemplate.template(template).source),
                                 to: "text", of: 2, actionName: "Add Script")
            let text = try XCTUnwrap(try clockText(session.overlay), "\(template)")
            XCTAssertNotEqual(text, "<Clock>", "\(template) writes the text")
        }
    }

    /// Lines a listener received (on the thread that wrote them).
    private final class Received: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [SceneScriptConsoleTap.Line] = []
        func append(_ line: SceneScriptConsoleTap.Line) { lock.withLock { lines.append(line) } }
        var all: [SceneScriptConsoleTap.Line] { lock.withLock { lines } }
    }

    func testTheScriptsConsoleReachesTheEditor() throws {
        let received = Received()
        let token = SceneScriptConsoleTap.listen(to: "wp-console") { line in received.append(line) }
        defer { SceneScriptConsoleTap.stop(token) }
        let console = SceneScriptConsole(identity: SceneScriptIdentity(wallpaperID: "wp-console", screenID: "s"),
                                         sink: { _, _ in })
        console.write(.log, message: "tick", scriptID: "wp-console/Clock#2/text", time: 0)
        console.write(.error, message: "TypeError: x", scriptID: "wp-console/Clock#2/text", time: 0)
        let other = SceneScriptConsole(identity: SceneScriptIdentity(wallpaperID: "another", screenID: "s"), sink: { _, _ in })
        other.write(.log, message: "elsewhere", scriptID: "another/A#1/alpha", time: 0)
        XCTAssertEqual(received.all.map(\.message), ["tick", "TypeError: x"])
        XCTAssertEqual(received.all.map(\.isError), [false, true])

        let feed = SceneScriptConsoleFeed(wallpaperID: "wp-console")
        for line in received.all {
            feed.append(level: line.isError ? .error : .log, message: line.message, scriptID: line.scriptID, line: line.line)
        }
        XCTAssertEqual(feed.entries(of: 2, "text").count, 2)
    }

    // MARK: User properties

    func testPropertiesWrittenByTheEditorReadBackInTheApp() throws {
        var mode = UserPropertyDraft.new(.combo, key: "mode", text: "Mode")
        mode.options = [.init(label: "Day", value: "day"), .init(label: "Night", value: "night")]
        mode.value = .string("night")
        var speed = UserPropertyDraft.new(.slider, key: "speed", text: "Speed")
        speed.minimum = 0
        speed.maximum = 4
        speed.step = 0.5
        speed.decimals = 1
        speed.condition = UserPropertyConditionRule(key: "mode", value: "night").condition
        var tint = UserPropertyDraft.new(.color, key: "tint", text: "<b>Tint</b>")
        tint.value = .string("1 0 0")
        let authoring = SceneAuthoring(properties: [mode, speed, tint, .new(.bool, key: "clock", text: "Clock")])
        let project = Data(#"{"file": "scene.json", "title": "T", "type": "scene", "general": {"supportsaudioprocessing": true}}"#.utf8)
        let written = try authoring.appliedProject(to: project)

        XCTAssertNoThrow(try JSONDecoder().decode(WEProject.self, from: written), "the library still reads the project")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: written) as? [String: Any])
        XCTAssertEqual((root["general"] as? [String: Any])?["supportsaudioprocessing"] as? Bool, true)
        let definitions = UserPropertyDefinition.all(projectJSON: root).sorted { ($0.order ?? 0) < ($1.order ?? 0) }
        XCTAssertEqual(definitions.map(\.key), ["mode", "speed", "tint", "clock"])
        XCTAssertEqual(definitions.map(\.type), ["combo", "slider", "color", "bool"])
        XCTAssertEqual(definitions[0].defaultValue, "night")
        XCTAssertEqual(definitions[0].options.map(\.value), ["day", "night"])
        XCTAssertEqual(definitions[1].minimum, 0)
        XCTAssertEqual(definitions[1].maximum, 4)
        XCTAssertEqual(definitions[1].step, 0.5)
        XCTAssertEqual(definitions[1].precision, 2)
        XCTAssertEqual(definitions[2].defaultValue, "1 0 0")
        XCTAssertEqual(definitions[2].text, "<b>Tint</b>")

        // The condition reads back as written (the sidebar and the preview share one evaluator).
        let condition = UserPropertyConditionExpression(try XCTUnwrap(definitions[1].condition))
        XCTAssertTrue(condition.isUnderstood)
        XCTAssertTrue(condition.evaluate(["mode": "night"]))
        XCTAssertFalse(condition.evaluate(["mode": "day"]))
        XCTAssertFalse(condition.evaluate([:]))
    }
}
