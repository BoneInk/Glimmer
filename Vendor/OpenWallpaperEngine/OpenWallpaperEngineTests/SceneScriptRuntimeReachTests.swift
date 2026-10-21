import JavaScriptCore
import XCTest
@testable import OpenWallpaperEngine

/// The runtime findings still open after the hardening (docs/test-risks.md): S11, a command a
/// handler pushes while the ring drains, and S28, scripts reaching `__rt`.
final class SceneScriptRuntimeReachTests: XCTestCase {
    private func evaluate(_ script: String, in runtime: SceneScriptRuntime) -> JSValue? {
        runtime.context.evaluateScript(script)
    }

    // MARK: - S11

    func testACommandPushedWhileTheRingDrainsRunsInTheSameDrain() throws {
        let runtime = try SceneScriptRuntime(host: TestSceneScriptHost(), compiler: TestSceneScriptCompiler())
        var log: [String] = []
        runtime.commandRing.register(SceneScriptCommandRing.Opcode(rawValue: 1002)) { [weak runtime] command in
            log.append("outer \(command.strings.first ?? "")")
            // A handler that calls back into JavaScript, like createLayer running a new layer's code.
            runtime?.rt.invokeMethod("push", withArguments: [1003, -1, [7], ["inner"]])
        }
        runtime.commandRing.register(SceneScriptCommandRing.Opcode(rawValue: 1003)) { command in
            log.append("\(command.strings.first ?? "") \(command.numbers.first ?? -1)")
        }
        runtime.add(SceneScriptInstance(id: "s", source: "function update() { __rt.push(1002, -1, [], ['a']); }"))
        runtime.load()
        runtime.frame(deltaTime: 1.0 / 60)
        XCTAssertEqual(log, ["outer a", "inner 7.0"])
        XCTAssertEqual(runtime.commandRing.pendingCount, 0)
        runtime.frame(deltaTime: 1.0 / 60)
        XCTAssertEqual(log, ["outer a", "inner 7.0", "outer a", "inner 7.0"], "nothing is replayed")
    }

    func testAHandlerThatKeepsPushingEndsInTheOverflow() throws {
        var configuration = SceneScriptRuntime.Configuration.standard
        configuration.commandCapacity = 16
        let runtime = try SceneScriptRuntime(host: TestSceneScriptHost(), compiler: TestSceneScriptCompiler(),
                                             configuration: configuration)
        var count = 0
        runtime.commandRing.register(SceneScriptCommandRing.Opcode(rawValue: 1004)) { [weak runtime] _ in
            count += 1
            runtime?.rt.invokeMethod("push", withArguments: [1004, -1])
        }
        runtime.add(SceneScriptInstance(id: "s", source: "function update() { __rt.push(1004, -1); }"))
        runtime.load()
        runtime.frame(deltaTime: 1.0 / 60)
        XCTAssertEqual(count, 16, "bounded by the ring's capacity")
        XCTAssertEqual(runtime.commandRing.pendingCount, 0)
    }

    // MARK: - S28

    private func transformerRuntime(configuration: SceneScriptRuntime.Configuration = .standard) throws -> SceneScriptRuntime {
        try SceneScriptRuntime(host: TestSceneScriptHost(), compiler: SceneScriptModuleTransformer(),
                               configuration: configuration)
    }

    func testScriptsCannotReachTheRuntime() throws {
        let runtime = try transformerRuntime()
        runtime.add(SceneScriptInstance(id: "s", source: """
            shared.atGlobal = [typeof __rt, typeof globalThis.__rt, typeof Function('return __rt')()].join();
            export function update() {
                shared.inUpdate = [typeof __rt, typeof globalThis.__rt, typeof Function('return this')().__rt].join();
            }
            """))
        runtime.load()
        runtime.frame(deltaTime: 1.0 / 60)
        XCTAssertEqual(evaluate("shared.atGlobal", in: runtime)?.toString(), "undefined,undefined,undefined")
        XCTAssertEqual(evaluate("shared.inUpdate", in: runtime)?.toString(), "undefined,undefined,undefined")
        XCTAssertEqual(evaluate("typeof __rt", in: runtime)?.toString(), "object", "the native side still reads it")
    }

    func testRuntimeCodeCallingAReplacedBuiltinDoesNotLeakTheRuntime() throws {
        let runtime = try transformerRuntime()
        runtime.add(SceneScriptInstance(id: "s", source: """
            const filter = Array.prototype.filter;
            Array.prototype.filter = function () {
                if (globalThis.__rt !== undefined) shared.leaked = true;
                return filter.apply(this, arguments);
            };
            export function update() {}
            """))
        runtime.load()
        runtime.frame(deltaTime: 1.0 / 60)
        runtime.remove(scriptID: "s")
        runtime.frame(deltaTime: 1.0 / 60)
        XCTAssertEqual(evaluate("shared.leaked === undefined", in: runtime)?.toBool(), true)
    }

    func testHooksAndRuntimeFunctionsAreSealed() throws {
        let runtime = try transformerRuntime()
        evaluate("__rt.hooks.coerce = function () { return 'hijacked'; }; __rt.push = null;", in: runtime)
        XCTAssertEqual(evaluate("Object.isFrozen(__rt.hooks)", in: runtime)?.toBool(), true)
        XCTAssertEqual(evaluate("typeof __rt.push", in: runtime)?.toString(), "function")
        XCTAssertEqual(evaluate("__rt.hooks.coerce({}, 5)", in: runtime)?.toInt32(), 5)
    }

    func testTheRuntimeIsReadableAgainAfterTheWatchdogHalted() throws {
        var configuration = SceneScriptRuntime.Configuration.standard
        configuration.frameTimeLimit = 0.2
        let runtime = try transformerRuntime(configuration: configuration)
        try XCTSkipUnless(SceneScriptWatchdog.isAvailable, "no watchdog in this JavaScriptCore")
        runtime.add(SceneScriptInstance(id: "s", source: "export function update() { while (true) {} }"))
        runtime.load()
        runtime.frame(deltaTime: 1.0 / 60)
        XCTAssertEqual(runtime.state, .halted)
        XCTAssertEqual(evaluate("typeof __rt", in: runtime)?.toString(), "object")
    }
}
