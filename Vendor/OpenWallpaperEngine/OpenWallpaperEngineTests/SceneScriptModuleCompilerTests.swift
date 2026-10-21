import JavaScriptCore
import XCTest
@testable import OpenWallpaperEngine

/// WP3's module compiler (docs/scenescript-plan.md §4.2): every ES module form a SceneScript can
/// use, line preservation, the exports namespace, imports of WE's jsmodules and the rejected forms.
final class SceneScriptModuleCompilerTests: XCTestCase {
    private let compiler = SceneScriptModuleTransformer()

    /// A runtime whose prelude has WE's baseclasses.js and jsmodules, compiled by the transformer.
    private func makeRuntime(_ host: ModuleCompilerTestHost = ModuleCompilerTestHost()) throws -> SceneScriptRuntime {
        try SceneScriptRuntime(host: host, compiler: compiler)
    }

    /// Compiles `source`, evaluates the factory and calls it like the runtime does; returns the
    /// exports namespace. Throws the compile error, or the JavaScript exception as `JSFailure`.
    @discardableResult
    private func evaluate(_ source: String, in runtime: SceneScriptRuntime? = nil,
                          thisLayer: Any = "the layer", thisObject: Any = "the object") throws -> JSValue {
        let runtime = try runtime ?? makeRuntime()
        let module = try compiler.compile(source)
        let context = runtime.context
        let (factory, syntaxError) = catching(context) {
            context.evaluateScript(module.factorySource, withSourceURL: URL(string: "owe://test/module.js"))
        }
        if let syntaxError { throw JSFailure(syntaxError) }
        let scope = JSValue(newObjectIn: context)!
        scope.setValue(thisLayer, forProperty: "thisLayer")
        scope.setValue(thisObject, forProperty: "thisObject")
        scope.setValue(runtime.rt.forProperty("require"), forProperty: "require")
        let (exports, exception) = catching(context) { factory?.call(withArguments: [runtime.rt, scope]) }
        if let exception { throw JSFailure(exception) }
        return try XCTUnwrap(exports)
    }

    /// Runs `body` with an exception handler of its own (the runtime installs one that keeps the
    /// exception to itself) and returns the result and the exception it threw, if any.
    private func catching(_ context: JSContext, _ body: () -> JSValue?) -> (JSValue?, JSValue?) {
        let saved = context.exceptionHandler
        var thrown: JSValue?
        context.exceptionHandler = { _, exception in thrown = exception }
        let result = body()
        context.exceptionHandler = saved
        return (result, thrown)
    }

    /// The line of the exception `function` throws when called.
    private func thrownLine(_ function: JSValue) -> Int32? {
        catching(function.context) { function.call(withArguments: []) }.1?.forProperty("line").toInt32()
    }

    private func keys(_ namespace: JSValue) -> [String] {
        let context = namespace.context!
        return context.objectForKeyedSubscript("Object").invokeMethod("keys", withArguments: [namespace])
            .toArray().compactMap { $0 as? String }
    }

    private func assertCompileError(_ source: String, line: Int, contains text: String,
                                    file: StaticString = #filePath, fileLine: UInt = #line) {
        XCTAssertThrowsError(try compiler.compile(source), file: file, line: fileLine) { error in
            guard let error = error as? SceneScriptCompileError else {
                return XCTFail("not a compile error: \(error)", file: file, line: fileLine)
            }
            XCTAssertEqual(error.line, line, "line of \(error.message)", file: file, line: fileLine)
            XCTAssertTrue(error.message.contains(text), "\(error.message) lacks \(text)", file: file, line: fileLine)
            XCTAssertTrue(error.message.hasPrefix("SyntaxError: "), error.message, file: file, line: fileLine)
        }
    }

    // MARK: - Exports

