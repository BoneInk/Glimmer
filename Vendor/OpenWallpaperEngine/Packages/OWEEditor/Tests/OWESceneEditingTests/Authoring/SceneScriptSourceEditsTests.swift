import XCTest
@testable import OWESceneEditing

/// The script editor's Snippets and Edit menus on a script's text, as WE's editor makes them:
/// Insert Function, Insert Property, Import Base Module, Replace Script, Format Document and
/// Comment / Uncomment Selection.
final class SceneScriptSourceEditsTests: XCTestCase {
    private let script = """
        'use strict';

        import * as WEMath from 'WEMath';

        export function update(value) {
        \treturn value;
        }
        """

    // MARK: Insert Function

    func testInsertFunctionAppendsOnceWithItsDocs() {
        let added = SceneScriptSourceEdits.inserting(.cursorClick, into: script)
        XCTAssertTrue(added.hasSuffix("/**\n * @param {CursorEvent} event\n */\nexport function cursorClick(event) {\n\t\n}\n"))
        XCTAssertEqual(SceneScriptSourceEdits.inserting(.cursorClick, into: added), added, "already exported")
        XCTAssertEqual(SceneScriptSourceEdits.inserting(.update, into: script), script)
        XCTAssertTrue(SceneScriptSourceEdits.inserting(.initialize, into: script, valueType: "Vec3")
            .contains("@param {Vec3} value - the field's value"))
        XCTAssertFalse(SceneScriptSourceEdits.exports("init", in: "// export function init(v) {}\nconst s = 'export function init(';"),
                       "a comment or a string isn't an export")
        XCTAssertEqual(SceneScriptSourceEdits.Callback.groups.flatMap { $0 }.count, SceneScriptSourceEdits.Callback.allCases.count)
    }

    // MARK: Insert Property

    func testInsertPropertyStartsAChainAfterTheHeader() {
        let added = SceneScriptSourceEdits.inserting(.slider, into: script)
        XCTAssertTrue(added.hasPrefix("""
            'use strict';

            import * as WEMath from 'WEMath';

            export var scriptProperties = createScriptProperties()
            \t.addSlider({ name: 'newSlider', label: 'New Slider', value: 0.5, min: 0, max: 1, integer: false })
            \t.finish();

            export function update
            """), added)
        let declarations = SceneScriptPropertyDeclaration.declarations(in: added)
        XCTAssertEqual(declarations.map(\.name), ["newSlider"])
        XCTAssertEqual(SceneScriptSyntaxCheck.diagnostics(of: added), [])
    }

    func testInsertPropertyJoinsTheChainWithAUniqueName() {
        var text = SceneScriptSourceEdits.inserting(.slider, into: script)
        text = SceneScriptSourceEdits.inserting(.slider, into: text)
        for kind in SceneScriptSourceEdits.PropertyKind.allCases where kind != .slider {
            text = SceneScriptSourceEdits.inserting(kind, into: text)
        }
        let declarations = SceneScriptPropertyDeclaration.declarations(in: text)
        XCTAssertEqual(declarations.map(\.name), ["newSlider", "newSlider2", "newCheckbox", "newText", "newColor", "newCombo"])
        XCTAssertEqual(declarations.map(\.kind), [.slider, .slider, .checkbox, .text, .color, .combo])
        XCTAssertEqual(text.components(separatedBy: "createScriptProperties()").count, 2, "one chain")
        XCTAssertEqual(SceneScriptSyntaxCheck.diagnostics(of: text), [])
    }

    func testInsertPropertyIntoAScriptWithoutHeader() {
        let added = SceneScriptSourceEdits.inserting(.checkbox, into: "export function update(v) { return v; }")
        XCTAssertTrue(added.hasPrefix("\nexport var scriptProperties = createScriptProperties()\n\t.addCheckbox("), added)
        XCTAssertEqual(SceneScriptSyntaxCheck.diagnostics(of: added), [])
    }

    // MARK: Import Base Module

    func testImportGoesAfterTheImportsOrUseStrict() {
        let both = SceneScriptSourceEdits.importing("WEColor", into: script)
        XCTAssertTrue(both.contains("import * as WEMath from 'WEMath';\nimport * as WEColor from 'WEColor';\n"))
        XCTAssertEqual(SceneScriptSourceEdits.importing("WEMath", into: script), script, "imported already")
        let strict = SceneScriptSourceEdits.importing("WEVector", into: "'use strict';\n\nexport function update(v) { return v; }")
        XCTAssertTrue(strict.hasPrefix("'use strict';\n\nimport * as WEVector from 'WEVector';\n"), strict)
        let bare = SceneScriptSourceEdits.importing("WEVector", into: "export function update(v) { return v; }")
        XCTAssertTrue(bare.hasPrefix("import * as WEVector from 'WEVector';\n\n"), bare)
    }

