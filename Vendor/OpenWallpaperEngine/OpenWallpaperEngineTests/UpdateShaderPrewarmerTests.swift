import XCTest
@testable import OpenWallpaperEngine

/// The postponed install runs exactly once whatever happens to the prewarm: not needed, finished,
/// crashed, timed out, or impossible to check.
@MainActor
final class UpdateShaderPrewarmerTests: XCTestCase {
    private let current = ShaderCacheKey(translatorRevision: 10, variantGeneration: "r10-aaaaaa", pipelineEnvironment: "env-a")
    private let newer = ShaderCacheKey(translatorRevision: 11, variantGeneration: "r11-aaaaaa", pipelineEnvironment: "env-b")
    private var bundle: URL!
    private var runner: FakePrewarmProcessRunner!
    private var installs = 0

    override func setUpWithError() throws {
        bundle = FileManager.default.temporaryDirectory.appending(path: "owe-prewarm-\(UUID().uuidString)/New.app")
        try UpdateBundleLocatorTests.makeBundle(at: bundle, identifier: "com.example.app", version: "42")
        runner = FakePrewarmProcessRunner()
        installs = 0
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: bundle.deletingLastPathComponent())
    }

    private func prewarmer(bundle: URL? = nil, verify: @escaping (URL) throws -> Void = { _ in },
                           timeout: TimeInterval = 5) -> UpdateShaderPrewarmer {
        let found: URL? = bundle ?? self.bundle
        let current = self.current
        return UpdateShaderPrewarmer(runner: runner, currentKey: { current }, locateBundle: { _ in found },
                                     verifyBundle: verify, environment: ["OWE_ISOLATED_STATE": "tag"], timeout: timeout)
    }

    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }

    func testSameKeyInstallsWithoutPrewarm() throws {
        runner.keyOutput = .success(try current.encoded())
        let prewarmer = prewarmer()
        prewarmer.prewarmThenInstall(version: "42") { self.installs += 1 }
        spin { installs > 0 }
        settle()
        XCTAssertEqual(installs, 1)
        XCTAssertEqual(runner.outputArguments, [[HelperRunCommand.printKeyArgument]])
        XCTAssertTrue(runner.startedArguments.isEmpty)
    }

    func testDifferentKeyPrewarmsThenInstallsWhenTheHelperExits() throws {
        runner.keyOutput = .success(try newer.encoded())
        let prewarmer = prewarmer()
        prewarmer.prewarmThenInstall(version: "42") { self.installs += 1 }
        spin { runner.exited != nil }
        XCTAssertEqual(runner.startedArguments, [[HelperRunCommand.prewarmArgument]])
        XCTAssertEqual(runner.startedEnvironment?["OWE_ISOLATED_STATE"], "tag", "the helper uses the app's isolated state")
        XCTAssertEqual(installs, 0, "the install waits for the prewarm")
        runner.exited?(0, .exit)
        runner.exited?(0, .exit)
        settle()
        XCTAssertEqual(installs, 1)
        XCTAssertFalse(prewarmer.isRunning)
    }

    func testCrashedHelperStillInstalls() throws {
        runner.keyOutput = .success(try newer.encoded())
        let prewarmer = prewarmer()
        prewarmer.prewarmThenInstall(version: "42") { self.installs += 1 }
        spin { runner.exited != nil }
        runner.exited?(11, .uncaughtSignal)
        settle()
        XCTAssertEqual(installs, 1)
    }

    func testTimeoutTerminatesTheHelperAndInstalls() throws {
        runner.keyOutput = .success(try newer.encoded())
        let prewarmer = prewarmer(timeout: 0.2)
        prewarmer.prewarmThenInstall(version: "42") { self.installs += 1 }
        spin { installs > 0 }
        XCTAssertEqual(installs, 1)
        XCTAssertEqual(runner.child?.terminateCount, 1, "terminated by its own pid")
        // The terminated helper's exit arrives afterwards.
        runner.exited?(15, .uncaughtSignal)
        settle()
        XCTAssertEqual(installs, 1)
    }

    func testUnreadableKeyInstallsWithoutPrewarm() {
        runner.keyOutput = .failure(FoundationPrewarmProcessRunner.RunError.timedOut(seconds: 30))
        let prewarmer = prewarmer()
        prewarmer.prewarmThenInstall(version: "42") { self.installs += 1 }
        spin { installs > 0 }
        settle()
        XCTAssertEqual(installs, 1)
        XCTAssertTrue(runner.startedArguments.isEmpty)
    }

    func testHelperThatCantStartInstalls() throws {
        runner.keyOutput = .success(try newer.encoded())
        runner.startError = CocoaError(.fileNoSuchFile)
        let prewarmer = prewarmer()
        prewarmer.prewarmThenInstall(version: "42") { self.installs += 1 }
        spin { installs > 0 }
        settle()
        XCTAssertEqual(installs, 1)
    }

    func testMissingOrUnverifiedBundleInstallsAtOnce() {
        let missing = UpdateShaderPrewarmer(runner: runner, currentKey: { self.current }, locateBundle: { _ in nil },
                                            verifyBundle: { _ in }, environment: [:])
        missing.prewarmThenInstall(version: "42") { self.installs += 1 }
        XCTAssertEqual(installs, 1)
        let unverified = prewarmer(verify: { _ in throw UpdateBundleVerifier.Failure.invalid(-67050) })
        unverified.prewarmThenInstall(version: "42") { self.installs += 1 }
        XCTAssertEqual(installs, 2)
        XCTAssertTrue(runner.outputArguments.isEmpty, "an unverified build never runs")
    }

    func testQuittingStopsTheHelperWithoutInstalling() throws {
        runner.keyOutput = .success(try newer.encoded())
        let prewarmer = prewarmer()
        prewarmer.prewarmThenInstall(version: "42") { self.installs += 1 }
        spin { runner.exited != nil }
        prewarmer.cancel()
        XCTAssertEqual(runner.child?.terminateCount, 1)
        runner.exited?(15, .uncaughtSignal)
        settle()
        XCTAssertEqual(installs, 0, "Sparkle installs on quit by itself")
    }
}
