import Cocoa

/// What the two apps' executables run (`OpenWallpaperEngineApp/main.swift`, built into Open
/// Wallpaper Engine and the Wallpaper Editor's app): the code is in the OpenWallpaperEngine
/// framework both link, and the bundle id says which app this is (`AppLaunchMode`).
public enum AppMain {
    public static func run() {
        // First of all: an isolated copy (a test host, `OWE_ISOLATED_STATE`) moves its Darwin
        // cache and temporary folders, and with them Metal's shader cache, out of the app's.
        DarwinUserDirectories.isolate(for: AppStorageLocation.current)

        // Before any JavaScriptCore VM exists: the SceneScript watchdog must be able to stop
        // JIT-compiled loops.
        SceneScriptJIT.configurePollingTraps()

        // The crash watcher (Settings › Restart after crashing) only waits on the app: no
        // JavaScriptCore, no app lifecycle.
        if let status = CrashWatcher.runIfRequested(arguments: ProcessInfo.processInfo.arguments) {
            exit(status)
        }

        // `--control <command>` (WE's `-control`): a command for the running app, which this
        // process hands over and exits with its answer (`CommandLineControlCommand`). No Metal,
        // no app lifecycle, nothing of the running app's taken over.
        if let status = MainActor.assumeIsolated({ CommandLineControlCommand.run(arguments: ProcessInfo.processInfo.arguments) }) {
            exit(status)
        }

        // Before any Metal work: the Metal shader cache goes when the shaders changed or Metal's
        // usage database filled up, and this process holds it from now on.
        MetalShaderCacheLaunch.run()

        MainActor.assumeIsolated {
            // A helper run (`HelperRunCommand`) does its work and exits before the app's
            // lifecycle starts: no delegate, no windows, no playback.
            if let status = HelperRunCommand.run(arguments: ProcessInfo.processInfo.arguments) {
                exit(status)
            }
#if DEBUG
            // Debug harness for the Chromium engine's frame sharing (docs/chromium-engine.md).
            if let status = ChromiumFrameCaptureCommand.run(arguments: ProcessInfo.processInfo.arguments) {
                exit(status)
            }
#endif
            // Unit tests are hosted in the app; skip the delegate so a test run doesn't open
            // wallpaper windows, start playback or overwrite the user's saved state.
            var delegate: NSApplicationDelegate?
            let isTestHost = AppHostContext.isTestHost(environment: ProcessInfo.processInfo.environment,
                                                       xcTestLoaded: NSClassFromString("XCTestCase") != nil,
                                                       loadedBundlePaths: Bundle.allBundles.map(\.bundlePath))
            if !isTestHost {
                // Open Wallpaper Engine, or the Wallpaper Editor in a process of its own (`AppLaunchPlan`).
                let mode: AppLaunchMode = AppLaunchMode.parse(ProcessInfo.processInfo.arguments)
                // The first launch under the new bundle id moves the old one's state, before
                // anything reads the defaults (`AppIdentityMigration`).
                if case .main = mode {
                    AppIdentityMigration.forCurrentProcess().run()
                }
                delegate = AppLaunchPlan.plan(for: mode).makeDelegate()
                NSApplication.shared.delegate = delegate
            } else {
                // A test host has no delegate, so it marks its own Dock icon (`DockBadge.test`).
                DockBadge.current.apply(to: NSApplication.shared.dockTile)
            }
            // `NSApplication.delegate` is weak: the delegate lives as long as the app runs.
            withExtendedLifetime(delegate) {
                NSApplication.shared.run()
            }
        }
    }
}