    func testExportsEveryDeclarationForm() throws {
        let exports = try evaluate("""
            'use strict';
            export function update(value) { return value + 1; }
            export async function later() {}
            export function* frames() { yield 1; }
            export class Thing { static kind = 'thing'; #secret = 1; }
            export let counter = 1, other = 2;
            export var legacy = 'var';
            export const { a, b: [c, d = 4], ...rest } = { a: 1, b: [3], e: 5 };
            export const [first, , third = 'third'] = ['first'];
            export let scriptProperties = { flag: true };
            export var __workshopId = '123456';
            """)
        XCTAssertEqual(Set(keys(exports)), ["update", "later", "frames", "Thing", "counter", "other", "legacy", "a", "c",
                                            "d", "rest", "first", "third", "scriptProperties", "__workshopId"])
        XCTAssertEqual(exports.forProperty("update").call(withArguments: [1]).toInt32(), 2)
        XCTAssertEqual(exports.forProperty("Thing").forProperty("kind").toString(), "thing")
        XCTAssertEqual(exports.forProperty("d").toInt32(), 4)
        XCTAssertEqual(exports.forProperty("rest").forProperty("e").toInt32(), 5)
        XCTAssertEqual(exports.forProperty("third").toString(), "third")
        XCTAssertEqual(exports.forProperty("__workshopId").toString(), "123456")
        XCTAssertTrue(exports.forProperty("scriptProperties").forProperty("flag").toBool())
    }

    func testExportListsAndDefaults() throws {
        let list = try evaluate("""
            function update() { return 'u'; }
            const helper = 2;
            export {
                update,
                helper as renamed,
                helper as 'string name',
            };
            export default 40 + 2
            """)
        XCTAssertEqual(Set(keys(list)), ["update", "renamed", "string name", "default"])
        XCTAssertEqual(list.forProperty("renamed").toInt32(), 2)
        XCTAssertEqual(list.forProperty("string name").toInt32(), 2)
        XCTAssertEqual(list.forProperty("default").toInt32(), 42)

        XCTAssertEqual(try evaluate("export default function named() { return 1; }").forProperty("default")
            .call(withArguments: []).toInt32(), 1)
        XCTAssertEqual(try evaluate("export default function () { return 2; }\n(3)").forProperty("default")
            .call(withArguments: []).toInt32(), 2, "an anonymous default function stays a declaration")
        XCTAssertEqual(try evaluate("export default function* () { yield 3; }").forProperty("default")
            .call(withArguments: []).invokeMethod("next", withArguments: []).forProperty("value").toInt32(), 3)
        XCTAssertEqual(try evaluate("export default class { static v = 4; }").forProperty("default")
            .forProperty("v").toInt32(), 4)
        XCTAssertEqual(try evaluate("export default class extends Array {}").forProperty("default")
            .forProperty("name").toString(), SceneScriptModuleScanner.defaultLocal)
        XCTAssertEqual(try evaluate("export default { v: 5 };").forProperty("default").forProperty("v").toInt32(), 5)
    }

    func testExportLetStaysLive() throws {
        let exports = try evaluate("""
            export let frames = 0;
            export function update() { frames += 1; }
            """)
        exports.forProperty("update").call(withArguments: [])
        exports.forProperty("update").call(withArguments: [])
        XCTAssertEqual(exports.forProperty("frames").toInt32(), 2)
    }

    /// WE reads a module's exports: a callback that is declared but not exported is never called.
    func testOnlyExportedNamesAreVisible() throws {
        let exports = try evaluate("""
            function update() { return 1; }
            export function init() { return 2; }
            var scriptProperties = {};
            """)
        XCTAssertEqual(keys(exports), ["init"])
        XCTAssertTrue(exports.forProperty("update").isUndefined)
    }

    func testExportsAreAFrozenNamespace() throws {
        let exports = try evaluate("export let value = 1;")
        let context = exports.context!
        XCTAssertTrue(context.objectForKeyedSubscript("Object").invokeMethod("isFrozen", withArguments: [exports]).toBool())
        XCTAssertTrue(context.objectForKeyedSubscript("Object").invokeMethod("getPrototypeOf", withArguments: [exports]).isNull)
    }

    func testModuleScopeIsStrictAndPrivate() throws {
        let runtime = try makeRuntime()
        try evaluate("let topLevel = 1; var alsoTopLevel = 2; export const isStrict = (function () { return this === undefined; })();",
                     in: runtime)
        XCTAssertEqual(runtime.context.evaluateScript("typeof topLevel + typeof alsoTopLevel")?.toString(), "undefinedundefined")
        XCTAssertThrowsError(try evaluate("undeclared = 1;", in: runtime), "modules are strict")
    }

