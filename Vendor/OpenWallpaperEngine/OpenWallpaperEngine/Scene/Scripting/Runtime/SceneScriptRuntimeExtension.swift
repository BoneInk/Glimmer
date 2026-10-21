import Foundation

/// A package of WE API that plugs into a `SceneScriptRuntime` without editing it: engine/timers/
/// storage/input (WP4), audio buffers (WP5), media (WP6), the object model (WP7). Each owns its
/// Swift files, its JS resource files and its data source; whoever builds the runtime (the
/// renderer, from WP11) passes the list.
///
/// Buffers an extension shares with scripts should be `SceneScriptSharedBuffer`s passed to
/// `runtime.watch(_:)` in `install`, so a script that detaches one stops the wallpaper's scripts
/// instead of silently desynchronizing them.
///
/// Order at runtime creation: `runtime.js`, then for each extension in list order `install(into:)`
/// followed by its `scriptResources`, then WE's jsmodules. Inside its JS an extension registers with
/// `__rt.addPhaseHandler('frameGlobals' | 'timers' | 'deferred', fn)`,
/// `__rt.addEventHandler(kind, fn)` and the `__rt.hooks`, and defines the globals it owns.
protocol SceneScriptRuntimeExtension: AnyObject {
    /// Names of JS files in `Resources/SceneScript/` (without `.js`), evaluated after `install`.
    var scriptResources: [String] { get }

    /// Installs native pieces before the JS resources run: shared buffers, command ring handlers,
    /// narrow `@convention(block)` functions on `runtime.rt.native`. Throwing aborts runtime creation.
    func install(into runtime: SceneScriptRuntime) throws

    /// Before the frame's single JS entry: fill shared buffers (audio, cursor, clock).
    func willRunFrame(_ runtime: SceneScriptRuntime, deltaTime: Double)

    /// After the frame and the command ring drain: read back what scripts wrote.
    func didRunFrame(_ runtime: SceneScriptRuntime)

    /// Once, when the runtime is torn down: after every script's `destroy()` ran (none when the
    /// watchdog halted the runtime) and the commands they issued were executed. Flush storage,
    /// cancel work, unsubscribe from sources. No script code runs afterwards. On the runtime's
    /// thread, like every other call.
    func tearDown(_ runtime: SceneScriptRuntime)
}

extension SceneScriptRuntimeExtension {
    var scriptResources: [String] { [] }
    func install(into runtime: SceneScriptRuntime) throws {}
    func willRunFrame(_ runtime: SceneScriptRuntime, deltaTime: Double) {}
    func didRunFrame(_ runtime: SceneScriptRuntime) {}
    func tearDown(_ runtime: SceneScriptRuntime) {}
}
