import XCTest
@testable import OpenWallpaperEngine

/// The version Settings › About shows.
final class AppVersionTests: XCTestCase {
    private let key = Data(repeating: 7, count: 32).base64EncodedString()

    func testReleaseBuildShowsItsReleaseVersionAndBuild() {
        let info: [String: Any] = [
            "SUFeedURL": "https://example.com/appcast.xml", "SUPublicEDKey": key,
            "OWEVersionLabel": "1.0.0-beta.2", "CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "2",
        ]
        XCTAssertEqual(AppVersion.displayString(infoDictionary: info), "1.0.0-beta.2 (2)")
    }

    func testLocalBuildWithoutTheUpdateKeyIsADevBuild() {
        let info: [String: Any] = [
            "SUFeedURL": "https://example.com/appcast.xml", "SUPublicEDKey": "",
            "OWEVersionLabel": "1.0.0", "CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "1",
        ]
        XCTAssertEqual(AppVersion.displayString(infoDictionary: info), "1.0.0 (Dev build)")
        let unexpanded: [String: Any] = ["OWEVersionLabel": "$(OWE_VERSION_LABEL)", "CFBundleShortVersionString": "1.0.0"]
        XCTAssertEqual(AppVersion.displayString(infoDictionary: unexpanded), "1.0.0 (Dev build)")
    }
}
