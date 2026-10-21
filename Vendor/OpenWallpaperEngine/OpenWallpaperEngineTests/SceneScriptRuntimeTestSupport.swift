import Foundation
@testable import OpenWallpaperEngine

/// A host with WE's baseclasses.js and no jsmodules (their `export`s need WP3's compiler).
final class TestSceneScriptHost: SceneScriptHost {
    let identity: SceneScriptIdentity
    let prelude: SceneScriptPrelude
    private(set) var errors: [SceneScriptError] = []

    init(wallpaperID: String = "test-wallpaper", screenID: String = "screen-1") {
        identity = SceneScriptIdentity(wallpaperID: wallpaperID, screenID: screenID)
        prelude = SceneScriptPrelude(baseClasses: SceneScriptPrelude.load().baseClasses, modules: [])
    }

    func runtime(_ runtime: SceneScriptRuntime, didReport error: SceneScriptError) {
        errors.append(error)
    }
}

/// Wraps plain function declarations (no `import`/`export`) in the module factory contract of
/// `SceneScriptModuleCompiling`, keeping line numbers. A stand-in until WP3's transformer.
struct TestSceneScriptCompiler: SceneScriptModuleCompiling {
    private static let exportNames = ["init", "update", "destroy", "resizeScreen", "applyUserProperties",
                                      "applyGeneralSettings", "scriptProperties"]

    func compile(_ source: String) throws -> SceneScriptCompiledModule {
        let getters = Self.exportNames
            .map { "get \($0)() { return typeof \($0) === 'undefined' ? undefined : \($0); }" }
            .joined(separator: ", ")
        let header = "(function (__rt, __scope) { 'use strict'; var thisLayer = __scope.thisLayer, thisObject = __scope.thisObject; "
        return SceneScriptCompiledModule(factorySource: header + source + "\nreturn { \(getters) }; })")
    }
}

/// Registers JS phase handlers and a media-ordered event kind that log into `shared.log`, to
/// observe the frame order.
final class PhaseLoggingExtension: SceneScriptRuntimeExtension {
    func install(into runtime: SceneScriptRuntime) throws {
        runtime.context.evaluateScript("""
            shared.log = shared.log || [];
            __rt.addPhaseHandler('frameGlobals', function () { shared.log.push('frameGlobals'); });
            __rt.addPhaseHandler('animations', function () { shared.log.push('animations'); });
            __rt.addEventHandler('testMedia', __rt.EVENT_ORDER.media, function (event) {
                shared.log.push('media:' + event.payload.state);
            });
            __rt.addPhaseHandler('timers', function () { shared.log.push('timers'); });
            __rt.addPhaseHandler('deferred', function () { shared.log.push('deferred'); });
            """)
    }
}
