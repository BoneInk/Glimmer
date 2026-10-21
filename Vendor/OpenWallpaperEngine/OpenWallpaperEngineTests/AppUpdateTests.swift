import XCTest
@testable import OpenWallpaperEngine

/// Sparkle configuration, release version parsing, the beta channel and when a downloaded update
/// installs (`Core/Updates`).
@MainActor
final class AppUpdateTests: XCTestCase {
    /// 32 bytes, base64: the shape of a Sparkle EdDSA public key (not a real one).
    private let sampleKey: String = Data(repeating: 7, count: 32).base64EncodedString()
    private let feed: URL? = URL(string: "https://openwallpaperengine.app/appcast.xml")

    private func configuration(key: String, label: String = "1.0.0") -> AppUpdateConfiguration {
        AppUpdateConfiguration(feedURL: feed, publicEDKey: key, versionLabel: label)
    }

    private func isolatedDefaults() -> UserDefaults {
        let name: String = "AppUpdateTests.\(UUID().uuidString)"
        let defaults: UserDefaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    // MARK: Versions

    func testReleaseVersionParsing() throws {
        let final: ReleaseVersion = try XCTUnwrap(ReleaseVersion("v1.0.0"))
        XCTAssertEqual(final.marketingVersion, "1.0.0")
        XCTAssertNil(final.prerelease)

        let beta: ReleaseVersion = try XCTUnwrap(ReleaseVersion("1.2.3-beta.4"))
        XCTAssertEqual(beta.marketingVersion, "1.2.3")
        XCTAssertEqual(beta.prerelease?.stage, .beta)
        XCTAssertEqual(beta.prerelease?.number, 4)
        XCTAssertEqual(ReleaseVersion("v2.0.0-alpha.1")?.prerelease?.stage, .alpha)
        XCTAssertEqual(ReleaseVersion("v2.0.0-rc.12")?.prerelease?.number, 12)

        for bad in ["", "v1", "v1.0", "1.0.0.0", "v1.0.0-", "v1.0.0-beta", "v1.0.0-beta.", "v1.0.0-preview.1",
                    "v1.0.0-beta.1.2", "v1.0.x", "1.0.0 ", "v1..0", "v1.0.0-Beta.1", "v01.0.0", "v1.0.0-beta.01"] {
            XCTAssertNil(ReleaseVersion(bad), bad)
        }
    }

    // MARK: Configuration

    func testBuildsWithoutAKeyDoNotCheckForUpdates() {
        XCTAssertFalse(configuration(key: "").isConfigured, "empty build setting (Debug and local builds)")
        XCTAssertFalse(configuration(key: "$(SPARKLE_PUBLIC_ED_KEY)").isConfigured, "unexpanded")
        XCTAssertFalse(configuration(key: "SPARKLE_PUBLIC_ED_KEY_PLACEHOLDER").isConfigured)
        XCTAssertFalse(configuration(key: Data(count: 16).base64EncodedString()).isConfigured, "wrong length")
        XCTAssertFalse(AppUpdateConfiguration(feedURL: URL(string: "http://example.com/appcast.xml"),
                                              publicEDKey: sampleKey, versionLabel: "1.0.0").isConfigured,
                       "an insecure feed")
        XCTAssertTrue(configuration(key: sampleKey).isConfigured)
        XCTAssertTrue(configuration(key: " \(sampleKey)\n").isConfigured, "whitespace from a pasted secret")
    }

    /// The test host is a Debug build: no key, so no updater, and nothing is checked.
    func testThisDebugBuildHasNoUpdater() {
        let main: AppUpdateConfiguration = .main
        XCTAssertFalse(main.isConfigured)
        XCTAssertEqual(main.feedURL?.absoluteString, feed?.absoluteString)

        let updater: AppUpdater = AppUpdater(configuration: main, defaults: isolatedDefaults())
        updater.start()
        XCTAssertFalse(updater.isEnabled)
        XCTAssertNil(updater.controller)
        XCTAssertFalse(updater.canCheckForUpdates)
        updater.checkForUpdates() // a no-op
        XCTAssertNil(updater.lastUpdateCheckDate)
    }

    func testInfoDictionaryKeys() {
        let info: [String: Any] = ["SUFeedURL": feed!.absoluteString, "SUPublicEDKey": sampleKey,
                                   "OWEVersionLabel": "1.0.0-rc.1", "CFBundleShortVersionString": "1.0.0"]
        let parsed: AppUpdateConfiguration = AppUpdateConfiguration(infoDictionary: info)
        XCTAssertTrue(parsed.isConfigured)
        XCTAssertTrue(parsed.isPrereleaseBuild)

        let noLabel: AppUpdateConfiguration = AppUpdateConfiguration(infoDictionary: ["CFBundleShortVersionString": "1.0.0"])
        XCTAssertEqual(noLabel.versionLabel, "1.0.0")
        XCTAssertFalse(noLabel.isPrereleaseBuild)
        XCTAssertFalse(noLabel.isConfigured)
    }

    // MARK: Channels

    func testBetaChannelOnlyWhenEnabledOrOnAPrereleaseBuild() {
        let release: AppUpdateConfiguration = configuration(key: sampleKey, label: "1.0.0")
        XCTAssertEqual(release.allowedChannels(storedPreference: nil), [])
        XCTAssertEqual(release.allowedChannels(storedPreference: false), [])
        XCTAssertEqual(release.allowedChannels(storedPreference: true), ["beta"])

        for label in ["1.0.0-beta.1", "1.0.0-alpha.2", "1.0.0-rc.1"] {
            let prerelease: AppUpdateConfiguration = configuration(key: sampleKey, label: label)
            XCTAssertTrue(prerelease.isPrereleaseBuild, label)
            XCTAssertEqual(prerelease.allowedChannels(storedPreference: nil), ["beta"], "on by default: \(label)")
            XCTAssertEqual(prerelease.allowedChannels(storedPreference: false), [], "the user's choice wins: \(label)")
        }
    }

    func testBetaPreferenceIsStoredInTheGivenDefaults() {
        let defaults: UserDefaults = isolatedDefaults()
        let updater: AppUpdater = AppUpdater(configuration: configuration(key: "", label: "1.1.0-beta.2"), defaults: defaults)
        XCTAssertTrue(updater.receivesBetaUpdates, "a pre-release build offers betas by default")
        updater.receivesBetaUpdates = false
        XCTAssertEqual(defaults.object(forKey: AppUpdater.receivesBetaUpdatesKey) as? Bool, false)
        XCTAssertFalse(updater.receivesBetaUpdates)
    }

    // MARK: Installing a downloaded update

    func testDownloadedUpdateInstallsWhenIdleOrAfterADay() {
        let policy: PendingUpdateInstallPolicy = PendingUpdateInstallPolicy()
        let ready: Date = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertFalse(policy.shouldInstall(readySince: ready, now: ready.addingTimeInterval(60), userIdleSeconds: 5))
        XCTAssertFalse(policy.shouldInstall(readySince: ready, now: ready.addingTimeInterval(3600), userIdleSeconds: 9 * 60))
        XCTAssertTrue(policy.shouldInstall(readySince: ready, now: ready.addingTimeInterval(60), userIdleSeconds: 10 * 60))
        XCTAssertTrue(policy.shouldInstall(readySince: ready, now: ready.addingTimeInterval(24 * 3600), userIdleSeconds: 0),
                      "never waits more than a day")
        XCTAssertLessThan(policy.pollInterval, policy.idleThreshold)
    }

    /// A launch checks right away when checks are on and the last check is over an hour old or never happened.
    func testALaunchChecksWhenTheLastCheckIsStale() {
        let now: Date = Date(timeIntervalSince1970: 1_000_000)
        let recent: Date = now.addingTimeInterval(-30 * 60)
        let stale: Date = now.addingTimeInterval(-2 * 60 * 60)
        XCTAssertTrue(AppUpdater.checksAtLaunch(automaticChecks: true, lastCheck: nil, now: now))
        XCTAssertTrue(AppUpdater.checksAtLaunch(automaticChecks: true, lastCheck: stale, now: now))
        XCTAssertFalse(AppUpdater.checksAtLaunch(automaticChecks: true, lastCheck: recent, now: now))
        XCTAssertFalse(AppUpdater.checksAtLaunch(automaticChecks: false, lastCheck: nil, now: now))
    }
}
