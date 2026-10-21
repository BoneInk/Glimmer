import AppKit
import Foundation

/// `AppMain`'s step for the Metal shader cache (`MetalShaderCache.prepareForLaunch`): every process
/// running the app's code (the app, its helper runs, a test host, the Wallpaper Editor's app) takes
/// its shared lock, and a reset that is due happens when no other OWE process uses the cache.
enum MetalShaderCacheLaunch {
    /// What the cache was built for: the shader translator's and the pipeline archive's revisions.
    static var stamp: String {
        "shader-variants \(ShaderVariantTranslator.revision), pipeline-archive \(EffectPipelineArchive.revision)"
    }

    static func run() {
        guard let cache = MetalShaderCache.current else { return }
        let isolated = AppStorageLocation.current.isIsolated
        // A helper run starts while its app runs, which holds the cache: it only takes the lock.
        let mayReset = !HelperRunCommand.isHelperRun(arguments: ProcessInfo.processInfo.arguments)
        let outcome = cache.prepareForLaunch(lock: .process, stamp: stamp, mayReset: mayReset) {
            // An isolated copy's cache is its own, and only builds that take the lock use one.
            !isolated && otherProcessesRunning()
        }
        switch outcome {
        case .kept, .unavailable:
            break
        case .reset(let reason):
            OWELog.info(.app, "Metal shader cache: cleared (\(describe(reason)))")
        case .deferred(let reason):
            OWELog.info(.app, "Metal shader cache: clearing it (\(describe(reason))) waits for the next launch: another Open Wallpaper Engine process uses it")
        }
    }

    /// Another process with this bundle id: an older build, which doesn't take the lock, may share
    /// the cache.
    private static func otherProcessesRunning() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let pid = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains { $0.processIdentifier != pid }
    }

    private static func describe(_ reason: MetalShaderCache.ResetReason) -> String {
        switch reason {
        case .revisionChanged(let from): return "the shaders changed since \(from ?? "an earlier build")"
        case .usageDatabaseFull(let name): return "Metal's \(name) is full (MDB_MAP_FULL)"
        case .requested: return "Clear Caches"
        }
    }
}
