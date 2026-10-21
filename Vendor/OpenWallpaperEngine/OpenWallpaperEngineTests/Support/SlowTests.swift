import Foundation
import XCTest

/// The slow tier: tests that take over about a minute. They skip unless `OWE_SLOW_TESTS=1`
/// (`TEST_RUNNER_OWE_SLOW_TESTS` through `xcodebuild`), which the nightly workflow and
/// `OWE_SLOW_TESTS=1 Scripts/ci-local.sh` set; pull requests and pushes to main skip them.
///
/// A single test starts with `try SlowTests.require()`; a class whose every test is slow
/// inherits from `SlowTestCase`. The durations report (`Scripts/ci-test-durations.py`) shows
/// which tests are candidates.
enum SlowTests {
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["OWE_SLOW_TESTS"] == "1" }

    static func require() throws {
        try XCTSkipUnless(isEnabled, "slow test: set OWE_SLOW_TESTS=1")
    }
}

/// A test class in the slow tier: every test skips unless `OWE_SLOW_TESTS=1` (`SlowTests`).
class SlowTestCase: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try SlowTests.require()
    }
}
