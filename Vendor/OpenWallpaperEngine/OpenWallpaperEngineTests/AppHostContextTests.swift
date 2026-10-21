import XCTest
@testable import OpenWallpaperEngine

/// A test host that crashed was reopened as a plain app on the user's real state: what may open
/// another copy of the app, and in which isolated state.
final class AppHostContextTests: XCTestCase {
    private func detect(_ environment: [String: String] = [:], arguments: [String] = [], xcTestLoaded: Bool = false,
                        bundles: [String] = []) -> AppHostContext {
        AppHostContext.detect(environment: environment, arguments: arguments, xcTestLoaded: xcTestLoaded,
                              loadedBundlePaths: bundles, isDebugged: false)
    }

    func testTheTestRunnerIsDetectedEveryWay() {
        for key in AppHostContext.testEnvironmentKeys {
            XCTAssertTrue(detect([key: "x"]).isTestHost, key)
        }
        XCTAssertTrue(detect(["DYLD_INSERT_LIBRARIES": "/Xcode.app/usr/lib/libXCTestBundleInject.dylib"]).isTestHost)
        XCTAssertTrue(detect(xcTestLoaded: true).isTestHost, "XCTestCase loaded")
        XCTAssertTrue(detect(bundles: ["/build/OpenWallpaperEngineTests.xctest"]).isTestHost, "a test bundle injected")
        XCTAssertFalse(detect(bundles: ["/Applications/Open Wallpaper Engine.app"]).isTestHost)
    }

    func testATestHostIsIsolatedAndNeverWatchesOrRelaunches() {
        let host = detect(["XCTestSessionIdentifier": "1"])
        XCTAssertEqual(host.isolationTag, AppStorageLocation.testsTag)
        XCTAssertFalse(host.mayRelaunch)
        XCTAssertFalse(host.shouldWatchForCrashes(enabled: true))
    }

    func testAnIsolatedCopyRelaunchesOnlyIsolatedAndNeverWatches() {
        let host = detect([AppStorageLocation.environmentKey: "shots"])
        XCTAssertFalse(host.isTestHost)
        XCTAssertTrue(host.mayRelaunch, "a language change still relaunches a development copy")
        XCTAssertFalse(host.shouldWatchForCrashes(enabled: true))
        XCTAssertEqual(host.relaunchEnvironment, [AppStorageLocation.environmentKey: "shots"])
        let byArgument = detect(arguments: ["app", AppStorageLocation.argumentKey, "dev"])
        XCTAssertEqual(byArgument.relaunchEnvironment, [AppStorageLocation.environmentKey: "dev"])
    }

    func testTheUsersLaunchWatchesAndRelaunchesPlain() {
        let host = detect()
        XCTAssertFalse(host.isIsolated)
        XCTAssertTrue(host.mayRelaunch)
        XCTAssertTrue(host.shouldWatchForCrashes(enabled: true))
        XCTAssertFalse(host.shouldWatchForCrashes(enabled: false))
        XCTAssertEqual(host.relaunchEnvironment, [:])
    }

    func testPreviewsAndDebuggersNeverWatch() {
        let preview = detect([AppHostContext.previewEnvironmentKey: "1"])
        XCTAssertTrue(preview.isPreviewHost)
        XCTAssertFalse(preview.mayRelaunch)
        XCTAssertFalse(preview.shouldWatchForCrashes(enabled: true))
        let debugged = AppHostContext.detect(environment: [:], arguments: [], xcTestLoaded: false, loadedBundlePaths: [],
                                             isDebugged: true)
        XCTAssertFalse(debugged.shouldWatchForCrashes(enabled: true))
    }

    func testTheRelaunchConfigurationCarriesTheIsolatedState() {
        let isolated = AppRelauncher.configuration(arguments: ["-Key", "value"],
                                                   host: detect([AppStorageLocation.environmentKey: "shots"]),
                                                   newInstance: true)
        XCTAssertEqual(isolated.environment, [AppStorageLocation.environmentKey: "shots"])
        XCTAssertEqual(isolated.arguments, ["-Key", "value"])
        XCTAssertTrue(isolated.createsNewApplicationInstance)

        let plain = AppRelauncher.configuration(arguments: [], host: detect(), newInstance: false)
        XCTAssertNil(plain.environment[AppStorageLocation.environmentKey], "the user's launch opens a plain copy")
        XCTAssertFalse(plain.createsNewApplicationInstance)
    }

    /// The test host itself: isolated under `tests`, and any relaunch it builds stays isolated.
    func testTheTestHostsOwnContext() {
        let host = AppHostContext.current
        XCTAssertTrue(host.isTestHost)
        XCTAssertEqual(host.isolationTag, AppStorageLocation.current.isolationTag)
        XCTAssertEqual(AppRelauncher.configuration(arguments: [], host: host, newInstance: true).environment,
                       [AppStorageLocation.environmentKey: AppStorageLocation.testsTag])
    }
}
