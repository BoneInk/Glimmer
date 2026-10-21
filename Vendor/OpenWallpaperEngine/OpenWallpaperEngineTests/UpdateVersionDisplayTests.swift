import XCTest
@testable import OpenWallpaperEngine

/// The versions Sparkle's update window shows.
final class UpdateVersionDisplayTests: XCTestCase {
    func testDifferentLabelsShowWithoutBuilds() {
        let labels = UpdateVersionDisplay.labels(update: "1.0.0-beta.3", updateBuild: "3",
                                                 installed: "1.0.0-beta.2", installedBuild: "2")
        XCTAssertEqual(labels.update, "1.0.0-beta.3")
        XCTAssertEqual(labels.installed, "1.0.0-beta.2")
    }

    func testEqualLabelsShowTheirBuilds() {
        let labels = UpdateVersionDisplay.labels(update: "1.0.0-beta.2", updateBuild: "5",
                                                 installed: "1.0.0-beta.2", installedBuild: "2")
        XCTAssertEqual(labels.update, "1.0.0-beta.2 (5)")
        XCTAssertEqual(labels.installed, "1.0.0-beta.2 (2)")
    }

    func testInstalledPreReleaseIsNamedByItsLabelNotTheBundleVersion() {
        let info: [String: Any] = ["OWEVersionLabel": "1.0.0-beta.2", "CFBundleShortVersionString": "1.0.0"]
        let display = UpdateVersionDisplay(installedLabel: AppVersion.label(infoDictionary: info))
        XCTAssertEqual(display.formatBundleDisplayVersion("1.0.0", withBundleVersion: "2", matchingUpdate: nil),
                       "1.0.0-beta.2")
    }

    func testUnexpandedLabelFallsBackToTheBundleVersion() {
        let info: [String: Any] = ["OWEVersionLabel": "$(OWE_VERSION_LABEL)", "CFBundleShortVersionString": "1.0.0"]
        XCTAssertEqual(AppVersion.label(infoDictionary: info), "1.0.0")
    }
}