    func testThisLayerAndThisObjectComeFromTheScope() throws {
        let exports = try evaluate("export function names() { return thisLayer + '/' + thisObject; }",
                                   thisLayer: "layer 1", thisObject: "effect 2")
        XCTAssertEqual(exports.forProperty("names").call(withArguments: []).toString(), "layer 1/effect 2")
        // A module-scope declaration may shadow a global, as in a real module.
        XCTAssertEqual(try evaluate("let thisLayer = 'mine'; export const seen = thisLayer;").forProperty("seen").toString(), "mine")
    }

    // MARK: - Imports

    func testImportsWEModules() throws {
        _ = try Fixtures.assets()
        let exports = try evaluate("""
            export function update() {
                return [WEMath.mix(0, 10, 0.5), smooth(0, 1, 0.5), WEColor.normalizeColor(new Vec3(255, 0, 0)).x,
                        WEVector.vectorAngle2(new Vec2(0, 1)), deg];
            }
            import * as WEMath from 'WEMath';
            import { smoothStep as smooth, deg2rad as deg } from 'wemath';
            import * as WEColor from "WEColor";
            import * as WEVector from 'WEVector'
            import 'WEMath';
            """)
        let values = try XCTUnwrap(exports.forProperty("update").call(withArguments: []).toArray() as? [Double])
        XCTAssertEqual(values[0], 5)
        XCTAssertEqual(values[1], 0.5)
        XCTAssertEqual(values[2], 1)
        XCTAssertEqual(values[3], 90, accuracy: 1e-9)
        XCTAssertEqual(values[4], Double.pi / 180, accuracy: 1e-12)
    }

    func testMissingImportsFailWhenTheModuleIsEvaluated() throws {
        _ = try Fixtures.assets()
        XCTAssertThrowsError(try evaluate("import { nope } from 'WEMath';")) { error in
            XCTAssertTrue("\(error)".contains("The requested module 'WEMath' does not provide an export named 'nope'"),
                          "\(error)")
        }
        XCTAssertThrowsError(try evaluate("import WEMath from 'WEMath';")) { error in
            XCTAssertTrue("\(error)".contains("does not provide an export named 'default'"), "\(error)")
        }
        XCTAssertThrowsError(try evaluate("import * as Missing from 'Missing';")) { error in
            XCTAssertTrue("\(error)".contains("Cannot find module 'Missing'"), "\(error)")
        }
    }

    /// WE's jsmodules go through the same compiler; WEVector imports WEMath itself.
    func testWEJSModulesCompile() throws {
        _ = try Fixtures.assets()
        let modules = SceneScriptPrelude.load().modules
        XCTAssertEqual(Set(modules.map(\.name)), ["wemath", "wevector", "wecolor"])
        for module in modules {
            XCTAssertNoThrow(try compiler.compile(module.source), module.name)
        }
        let host = ModuleCompilerTestHost()
        let runtime = try makeRuntime(host)
        let names = runtime.context.evaluateScript("Object.keys(__rt.require('WEVector')).concat(Object.keys(__rt.require('WEMath')), Object.keys(__rt.require('WEColor'))).join(',')")
        XCTAssertEqual(names?.toString(), "angleVector2,vectorAngle2,deg2rad,mix,rad2deg,smoothStep,expandColor,hsv2rgb,normalizeColor,rgb2hsv")
        XCTAssertEqual(host.errors, [])
    }

    // MARK: - Lines

    func testLineNumbersArePreserved() throws {
        _ = try Fixtures.assets()
        let source = """
            'use strict';
            import * as WEMath
                from 'WEMath';
            export {
                fail as failure
            }
            export const text = `a
            b ${ `nested
            ${1}` } c`;
            /* a comment
               over lines */ export let x = 1 /
                2;
            export function fail() {
                throw new Error('line 14');
            }
            """
        let module = try compiler.compile(source)
        XCTAssertEqual(module.factorySource.components(separatedBy: "\n").count, source.components(separatedBy: "\n").count + 1)
        let exports = try evaluate(source)
        XCTAssertEqual(thrownLine(exports.forProperty("failure")), 14)
        XCTAssertEqual(exports.forProperty("x").toDouble(), 0.5)

        // Lines without module syntax keep their exact text; the others keep their columns.
        let sourceLines = source.components(separatedBy: "\n")
        let compiledLines = module.factorySource.components(separatedBy: "\n")
        for number in [8, 9, 10, 12, 14, 15] {
            XCTAssertEqual(compiledLines[number - 1], sourceLines[number - 1], "line \(number)")
        }
        XCTAssertEqual(compiledLines[10], "   over lines */        let x = 1 /")
        XCTAssertEqual(compiledLines[12], "       function fail() {")
    }

