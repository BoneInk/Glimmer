import XCTest
@testable import OpenWallpaperEngine

/// Copy to and Swap with move a wallpaper's saved properties between displays' stores, as WE's
/// `transferWallpaperProperties` does: each store's values are what it runs (its own, else the
/// shared ones), and what one doesn't have is cleared from the other.
final class WallpaperPropertyTransferTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private let identity = WallpaperSettingsIdentity(rawValue: "123456")

    override func setUpWithError() throws {
        suiteName = "WallpaperPropertyTransferTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    private func save(_ values: [String: String], _ scope: WallpaperPropertyScope) {
        defaults.set(values, forKey: identity.key(.userProperties, scope: scope))
        defaults.set(true, forKey: identity.key(.explicitUserProperties, scope: scope))
    }

    private func values(_ scope: WallpaperPropertyScope) -> [String: String]? {
        defaults.dictionary(forKey: identity.key(.userProperties, scope: scope)) as? [String: String]
    }

    func testCopyGivesTheDestinationTheSourcesValues() {
        save(["speed": "2"], .display("1"))
        save(["speed": "5"], .display("2"))
        let copied = WallpaperPropertyTransfer.copy(identity, from: .display("1"), to: .display("2"), defaults: defaults)
        XCTAssertEqual(copied, ["speed": "2"])
        XCTAssertEqual(values(.display("2")), ["speed": "2"])
        XCTAssertEqual(values(.display("1")), ["speed": "2"])
        XCTAssertTrue(defaults.bool(forKey: identity.key(.explicitUserProperties, scope: .display("2"))))
    }

    func testCopyFromADisplayWithoutItsOwnUsesTheSharedValues() {
        save(["speed": "3"], .shared)
        save(["speed": "5"], .display("2"))
        WallpaperPropertyTransfer.copy(identity, from: .display("1"), to: .display("2"), defaults: defaults)
        XCTAssertEqual(values(.display("2")), ["speed": "3"])
    }

    func testCopyOfNothingClearsTheDestination() {
        save(["speed": "5"], .display("2"))
        let copied = WallpaperPropertyTransfer.copy(identity, from: .display("1"), to: .display("2"), defaults: defaults)
        XCTAssertEqual(copied, [:])
        XCTAssertNil(values(.display("2")), "the destination runs project.json's defaults, as the source does")
        XCTAssertFalse(defaults.bool(forKey: identity.key(.explicitUserProperties, scope: .display("2"))))
    }

    func testSwapExchangesTheTwoStores() {
        save(["speed": "2"], .display("1"))
        save(["speed": "5"], .display("2"))
        let swapped = WallpaperPropertyTransfer.swap(identity, .display("1"), .display("2"), defaults: defaults)
        XCTAssertEqual(swapped.first, ["speed": "5"])
        XCTAssertEqual(swapped.second, ["speed": "2"])
        XCTAssertEqual(values(.display("1")), ["speed": "5"])
        XCTAssertEqual(values(.display("2")), ["speed": "2"])
    }

    func testSyncedPropertiesStayAsTheyAre() {
        save(["speed": "2"], .shared)
        WallpaperPropertyTransfer.copy(identity, from: .shared, to: .shared, defaults: defaults)
        WallpaperPropertyTransfer.swap(identity, .shared, .shared, defaults: defaults)
        XCTAssertEqual(values(.shared), ["speed": "2"])
    }
}
