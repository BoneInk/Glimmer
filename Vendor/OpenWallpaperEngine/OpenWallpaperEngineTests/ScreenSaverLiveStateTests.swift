import ServiceManagement
import XCTest
@testable import OpenWallpaperEngine

/// When the app draws the screen saver live: only during a screen saver session in which an Open
/// Wallpaper Engine saver says it shows.
final class ScreenSaverLiveStateTests: XCTestCase {
    func testDrawsOnceASaverShowsDuringASession() {
        var state = ScreenSaverLiveState()
        XCTAssertFalse(state.handle(.didStart, at: 0), "another screen saver may be selected")
        XCTAssertFalse(state.isDrawing)
        XCTAssertTrue(state.handle(.saverAlive, at: 1))
        XCTAssertTrue(state.isDrawing)
        XCTAssertFalse(state.handle(.saverAlive, at: 2), "already drawing")
    }

    func testASaverOutsideASessionNeverStartsIt() {
        var state = ScreenSaverLiveState()
        XCTAssertFalse(state.handle(.saverAlive, at: 0))
        XCTAssertFalse(state.isDrawing, "a stacked view that missed willstop")
    }

    func testStopsOnWillStopDidStopAndUnlock() {
        for stop in [ScreenSaverLiveState.Event.willStop, .didStop, .screenUnlocked] {
            var state = ScreenSaverLiveState()
            state.handle(.didStart, at: 0)
            state.handle(.saverAlive, at: 0.5)
            XCTAssertTrue(state.handle(stop, at: 1), "\(stop)")
            XCTAssertFalse(state.isDrawing)
            XCTAssertFalse(state.handle(.saverAlive, at: 1.5), "the session is over (\(stop))")
        }
    }

    func testLockingKeepsDrawing() {
        var state = ScreenSaverLiveState()
        state.handle(.didStart, at: 0)
        state.handle(.saverAlive, at: 0.5)
        XCTAssertFalse(state.handle(.screenLocked, at: 1))
        XCTAssertTrue(state.isDrawing)
        XCTAssertTrue(state.isLocked)
    }

    func testStopsWhenTheSaverGoesQuietAndResumesWhenItReturns() {
        var state = ScreenSaverLiveState()
        state.handle(.didStart, at: 0)
        state.handle(.saverAlive, at: 1)
        XCTAssertFalse(state.handle(.tick, at: 1 + ScreenSaverLiveState.saverTimeout))
        XCTAssertTrue(state.handle(.tick, at: 1.1 + ScreenSaverLiveState.saverTimeout))
        XCTAssertFalse(state.isDrawing)
        XCTAssertTrue(state.screenSaverRuns)
        XCTAssertTrue(state.handle(.saverAlive, at: 10), "a host that came back")
    }

    func testAnAppLaunchedForASaverDrawsWithoutTheDidStartItMissed() {
        var state = ScreenSaverLiveState()
        XCTAssertTrue(state.handle(.launchedForScreenSaver, at: 0), "loads at once, before the saver's next ping")
        XCTAssertTrue(state.screenSaverRuns)
        XCTAssertFalse(state.handle(.saverAlive, at: 0.5))
        XCTAssertTrue(state.handle(.screenUnlocked, at: 5), "an unlock still ends it")
    }

    func testTheBrokerLaunchesTheAppOnlyWhenItIsntRunningAndNotOverAndOver() {
        var policy = LiveSaverLaunchPolicy()
        policy.screenSaverStarted(fromPreferences: false)
        XCTAssertFalse(policy.shouldLaunch(at: 0, appRunning: true))
        XCTAssertTrue(policy.shouldLaunch(at: 1, appRunning: false))
        XCTAssertFalse(policy.shouldLaunch(at: 2, appRunning: false), "still starting")
        XCTAssertTrue(policy.shouldLaunch(at: 1 + LiveSaverLaunchPolicy.retryInterval, appRunning: false), "it didn't start")
    }

    func testTheBrokersBackgroundItemStates() {
        XCTAssertEqual(ScreenSaverBrokerAgent.state(.enabled), .enabled)
        XCTAssertEqual(ScreenSaverBrokerAgent.state(.requiresApproval), .requiresApproval, "turned off in Login Items")
        XCTAssertEqual(ScreenSaverBrokerAgent.state(.notRegistered), .notRegistered)
        XCTAssertEqual(ScreenSaverBrokerAgent.state(.notFound), .unavailable)
    }

    @MainActor
    func testABuildWithoutTheAgentNeverRegistersIt() {
        // The test host is a Debug build: no Contents/Library/LaunchAgents plist.
        let agent = ScreenSaverBrokerAgent(bundle: .main, mayRegister: true)
        agent.update(enabled: true)
        XCTAssertEqual(agent.state, .unavailable)
        let isolated = ScreenSaverBrokerAgent(bundle: .main, mayRegister: false)
        isolated.update(enabled: true)
        XCTAssertEqual(isolated.state, .unavailable)
    }

    func testOnlyARealScreenSaverSessionLaunchesTheApp() {
        var policy = LiveSaverLaunchPolicy()
        XCTAssertFalse(policy.shouldLaunch(at: 0, appRunning: false),
                       "System Settings showing the saver when it is picked: no didstart")
        policy.screenSaverStarted(fromPreferences: true)
        XCTAssertFalse(policy.shouldLaunch(at: 1, appRunning: false), "System Settings' Preview")
        policy.screenSaverStopped()
        policy.screenSaverStarted(fromPreferences: false)
        XCTAssertTrue(policy.shouldLaunch(at: 2, appRunning: false), "the screen saver itself")
        policy.screenSaverStopped()
        XCTAssertFalse(policy.shouldLaunch(at: 100, appRunning: false), "after it stopped")
    }

    func testPreviewRunsAreToldByRunFromPref() {
        XCTAssertTrue(LiveSaverLaunchPolicy.isFromPreferences(["runFromPref": NSNumber(value: 1)]))
        XCTAssertTrue(LiveSaverLaunchPolicy.isFromPreferences(["runFromPref": "1"]))
        XCTAssertTrue(LiveSaverLaunchPolicy.isFromPreferences(["runFromPref": true]))
        XCTAssertFalse(LiveSaverLaunchPolicy.isFromPreferences(["runFromPref": NSNumber(value: 0)]))
        XCTAssertFalse(LiveSaverLaunchPolicy.isFromPreferences([:]))
        XCTAssertFalse(LiveSaverLaunchPolicy.isFromPreferences(nil))
    }
}