    func testCRLFKeepsLines() throws {
        _ = try Fixtures.assets()
        let source = "export let a = 1;\r\nexport let b = 'b';\r\nimport * as M from 'WEMath';\r\nexport function f() {\r\n  throw new Error();\r\n}"
        XCTAssertEqual(thrownLine(try evaluate(source).forProperty("f")), 5)
    }

    func testRuntimeErrorsReportTheSourceLine() throws {
        _ = try Fixtures.assets()
        let host = ModuleCompilerTestHost()
        let runtime = try makeRuntime(host)
        runtime.add(SceneScriptInstance(id: "thrower", source: """
            import * as WEMath from 'WEMath';

            export function update(value) {
                return value.missing.property;
            }
            """, initialValue: 1))
        runtime.load()
        runtime.frame(deltaTime: 1.0 / 60)
        let error = try XCTUnwrap(host.errors.first)
        XCTAssertEqual(error.kind, .runtime)
        XCTAssertEqual(error.callback, "update")
        XCTAssertEqual(error.line, 4)
    }

    // MARK: - Statement boundaries

    func testRemovedStatementsDoNotJoinTheirNeighbours() throws {
        _ = try Fixtures.assets()
        let exports = try evaluate("""
            let calls = [];
            function log(value) { calls.push(value); return log; }
            log(1)
            import * as WEMath from 'WEMath'
            (log)(2)
            log(3)
            export { calls }
            [4].forEach(log)
            """)
        XCTAssertEqual(exports.forProperty("calls").toArray() as? [Int], [1, 2, 3, 4])
        let asi = try evaluate("let calls = [];\nfunction log(v) { calls.push(v); return log; }\nlog(1)\nexport { calls }\n(2)")
        XCTAssertEqual(asi.forProperty("calls").toArray() as? [Int], [1], "`(2)` after a blanked export is its own statement")
    }

    func testHashbang() throws {
        XCTAssertEqual(try evaluate("#!/usr/bin/env node\nexport const v = 1;").forProperty("v").toInt32(), 1)
    }

    // MARK: - Tokens that look like module syntax

    func testModuleWordsInsideLiteralsAndCommentsAreLeftAlone() throws {
        let exports = try evaluate("""
            // export function hidden() {}
            /* import * as X from 'Nope'; */
            export const texts = ['export let a', "import b from 'c'", `export ${'default'} d`];
            export const pattern = /export|import\\/[/]x/g.source;
            export const object = { export: 1, import: 2, default: 3, return: 4 };
            export const methods = { import() { return 'method'; } };
            export function update() { return object.export + object.import; }
            """)
        XCTAssertEqual(Set(keys(exports)), ["texts", "pattern", "object", "methods", "update"])
        XCTAssertEqual(exports.forProperty("texts").toArray() as? [String],
                       ["export let a", "import b from 'c'", "export default d"])
        XCTAssertEqual(exports.forProperty("pattern").toString(), "export|import\\/[/]x")
        XCTAssertEqual(exports.forProperty("methods").invokeMethod("import", withArguments: []).toString(), "method")
    }

    // MARK: - Rejected forms and syntax errors

    /// 8bb9b9a54120 (3802509485): a string literal broken across two lines. V8 rejects it, so WE
    /// never runs the script and the field keeps its authored value.
    func testBrokenStringLiteralIsACompileErrorOnItsLine() {
        assertCompileError("""
            export function update(value) {
                const d = ['S U N D A Y','M O N D A Y','T U E S D A Y','W E D N E S D A Y','T
            H U R S D A Y','F R I D A Y','S A T U R D A Y'];
                return d[new Date().getDay()];
              }
            """, line: 2, contains: "Invalid or unexpected token")
    }

    func testBrokenScriptIsDisabledAndKeepsItsValue() throws {
        let host = ModuleCompilerTestHost()
        let runtime = try makeRuntime(host)
        runtime.add(SceneScriptInstance(id: "broken", source: "export function update() {\n  return 'a\n';\n}",
                                        initialValue: "authored"))
        runtime.add(SceneScriptInstance(id: "fine", source: "export function update(v) { return v + 1; }", initialValue: 1))
        runtime.load()
        runtime.frame(deltaTime: 1.0 / 60)
        XCTAssertEqual(host.errors.count, 1)
        XCTAssertEqual(host.errors.first?.kind, .compile)
        XCTAssertEqual(host.errors.first?.line, 2)
        XCTAssertEqual(runtime.value(of: "fine")?.toInt32(), 2)
        XCTAssertFalse(runtime.isEnabled("broken"))
    }

