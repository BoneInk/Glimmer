import Foundation

/// Compiles an update's shaders before it installs, so the relaunched app draws its wallpapers
/// without stalling on shader and pipeline compilation.
///
/// Sparkle has downloaded and extracted the update; its install and relaunch are postponed
/// (`AppUpdater`) until `prewarmThenInstall` calls `install`. That happens:
/// - at once, when the new build's shader cache key (`ShaderCacheKey`, printed by the new
///   executable) equals this one's, or when the bundle, its signature or its key can't be
///   checked (logged);
/// - otherwise once the new executable, run headless with `--prewarm-shaders`
///   (`HelperRunCommand`), has compiled the shown and recent wallpapers into the shared
///   caches under its key and exited, crashed, or run over `timeout` (then terminated).
///
/// `install` runs exactly once per call.
@MainActor
final class UpdateShaderPrewarmer {
    private let runner: PrewarmProcessRunner
    private let currentKey: () -> ShaderCacheKey
    /// The extracted update's bundle for an appcast version, nil when it can't be found.
    private let locateBundle: (String) -> URL?
    /// Throws unless the bundle may run (`UpdateBundleVerifier`).
    private let verifyBundle: (URL) throws -> Void
    private let environment: [String: String]
    let timeout: TimeInterval
    let keyTimeout: TimeInterval

    private var child: PrewarmProcess?
    private var pendingInstall: (() -> Void)?
    private var timeoutWork: DispatchWorkItem?

    init(runner: PrewarmProcessRunner, currentKey: @escaping () -> ShaderCacheKey,
         locateBundle: @escaping (String) -> URL?, verifyBundle: @escaping (URL) throws -> Void,
         environment: [String: String], timeout: TimeInterval = 10 * 60, keyTimeout: TimeInterval = 30) {
        self.runner = runner
        self.currentKey = currentKey
        self.locateBundle = locateBundle
        self.verifyBundle = verifyBundle
        self.environment = environment
        self.timeout = timeout
        self.keyTimeout = keyTimeout
    }

    /// The app's prewarmer: Sparkle's installation cache for `bundleIdentifier`, the running app's
    /// signing requirement, and this process's isolated state passed on to the helper.
    static func standard(bundleIdentifier: String, storage: AppStorageLocation = .current) -> UpdateShaderPrewarmer {
        let locator = UpdateBundleLocator(bundleIdentifier: bundleIdentifier)
        var environment: [String: String] = ProcessInfo.processInfo.environment
        if let tag = storage.isolationTag { environment[AppStorageLocation.environmentKey] = tag }
        return UpdateShaderPrewarmer(
            runner: FoundationPrewarmProcessRunner(),
            currentKey: { ShaderCacheKey.current },
            locateBundle: { locator.bundle(version: $0) },
            verifyBundle: { bundle in
                try UpdateBundleVerifier.verify(bundle, requirement: try UpdateBundleVerifier.runningAppRequirement())
            },
            environment: environment)
    }

    var isRunning: Bool { pendingInstall != nil }

    /// Prewarms for the update whose appcast `version` (`CFBundleVersion`) Sparkle extracted, then
    /// calls `install`. A call while one runs replaces the install it will call.
    func prewarmThenInstall(version: String, install: @escaping () -> Void) {
        let alreadyRunning: Bool = pendingInstall != nil
        pendingInstall = install
        guard !alreadyRunning else { return }
        guard let bundle = locateBundle(version) else {
            return finish("no extracted bundle of version \(version) in Sparkle's installation cache", failed: true)
        }
        do {
            try verifyBundle(bundle)
        } catch {
            return finish("the update at \(bundle.path) can't be verified: \(error)", failed: true)
        }
        guard let executable = UpdateBundleLocator.executable(of: bundle) else {
            return finish("the update at \(bundle.path) has no executable", failed: true)
        }
        let current: ShaderCacheKey = currentKey()
        runner.output(of: executable, arguments: [HelperRunCommand.printKeyArgument], environment: environment,
                      timeout: keyTimeout) { [weak self] result in
            self?.decided(ShaderPrewarmDecision.decide(current: current, newBuildOutput: result), executable: executable)
        }
    }

    private func decided(_ decision: ShaderPrewarmDecision, executable: URL) {
        guard pendingInstall != nil else { return }
        switch decision {
        case .notNeeded:
            finish("the new build reads the same shader caches")
        case .unknown(let reason):
            finish(reason, failed: true)
        case .needed(let key):
            OWELog.info(.app, "Prewarming shaders for the update (cache \(key.variantGeneration))")
            start(executable)
        }
    }

    private func start(_ executable: URL) {
        let started = Date()
        do {
            child = try runner.start(executable, arguments: [HelperRunCommand.prewarmArgument], environment: environment) { [weak self] status, reason in
                guard let self, self.child != nil else { return }
                let seconds: String = String(format: "%.1f", Date().timeIntervalSince(started))
                if reason == .exit, status == 0 {
                    self.finish("shader prewarm finished in \(seconds) s")
                } else {
                    self.finish("shader prewarm ended after \(seconds) s (\(reason == .exit ? "status" : "signal") \(status))", failed: true)
                }
            }
        } catch {
            return finish("the shader prewarm couldn't start: \(error)", failed: true)
        }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let child = self.child else { return }
                child.terminate()
                self.finish("shader prewarm ran over \(Int(self.timeout)) s; terminated pid \(child.processIdentifier)", failed: true)
            }
        }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
    }

    /// The app is quitting: stops the helper. The postponed install is dropped; Sparkle installs a
    /// downloaded update on quit by itself.
    func cancel() {
        guard pendingInstall != nil else { return }
        if let child {
            OWELog.info(.app, "Stopping the shader prewarm (pid \(child.processIdentifier)): the app is quitting")
            child.terminate()
        }
        reset()
    }

    private func finish(_ reason: String, failed: Bool = false) {
        guard let install = pendingInstall else { return }
        reset()
        if failed {
            OWELog.error(.app, "Installing the update without a shader prewarm: \(reason)")
        } else {
            OWELog.info(.app, "Installing the update: \(reason)")
        }
        install()
    }

    private func reset() {
        timeoutWork?.cancel()
        timeoutWork = nil
        child = nil
        pendingInstall = nil
    }
}
