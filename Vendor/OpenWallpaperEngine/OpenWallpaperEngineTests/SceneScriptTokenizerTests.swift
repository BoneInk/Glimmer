import XCTest
@testable import OpenWallpaperEngine

/// The module compiler's tokenizer: literals, comments, the regex/division ambiguity, template
/// nesting, lines and the automatic-semicolon-insertion flags.
final class SceneScriptTokenizerTests: XCTestCase {
    private func tokens(_ source: String) throws -> [SceneScriptToken] {
        try SceneScriptTokenizer.tokenize(source)
    }

    private func kinds(_ source: String) throws -> [SceneScriptToken.Kind] {
        try tokens(source).map(\.kind)
    }

    private func regexes(_ source: String) throws -> [String] {
        try tokens(source).filter { $0.kind == .regex }.map(\.text)
    }

    func testLiterals() throws {
        let scanned = try tokens(#"a = 'it\'s' + "q\"" + 0x1F + 1_000.5e-3 + .5 + 10n + `t` + #x;"#)
        XCTAssertEqual(scanned.map(\.text), ["a", "=", #"'it\'s'"#, "+", #""q\"""#, "+", "0x1F", "+", "1_000.5e-3", "+",
                                             ".5", "+", "10n", "+", "`t`", "+", "#x", ";"])
        XCTAssertEqual(scanned[2].kind, .string)
        XCTAssertEqual(scanned[8].kind, .number)
        XCTAssertEqual(scanned[14].kind, .template)
        XCTAssertEqual(scanned[16].kind, .privateName)
        XCTAssertEqual(try tokens("a?.b ?? c?.5:d").map(\.text), ["a", "?.", "b", "??", "c", "?", ".5", ":", "d"])
        XCTAssertEqual(try tokens("x >>>= 1; y **= 2; z ||= 3").filter { $0.kind == .punctuator }.map(\.text),
                       [">>>=", ";", "**=", ";", "||="])
    }

    func testCommentsAreSkipped() throws {
        XCTAssertEqual(try tokens("a // b\n/* c */ d /* e\n f */ g").map(\.text), ["a", "d", "g"])
        XCTAssertEqual(try tokens("a /* one line */ b").last?.newlineBefore, false)
        XCTAssertEqual(try tokens("a /* two\nlines */ b").last?.newlineBefore, true)
    }

    func testTemplatesNest() throws {
        let scanned = try tokens("`a${ {b: `c${d}`}.b }e${ '}' }f`")
        XCTAssertEqual(scanned.map(\.kind), [.templateHead, .punctuator, .identifier, .punctuator, .templateHead,
                                             .identifier, .templateTail, .punctuator, .punctuator, .identifier,
                                             .templateMiddle, .string, .templateTail])
        XCTAssertEqual(scanned.last?.text, "}f`")
    }

    func testRegexOrDivision() throws {
        XCTAssertEqual(try regexes("a = b / c / d"), [])
        XCTAssertEqual(try regexes("a = /b/g.test(c)"), ["/b/g"])
        XCTAssertEqual(try regexes("x = (a) / 2"), [], "a parenthesised expression is divided")
        XCTAssertEqual(try regexes("if (a) /b/.test(c)"), ["/b/"], "a control head is followed by a statement")
        XCTAssertEqual(try regexes("for await (const x of y) /z/.exec(x)"), ["/z/"])
        XCTAssertEqual(try regexes("a[0] / 2; b++ / 2"), [])
        XCTAssertEqual(try regexes("return /[/]\\//.source"), ["/[/]\\//"])
        XCTAssertEqual(try regexes("s.split(/\\s*,\\s*/)"), ["/\\s*,\\s*/"])
        XCTAssertEqual(try regexes("x = typeof /a/"), ["/a/"])
        XCTAssertEqual(try regexes("x = y.return / 2"), [], "a keyword after `.` is a property name")
        XCTAssertEqual(try regexes("{}\n/a/.test(b)"), ["/a/"], "after a block, a statement starts")
        XCTAssertEqual(try regexes("x = {} / 2"), [], "after an object literal, an operator follows")
        XCTAssertEqual(try regexes("function f() {}\n/a/.test(b)"), ["/a/"])
        XCTAssertEqual(try regexes("x = function () {} / 2"), [])
        XCTAssertEqual(try regexes("x = class {} / 2"), [])
        XCTAssertEqual(try regexes("class A {}\n/a/.test(b)"), ["/a/"])
        XCTAssertEqual(try regexes("f = () => {}\n/a/.test(b)"), ["/a/"])
        XCTAssertEqual(try regexes("x = `${a}` / 2; y = `${ /r/ }`"), ["/r/"])
        XCTAssertEqual(try regexes("a = b\n/c/g"), [], "no semicolon is inserted before `/`")
    }

    func testLinesAndLineTerminators() throws {
        let scanned = try tokens("a\nb\r\nc\rd\u{2028}e /*\n*/ f `g\nh` i")
        XCTAssertEqual(scanned.map(\.line), [1, 2, 3, 4, 5, 6, 6, 7])
        XCTAssertEqual(scanned.map(\.newlineBefore), [false, true, true, true, true, true, false, false])
        XCTAssertEqual(try tokens("'a\\\nb' c").map(\.line), [1, 2], "a line continuation inside a string counts")
    }

    func testBracketContextFlags() throws {
        let scanned = try tokens("if (a) {} f(b); x = {}; y = function () {}")
        let closers = scanned.filter { $0.isPunctuator(")") || $0.isPunctuator("}") }
        XCTAssertEqual(closers.map(\.closesControlHead), [true, false, false, false, false, false])
        XCTAssertEqual(closers.map(\.closesExpression), [false, false, false, true, false, true])
    }

    func testHashbangAndIdentifiers() throws {
        XCTAssertEqual(try tokens("#!/usr/bin/env node\nlet café = \\u0061;").map(\.text),
                       ["let", "café", "=", "\\u0061", ";"])
        XCTAssertEqual(try kinds("a.b"), [.identifier, .punctuator, .identifier])
    }

    func testStringLiteralValues() {
        XCTAssertEqual(SceneScriptStringLiteral.value(of: #"'WEMath'"#), "WEMath")
        XCTAssertEqual(SceneScriptStringLiteral.value(of: #""a\"b\\c\n\x41\u0042\u{1F600}""#), "a\"b\\c\nAB😀")
        XCTAssertEqual(SceneScriptStringLiteral.value(of: "'a\\\nb'"), "ab")
        XCTAssertEqual(SceneScriptStringLiteral.literal("a\"b\\c\nd\u{2028}😀"), #""a\"b\\c\nd\u2028😀""#)
    }
}
