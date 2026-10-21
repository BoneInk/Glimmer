import XCTest
@testable import OpenWallpaperEngine

/// What's New after an update, and the UI state kept across an update relaunch.
@MainActor
final class WhatsNewTests: XCTestCase {
    private func isolatedDefaults() -> UserDefaults {
        let name: String = "WhatsNewTests.\(UUID().uuidString)"
        let defaults: UserDefaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private let changelog: String = """
    # Changelog

    ## [Unreleased]

    ## [1.2.0]

    - Twelve.

    ## [1.1.0]

    - Eleven.

    ## [1.1.0-beta.1]

    - Eleven beta.

    ## [1.0.0]

    - One.
    """

    private func whatsNew(_ version: String, _ defaults: UserDefaults) -> WhatsNew {
        WhatsNew(defaults: defaults, currentVersion: version,
                 notes: ReleaseNotesStore(defaults: defaults, changelog: changelog))
    }

    func testVersionOrderingIncludesPrereleases() throws {
        let ordered: [String] = ["0.9.0", "1.0.0-alpha.1", "1.0.0-alpha.2", "1.0.0-beta.1", "1.0.0-beta.2",
                                 "1.0.0-beta.10", "1.0.0-rc.1", "1.0.0", "1.0.1", "1.1.0", "2.0.0"]
        let versions: [ReleaseVersion] = try ordered.map { try XCTUnwrap(ReleaseVersion($0), $0) }
        for (index, version) in versions.enumerated() {
            for later in versions[(index + 1)...] { XCTAssertLessThan(version, later, "\(version) < \(later)") }
            XCTAssertEqual(version.description, ordered[index])
        }
        XCTAssertEqual(versions.shuffled().sorted(), versions)
    }

    func testFirstInstallShowsNothing() {
        let defaults: UserDefaults = isolatedDefaults()
        let first: WhatsNew = whatsNew("1.0.0", defaults)
        first.recordFirstInstall()
        XCTAssertEqual(defaults.string(forKey: WhatsNew.lastSeenVersionKey), "1.0.0")
        XCTAssertNil(first.takePendingEntries())
        XCTAssertNil(whatsNew("1.0.0", defaults).takePendingEntries(), "a relaunch of the same version")
    }

    func testAnUpdateShowsOnce() throws {
        let defaults: UserDefaults = isolatedDefaults()
        whatsNew("1.0.0", defaults).recordFirstInstall()
        let pending = try XCTUnwrap(whatsNew("1.1.0", defaults).takePendingEntries())
        XCTAssertEqual(pending.current, "1.1.0")
        XCTAssertEqual(pending.entries, [WhatsNew.Entry(version: "1.1.0", notes: "- Eleven.")])
        XCTAssertNil(whatsNew("1.1.0", defaults).takePendingEntries(), "shown once")
        XCTAssertEqual(defaults.string(forKey: WhatsNew.lastSeenVersionKey), "1.1.0")
    }

    func testSkippedVersionsAreCombinedNewestFirst() throws {
        let defaults: UserDefaults = isolatedDefaults()
        whatsNew("1.0.0", defaults).recordFirstInstall()
        let pending = try XCTUnwrap(whatsNew("1.2.0", defaults).takePendingEntries())
        XCTAssertEqual(pending.entries.map(\.version), ["1.2.0", "1.1.0"], "no pre-releases on the way to a final")
        XCTAssertEqual(pending.entries.map(\.notes), ["- Twelve.", "- Eleven."])
    }

    func testPrereleasesListedWhenUpdatingToAPrerelease() throws {
        let defaults: UserDefaults = isolatedDefaults()
        whatsNew("1.0.0", defaults).recordFirstInstall()
        let pending = try XCTUnwrap(whatsNew("1.1.0-beta.2", defaults).takePendingEntries())
        XCTAssertEqual(pending.entries.map(\.version), ["1.1.0-beta.2", "1.1.0-beta.1"])
        XCTAssertNil(pending.entries[0].notes, "no notes anywhere for beta.2")
    }

    func testAppcastNotesWinAndArePrunedOnceShown() throws {
        let defaults: UserDefaults = isolatedDefaults()
        whatsNew("1.0.0", defaults).recordFirstInstall()
        let store: ReleaseNotesStore = ReleaseNotesStore(defaults: defaults, changelog: changelog)
        store.cache(["1.1.0": "From the appcast.", "1.3.0": "Later.", "0.9.0": "Old."], newerThan: try XCTUnwrap(ReleaseVersion("1.0.0")))
        let pending = try XCTUnwrap(whatsNew("1.1.0", defaults).takePendingEntries())
        XCTAssertEqual(pending.entries, [WhatsNew.Entry(version: "1.1.0", notes: "From the appcast.")])
        let left: [String: String]? = defaults.dictionary(forKey: ReleaseNotesStore.defaultsKey) as? [String: String]
        XCTAssertEqual(left, ["1.3.0": "Later."])
    }

    func testTurnedOffShowsNothingButRecordsTheVersion() {
        let defaults: UserDefaults = isolatedDefaults()
        whatsNew("1.0.0", defaults).recordFirstInstall()
        defaults.set(true, forKey: WhatsNew.hidesReleaseNotesKey)
        XCTAssertNil(whatsNew("1.1.0", defaults).takePendingEntries())
        defaults.set(false, forKey: WhatsNew.hidesReleaseNotesKey)
        XCTAssertNil(whatsNew("1.1.0", defaults).takePendingEntries())
    }

    func testChangelogSection() {
        XCTAssertEqual(ReleaseNotesStore.section(of: "1.1.0", in: changelog), "- Eleven.")
        XCTAssertNil(ReleaseNotesStore.section(of: "3.0.0", in: changelog))
        XCTAssertNil(ReleaseNotesStore.section(of: "Unreleased", in: changelog), "an empty section")
    }

    /// The bundled CHANGELOG has this version's section.
    func testBundledChangelogCoversThisVersion() throws {
        let changelog: String = try XCTUnwrap(ReleaseNotesStore.bundledChangelog())
        let version: ReleaseVersion = try XCTUnwrap(ReleaseVersion(AppUpdateConfiguration.main.versionLabel))
        XCTAssertNotNil(ReleaseNotesStore.section(of: version.description, in: changelog))
    }

    // MARK: Update relaunch

    func testRelaunchStateIsRestoredOnce() throws {
        let defaults: UserDefaults = isolatedDefaults()
        let state: UpdateRelaunchState = UpdateRelaunchState(
            mainWindowOpen: true, tab: 1, selectedWallpapers: [URL(fileURLWithPath: "/tmp/a")],
            settingsOpen: true, settingsPage: 2, settingsFrame: "10 20 480 300 0 0 1920 1080 ", paused: true)
        state.save(to: defaults)
        XCTAssertEqual(UpdateRelaunchState.take(from: defaults), state)
        XCTAssertNil(UpdateRelaunchState.take(from: defaults), "used once")
    }

    func testMenuBarOnlyStateOpensNoWindow() throws {
        let defaults: UserDefaults = isolatedDefaults()
        UpdateRelaunchState(mainWindowOpen: false, tab: 0, selectedWallpapers: [], settingsOpen: false,
                            settingsPage: 0, settingsFrame: nil, paused: false).save(to: defaults)
        let restored: UpdateRelaunchState = try XCTUnwrap(UpdateRelaunchState.take(from: defaults))
        XCTAssertFalse(restored.mainWindowOpen || restored.settingsOpen)
    }

    func testUnreadableRelaunchStateIsDropped() {
        let defaults: UserDefaults = isolatedDefaults()
        defaults.set(Data("nonsense".utf8), forKey: UpdateRelaunchState.defaultsKey)
        XCTAssertNil(UpdateRelaunchState.take(from: defaults))
        XCTAssertNil(defaults.data(forKey: UpdateRelaunchState.defaultsKey))
    }
}