    // MARK: Replace Script

    func testSnippetsPreferWEsOwnFile() {
        let rainbow = SceneScriptSnippet.snippet(.rainbowColor)
        XCTAssertEqual(rainbow.weFile, "script_vec3_color_rainbow")
        XCTAssertEqual(rainbow.resolvedSource { $0 == "script_vec3_color_rainbow" ? "// WE's" : nil }, "// WE's")
        XCTAssertEqual(rainbow.resolvedSource { _ in nil }, rainbow.source, "this project's script without WE's")
        XCTAssertEqual(rainbow.resolvedSource { _ in "  \n" }, rainbow.source, "an empty file doesn't count")
        let wiggle = SceneScriptSnippet.snippet(.clickWiggle)
        XCTAssertNil(wiggle.weFile, "WE 2.8.42 ships no Click Wiggle")
        XCTAssertEqual(wiggle.resolvedSource { _ in "x" }, wiggle.source)
        XCTAssertEqual(SceneScriptSnippet.all.map(\.id), SceneScriptSnippet.ID.allCases)
        for snippet in SceneScriptSnippet.all {
            XCTAssertEqual(SceneScriptSyntaxCheck.diagnostics(of: snippet.source), [], "\(snippet.id)")
        }
    }

    // MARK: Format Document

    func testFormatReindentsByBrackets() {
        let messy = """
            'use strict';
            export var scriptProperties = createScriptProperties()
            .addSlider({
            name: 'speed',
                  value: 1
            })
              .finish();



            export function update(value) {
            if (value > 1) {
            return value; // keep }
            }
                    const s = '{ not a block';
            return value;
            }
            """
        XCTAssertEqual(SceneScriptSourceEdits.formatted(messy), """
            'use strict';
            export var scriptProperties = createScriptProperties()
            \t.addSlider({
            \t\tname: 'speed',
            \t\tvalue: 1
            \t})
            \t.finish();

            export function update(value) {
            \tif (value > 1) {
            \t\treturn value; // keep }
            \t}
            \tconst s = '{ not a block';
            \treturn value;
            }
            """)
    }

    func testFormatLeavesTemplateAndCommentLinesAlone() {
        let text = "export function update(v) {\nconst t = `line\n   kept`;\n/*\n   kept too\n*/\nreturn v;\n}"
        XCTAssertEqual(SceneScriptSourceEdits.formatted(text),
                       "export function update(v) {\n\tconst t = `line\n   kept`;\n\t/*\n   kept too\n*/\n\treturn v;\n}")
        for snippet in SceneScriptSnippet.all {
            XCTAssertEqual(SceneScriptSourceEdits.formatted(snippet.source), snippet.source.trimmingTrailingNewlines + "\n",
                           "\(snippet.id) is formatted already")
        }
    }

    // MARK: Comment Selection

    func testCommentAndUncommentTheSelectedLines() {
        let text = "a();\n\tb();\n\t\tc();\nd();"
        let second = (text as NSString).range(of: "b();")
        let third = (text as NSString).range(of: "c")
        let selection = NSRange(location: second.location, length: NSMaxRange(third) - second.location)
        let commented = SceneScriptSourceEdits.commenting(text, selection: selection)
        XCTAssertEqual(commented.text, "a();\n\t// b();\n\t// \tc();\nd();")
        XCTAssertEqual((commented.text as NSString).substring(with: commented.selection), "\t// b();\n\t// \tc();")
        let back = SceneScriptSourceEdits.uncommenting(commented.text, selection: commented.selection)
        XCTAssertEqual(back.text, text)
        // A caret comments its line; a selection ending at a line's start leaves that line.
        XCTAssertEqual(SceneScriptSourceEdits.commenting(text, selection: NSRange(location: 1, length: 0)).text,
                       "// a();\n\tb();\n\t\tc();\nd();")
        XCTAssertEqual(SceneScriptSourceEdits.commenting(text, selection: NSRange(location: 0, length: 5)).text,
                       "// a();\n\tb();\n\t\tc();\nd();")
        XCTAssertEqual(SceneScriptSourceEdits.uncommenting("x();", selection: NSRange(location: 0, length: 0)).text, "x();")
    }
}

private extension String {
    var trimmingTrailingNewlines: String {
        var text = self
        while text.hasSuffix("\n") { text.removeLast() }
        return text
    }
}