    func testUnterminatedTokens() {
        assertCompileError("let a = 1;\nlet t = `open\n\n", line: 2, contains: "Unterminated template literal")
        assertCompileError("let a = 1;\nlet t = `${ 1 `;", line: 2, contains: "Unterminated template literal")
        assertCompileError("let a = 1;\nlet r = /open\n/;", line: 2, contains: "Invalid regular expression: missing /")
        assertCompileError("let a = 1;\n/* open\n\n", line: 2, contains: "Invalid or unexpected token")
        assertCompileError("let a = \"open\\\"\n", line: 1, contains: "Invalid or unexpected token")
        assertCompileError("function f() {\n  return (1;\n}", line: 3, contains: "Unexpected token '}'")
        assertCompileError("let a = 1;\rlet b = ]", line: 2, contains: "Unexpected token ']'")
        assertCompileError("function f() {\n  return 1;\n", line: 3, contains: "Unexpected end of input")
        assertCompileError("let a = 1;\nlet b = ]", line: 2, contains: "Unexpected token ']'")
        assertCompileError("let a = 1 @@ #;", line: 1, contains: "Invalid or unexpected token")
    }

    func testRejectedModuleForms() {
        assertCompileError("export * from 'WEMath';", line: 1, contains: "re-exports")
        assertCompileError("export * as M from 'WEMath';", line: 1, contains: "re-exports")
        assertCompileError("\nexport { mix } from 'WEMath';", line: 2, contains: "re-exports")
        assertCompileError("export function update() {\n  return import('WEMath');\n}", line: 2, contains: "dynamic import()")
        assertCompileError("const url = import.meta.url;", line: 1, contains: "import.meta")
        assertCompileError("import * as J from './data.json' with { type: 'json' };", line: 1, contains: "import attributes")
        assertCompileError("let a = 1;\nreturn a;", line: 2, contains: "Illegal return statement")
        assertCompileError("export let a = 1;\nexport function a2() {}\nexport { a2 as a };", line: 3,
                           contains: "Duplicate export of 'a'")
        assertCompileError("export function () {}", line: 1, contains: "require a function name")
        assertCompileError("let x = 1\nif (x) export let y = 2;", line: 2, contains: "Unexpected token 'export'")
        assertCompileError("let x = 1 export let y = 2;", line: 1, contains: "Unexpected token 'export'")
        assertCompileError("import * as from 'WEMath';", line: 1, contains: "Unexpected token")
        assertCompileError("import { a } from 'WEMath' let b;", line: 1, contains: "Unexpected token 'let'")
        assertCompileError("export { 'x' };", line: 1, contains: "must name local bindings")
        assertCompileError("export let;", line: 1, contains: "Unexpected token ';'")
    }

    /// A nested `export` is not a module statement; JavaScriptCore reports it when the factory is
    /// evaluated, and the runtime logs that as a compile error with the line.
    func testNestedExportIsASyntaxErrorAtEvaluation() throws {
        let host = ModuleCompilerTestHost()
        let runtime = try makeRuntime(host)
        runtime.add(SceneScriptInstance(id: "nested", source: "if (true) {\n  export let a = 1;\n}"))
        runtime.load()
        XCTAssertEqual(host.errors.first?.kind, .compile)
        XCTAssertEqual(host.errors.first?.line, 2)
    }
}

/// A JavaScript exception from evaluating a compiled module in a test.
struct JSFailure: Error, CustomStringConvertible {
    var description: String

    init(_ exception: JSValue) {
        description = exception.toString() ?? "exception"
    }
}

/// A host with WE's whole prelude: baseclasses.js and the jsmodules.
final class ModuleCompilerTestHost: SceneScriptHost {
    let identity = SceneScriptIdentity(wallpaperID: "module-tests", screenID: "screen-1")
    let prelude = SceneScriptPrelude.load()
    private(set) var errors: [SceneScriptError] = []

    func runtime(_ runtime: SceneScriptRuntime, didReport error: SceneScriptError) {
        errors.append(error)
    }
}
