import XCTest
@testable import OWESceneEditing

/// The script editor's tools on a script's source: highlighting tokens, the syntax check before
/// Apply, the properties a script declares, the templates, and the console's script ids.
@MainActor
final class SceneScriptSourceToolsTests: XCTestCase {
    private func kinds(_ source: String) -> [(String, JavaScriptToken.Kind)] {
        JavaScriptTokenizer.tokens(in: source).map { ((source as NSString).substring(with: $0.range), $0.kind) }
    }

    // MARK: Tokens

    func testTokensCoverCodeCommentsStringsAndAPI() {
        let tokens = kinds("export function update(v) { // tick\n\treturn thisLayer.alpha * 0.5 + 'a\\'b'; }")
        XCTAssertTrue(tokens.contains { $0 == ("export", .keyword) })
        XCTAssertTrue(tokens.contains { $0 == ("// tick", .lineComment) })
        XCTAssertTrue(tokens.contains { $0 == ("thisLayer", .api) })
        XCTAssertTrue(tokens.contains { $0 == ("alpha", .identifier) }, "a member isn't a keyword or a global")
        XCTAssertTrue(tokens.contains { $0 == ("0.5", .number) })
        XCTAssertTrue(tokens.contains { $0 == ("'a\\'b'", .string) })
    }

    func testRegexesTemplatesAndDivision() {
        XCTAssertTrue(kinds("const r = /a\\/b[/]/g;").contains { $0 == ("/a\\/b[/]/g", .regex) })
        XCTAssertFalse(kinds("x = a / b / c;").contains { $0.1 == .regex }, "division after an operand")
        XCTAssertTrue(kinds("let t = `x ${y}`;").contains { $0 == ("`x ${y}`", .template) })
        XCTAssertTrue(kinds("/* a\n b */x").contains { $0 == ("/* a\n b */", .blockComment) })
    }

    func testTokensNeverLoseText() {
        let sources = ["", "'unterminated", "/* open", "`open", "a.b.c(", "1e-5 + .5", "\u{1F600} = 1", "x = /re"]
        for source in sources {
            let tokens = JavaScriptTokenizer.tokens(in: source)
            let length = (source as NSString).length
            XCTAssertTrue(tokens.allSatisfy { NSMaxRange($0.range) <= length }, source)
            XCTAssertTrue(zip(tokens, tokens.dropFirst()).allSatisfy { NSMaxRange($0.range) <= $1.range.location }, source)
        }
    }

    // MARK: Syntax

    func testAModuleScriptPassesTheSyntaxCheck() {
        let source = """
            'use strict';
            import * as WEMath from 'WEMath';
            import { mix } from 'WEMath';
            export var scriptProperties = createScriptProperties().addSlider({ name: 's', value: 1 }).finish();
            export function update(value) { return WEMath.mix(value, 1, 0.5); }
            export { scriptProperties as props };
            export default function helper() {}
            """
        XCTAssertEqual(SceneScriptSyntaxCheck.diagnostics(of: source), [])
    }

    func testASyntaxErrorIsReportedAtItsLine() throws {
        let source = "export function update(value) {\n\treturn value +;\n}\n"
        let diagnostic = try XCTUnwrap(SceneScriptSyntaxCheck.diagnostics(of: source).first)
        XCTAssertEqual(diagnostic.line, 2)
        XCTAssertTrue(diagnostic.message.contains("SyntaxError"), diagnostic.message)
    }

    func testBlankingKeepsEveryLineAndColumn() {
        let source = "import * as A from 'WEMath';\nexport function f() {}\nexport default 1;\n"
        let classic = SceneScriptSyntaxCheck.classicScript(fromModule: source)
        XCTAssertEqual((classic as NSString).length, (source as NSString).length)
        XCTAssertEqual(classic.split(separator: "\n", omittingEmptySubsequences: false).count,
                       source.split(separator: "\n", omittingEmptySubsequences: false).count)
        XCTAssertFalse(classic.contains("import"))
        XCTAssertTrue(classic.contains("function f() {}"))
    }

    func testEveryTemplateIsValid() {
        for template in SceneScriptTemplate.all {
            XCTAssertEqual(SceneScriptSyntaxCheck.diagnostics(of: template.source), [], "\(template.id)")
        }
        XCTAssertEqual(SceneScriptTemplate.templates(for: "text").map(\.id), [.empty, .clockText, .dateText])
        XCTAssertEqual(SceneScriptTemplate.templates(for: "scale").map(\.id), [.empty, .audioScale])
        XCTAssertEqual(SceneScriptTemplate.templates(for: "origin").map(\.id), [.empty, .cursorFollow])
        XCTAssertEqual(SceneScriptTemplate.templates(for: "visible").map(\.id), [.empty, .objectScript])
    }

    // MARK: Script properties

