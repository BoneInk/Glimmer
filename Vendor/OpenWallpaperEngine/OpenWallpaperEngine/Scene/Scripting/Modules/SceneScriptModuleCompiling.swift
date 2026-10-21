import Foundation

/// Turns a WE script (an ES module) into a factory JavaScriptCore can run without module SPI
/// (docs/scenescript-plan.md §4.2). WP3's tokenizer-based transformer implements it.
///
/// The factory contract the runtime relies on:
/// - `factorySource` evaluates (as a classic script) to a function `(__rt, __scope) => exports`.
/// - `__scope.thisLayer` / `__scope.thisObject` are the script's globals of those names, and
///   `__scope.require(name)` resolves `import * as X from 'name'` (case-insensitive).
/// - `exports` has one property per export (getters keep `export let` bindings live); the runtime
///   reads callbacks from it by name on every call.
/// - Line N of the original source is line N of `factorySource`, so error lines need no mapping.
/// - Evaluating the body is the module's global-scope code; it runs once, at load.
protocol SceneScriptModuleCompiling {
    func compile(_ source: String) throws -> SceneScriptCompiledModule
}

struct SceneScriptCompiledModule {
    var factorySource: String
}

/// A source the compiler rejects (`export default`, dynamic `import()`, …). JavaScriptCore's own
/// syntax errors surface when the factory is evaluated and are reported the same way.
struct SceneScriptCompileError: Error, CustomStringConvertible {
    var message: String
    /// 1-based line in the original source.
    var line: Int?

    var description: String { message }
}
