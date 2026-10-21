import Foundation

// These tests inject all system interactions; they never launch an Intel app or install Rosetta.
enum SteamCMDCapabilityProbe {
    struct Result { var isUsable: Bool }
    static func detectRosetta() -> Result { Result(isUsable: false) }
}

actor ProbeFixture {
    var usable = false
    func setUsable() { usable = true }
    func check() -> Bool { usable }
}

@main
struct RosettaInstallControllerTests {
    @MainActor
    static func main() async {
        var assertions = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            assertions += 1
        }
        func settle() async { try? await Task.sleep(for: .milliseconds(25)) }

        let fixture = ProbeFixture()
        var launches = 0
        var continuations = 0
        let controller = RosettaInstallController(
            probe: { await fixture.check() },
            launch: { launches += 1 },
            pollInterval: .milliseconds(5), maximumChecks: 200,
            continueWithSteamCMD: { continuations += 1 }
        )
        controller.start()
        controller.start()
        await settle()
        check(controller.state == .waiting, "missing Rosetta must wait")
        check(launches == 1, "duplicate taps must not relaunch")
        check(continuations == 0, "missing Rosetta must not continue")
        await fixture.setUsable()
        await controller.recheck() // application-reactivation path
        await settle()
        check(controller.state == .ready, "real usable probe must reach ready")
        check(continuations == 1, "continue once after detection")
        await controller.recheck()
        check(continuations == 1, "additional checks must not duplicate continuation")

        let cancelledFixture = ProbeFixture()
        var cancelledContinuations = 0
        let cancelled = RosettaInstallController(
            probe: { await cancelledFixture.check() }, launch: {},
            pollInterval: .milliseconds(5), maximumChecks: 200,
            continueWithSteamCMD: { cancelledContinuations += 1 }
        )
        cancelled.start()
        await settle()
        cancelled.cancel()
        await cancelledFixture.setUsable()
        await cancelled.recheck()
        await settle()
        check(cancelled.state == .cancelled, "cancel must stop monitoring")
        check(cancelledContinuations == 0, "cancel must preserve pending operations")
        cancelled.start()
        await settle()
        check(cancelled.state == .ready, "retry must automatically detect newly installed Rosetta")
        check(cancelledContinuations == 1, "retry continues exactly once")

        let failedLaunch = RosettaInstallController(
            probe: { false },
            launch: { throw NSError(domain: "NSOSStatusErrorDomain", code: -10810) },
            pollInterval: .milliseconds(5), maximumChecks: 200,
            continueWithSteamCMD: { preconditionFailure("cannot continue when unavailable") }
        )
        failedLaunch.start()
        await settle()
        check(failedLaunch.state == .waiting, "launch error may accompany the system prompt")
        check(failedLaunch.launchNotice != nil, "launch error must have actionable waiting text")
        failedLaunch.cancel()

        let missingHelper = RosettaInstallController(
            probe: { false }, launch: { throw RosettaInstallController.LaunchError.missingHelper },
            pollInterval: .milliseconds(5), maximumChecks: 200,
            continueWithSteamCMD: { preconditionFailure("missing helper cannot continue") }
        )
        missingHelper.start()
        await settle()
        if case .failed(let detail) = missingHelper.state {
            check(detail.contains("组件缺失"), "missing helper must fail immediately with repair text")
        } else { preconditionFailure("missing helper must not wait for timeout") }

        let timeout = RosettaInstallController(
            probe: { false }, launch: {},
            pollInterval: .milliseconds(1), maximumChecks: 2,
            continueWithSteamCMD: { preconditionFailure("timeout cannot continue") }
        )
        timeout.start()
        await settle()
        if case .failed = timeout.state { check(true, "timeout reports retry") }
        else { preconditionFailure("bounded polling must time out") }

        // A slow successful probe finishing after cancel must not resume the user's queue.
        var staleContinues = 0
        let stale = RosettaInstallController(
            probe: { try? await Task.sleep(for: .milliseconds(50)); return true }, launch: {},
            pollInterval: .milliseconds(5), maximumChecks: 200,
            continueWithSteamCMD: { staleContinues += 1 }
        )
        stale.start()
        await settle()
        stale.cancel()
        try? await Task.sleep(for: .milliseconds(75))
        check(stale.state == .cancelled, "late probe must respect cancellation generation")
        check(staleContinues == 0, "late success must not continue")
        print("PASS Rosetta controller: \(assertions) assertions; no system installer launched")
    }
}