    func testDeclaredScriptPropertiesAreRead() throws {
        let declarations = SceneScriptPropertyDeclaration.declarations(in: SceneScriptTemplate.template(.clockText).source)
        XCTAssertEqual(declarations.map(\.name), ["use24h", "showSeconds"])
        XCTAssertEqual(declarations.first?.kind, .checkbox)
        XCTAssertEqual(declarations.first?.label, "24-hour clock")
        XCTAssertEqual(declarations.first?.value, .bool(true))

        let source = """
            export var scriptProperties = createScriptProperties()
                .addSlider({ name: "speed", label: 'Speed', value: -0.5, min: -1, max: 1, integer: false, })
                .addCombo({ name: 'mode', label: 'Mode', options: [{ label: 'A', value: 1 }, { label: 'B', value: 2 }] })
                .addColor({ name: 'tint', label: 'Tint', value: '1 0 0' })
                .addText({ name: 'caption', label: 'Caption', value: 'it\\'s' })
                .addSlider({ name: 'computed', value: Math.PI }) // not a literal: skipped
                .finish();
            """
        let read = SceneScriptPropertyDeclaration.declarations(in: source)
        XCTAssertEqual(read.map(\.name), ["speed", "mode", "tint", "caption"])
        let speed = try XCTUnwrap(read.first)
        XCTAssertEqual(speed.value, .number(-0.5))
        XCTAssertEqual(speed.minimum, -1)
        XCTAssertEqual(speed.maximum, 1)
        XCTAssertFalse(speed.isInteger)
        XCTAssertEqual(read[1].kind, .combo)
        XCTAssertEqual(read[1].value, .number(1), "a combo starts at its first option, as WE's does")
        XCTAssertEqual(read[1].options.map(\.label), ["A", "B"])
        XCTAssertEqual(read[2].value, .string("1 0 0"))
        XCTAssertEqual(read[3].value, .string("it's"))
    }

    // MARK: Console

    func testConsoleEntriesNameTheirLayerAndField() {
        XCTAssertEqual(SceneScriptConsoleEntry.site(of: "123/Clock#11/text", wallpaperID: "123")?.layerID, 11)
        XCTAssertEqual(SceneScriptConsoleEntry.site(of: "123/Clock#11/text", wallpaperID: "123")?.path, "text")
        XCTAssertEqual(SceneScriptConsoleEntry.site(of: "123/#i2/effects.0.visible~2", wallpaperID: "123")?.layerID, 2)
        XCTAssertEqual(SceneScriptConsoleEntry.site(of: "123/#i2/effects.0.visible~2", wallpaperID: "123")?.path, .effect(0))
        XCTAssertEqual(SceneScriptConsoleEntry.site(of: "123/a/b#5/origin", wallpaperID: "123")?.layerID, 5,
                       "a name with a slash")
        XCTAssertNil(SceneScriptConsoleEntry.site(of: "123/scene/general.bloom", wallpaperID: "123")?.layerID)
        XCTAssertNil(SceneScriptConsoleEntry.site(of: "999/Clock#11/text", wallpaperID: "123"))
    }

    func testTheConsoleKeepsTheLatestErrorPerLine() {
        let feed = SceneScriptConsoleFeed(wallpaperID: "wp")
        feed.append(level: .log, message: "tick", scriptID: "wp/Clock#11/text", line: nil)
        feed.append(level: .error, message: "TypeError: a", scriptID: "wp/Clock#11/text", line: 3)
        feed.append(level: .error, message: "TypeError: b", scriptID: "wp/Clock#11/text", line: 3)
        feed.append(level: .error, message: "elsewhere", scriptID: "wp/Logo#13/alpha", line: 1)
        XCTAssertEqual(feed.entries(of: 11, "text").count, 3)
        XCTAssertEqual(feed.diagnostics(of: 11, "text"), [SceneScriptDiagnostic(line: 3, message: "TypeError: b")])
        XCTAssertTrue(feed.diagnostics(of: 11, "text", since: Date.distantFuture).isEmpty)
        for index in 0..<SceneScriptConsoleFeed.limit { feed.append(level: .log, message: "\(index)", scriptID: "", line: nil) }
        XCTAssertEqual(feed.entries.count, SceneScriptConsoleFeed.limit)
        feed.clear()
        XCTAssertTrue(feed.entries.isEmpty)
    }

    // MARK: Apply

    /// Attaching a script and applying a new version of it changes what the scene runs, in one
    /// undo step each; the next load of the scene runs the new text.
    func testAttachAndApplyChangeTheTextScriptTheSceneRuns() throws {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        let session = SceneEditSession(outline: try SceneOutline(sceneData: Fixtures.sceneData), undoManager: undoManager)
        func runningScript() throws -> String? {
            let applied = try session.overlay.applied(to: Fixtures.sceneData)
            return (try Fixtures.object(11, in: applied)["text"] as? [String: Any])?["script"] as? String
        }
        let clock = SceneScriptTemplate.template(.clockText).source
        session.attachScript(SceneScriptAttachment(source: clock), to: "text", of: 11, actionName: "Edit Script")
        XCTAssertEqual(try runningScript(), clock)
        let hello = "export function update(value) { return 'hello'; }"
        session.attachScript(SceneScriptAttachment(source: hello), to: "text", of: 11, actionName: "Edit Script")
        XCTAssertEqual(try runningScript(), hello)
        session.undo()
        XCTAssertEqual(try runningScript(), clock)
    }
}
