import XCTest
@testable import OpenWallpaperEngine

/// The setup assistant's state: skipping, revisiting, finishing, reopening and the language
/// relaunch, in a defaults suite of its own.
@MainActor
final class OnboardingFlowTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suite = "owe-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    func testEveryStepCanBeSkippedAndRevisited() {
        let flow = OnboardingFlow(defaults: defaults)
        XCTAssertTrue(OnboardingFlow.showsAtLaunch(defaults: defaults))
        XCTAssertEqual(flow.step, .notice)
        XCTAssertTrue(flow.isFirst)
        flow.back()
        XCTAssertEqual(flow.step, .notice)
        flow.skip()
        XCTAssertEqual(flow.step, .notice, "the Terms of Use and Privacy Policy notice can't be skipped")

        flow.next()
        flow.next()
        flow.next()
        XCTAssertEqual(flow.step, .steam)
        flow.skip()
        flow.skip()
        flow.skip()
        XCTAssertEqual(flow.step, .done)
        XCTAssertEqual(flow.skipped, [.steam, .assets, .wallpapers])
        XCTAssertEqual(flow.completed, [.notice, .welcome, .privacy])
        flow.skip()
        XCTAssertEqual(flow.step, .done, "the last step can't be skipped past")

        flow.go(to: .steam)
        XCTAssertEqual(flow.step, .steam)
        flow.next()
        XCTAssertEqual(flow.step, .assets)
        XCTAssertEqual(flow.skipped, [.assets, .wallpapers], "a step done on a revisit is no longer skipped")
        flow.back()
        XCTAssertEqual(flow.step, .steam)
    }

    /// The step and what was skipped survive a relaunch; finishing hides the assistant and
    /// "Run setup again…" brings it back from the top.
    func testProgressIsKeptUntilFinishAndReopenStartsOver() {
        let flow = OnboardingFlow(defaults: defaults)
        flow.next()
        flow.skip()
        flow.next()
        let resumed = OnboardingFlow(defaults: defaults)
        XCTAssertEqual(resumed.step, .steam)
        XCTAssertEqual(resumed.skipped, [.welcome])

        resumed.go(to: .done)
        resumed.finish()
        XCTAssertFalse(OnboardingFlow.showsAtLaunch(defaults: defaults))
        XCTAssertEqual(OnboardingFlow(defaults: defaults).step, .notice)

        OnboardingFlow.reopen(defaults: defaults)
        XCTAssertTrue(OnboardingFlow.showsAtLaunch(defaults: defaults))
        let reopened = OnboardingFlow(defaults: defaults)
        XCTAssertEqual(reopened.step, .notice)
        XCTAssertEqual(reopened.skipped, [])
    }

    /// A new language needs a relaunch; the assistant comes back after it on the next step.
    func testLanguageChangeRelaunchesIntoTheNextStep() {
        let change = LanguageChange(atLaunch: .followSystem)
        XCTAssertFalse(change.needsRelaunch(for: .followSystem))
        XCTAssertTrue(change.needsRelaunch(for: .de))
        XCTAssertFalse(LanguageChange(atLaunch: .ja).needsRelaunch(for: .ja))

        let flow = OnboardingFlow(defaults: defaults)
        flow.next()
        defaults.set(false, forKey: OnboardingFlow.showsAtLaunchKey)
        flow.prepareForRelaunch()
        XCTAssertTrue(OnboardingFlow.showsAtLaunch(defaults: defaults))
        XCTAssertEqual(OnboardingFlow(defaults: defaults).step, .privacy)
    }

    /// The language step writes the same setting as Settings › General, where macOS reads it.
    func testTheChosenLanguageIsWhereMacOSReadsIt() {
        GSLocalization.de.apply(to: defaults)
        XCTAssertEqual(defaults.array(forKey: "AppleLanguages") as? [String], ["de"])
        GSLocalization.followSystem.apply(to: defaults)
        // The global domain's list shows through `object(forKey:)`; the suite's own value is gone.
        XCTAssertNil(defaults.persistentDomain(forName: suite)?["AppleLanguages"])
    }
}
