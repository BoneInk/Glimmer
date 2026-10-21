import XCTest
@testable import OpenWallpaperEngine

/// GetPublishedFileDetails answers and the store that keeps unavailable items from being asked
/// for again.
final class WorkshopItemAvailabilityTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "owe-unavailable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    // MARK: - Parsing

    func testParsesEachResult() throws {
        let json = """
        {"response": {"result": 1, "resultcount": 5, "publishedfiledetails": [
            {"publishedfileid": "1000000001", "result": 1, "consumer_app_id": 431960, "creator_app_id": 431960, "banned": 0},
            {"publishedfileid": "1000000002", "result": 9},
            {"publishedfileid": "1000000003", "result": 1, "consumer_app_id": 4000, "banned": 0},
            {"publishedfileid": "1000000004", "result": 1, "consumer_app_id": 431960, "banned": 1},
            {"publishedfileid": 1000000005, "result": 1, "consumer_app_id": 431960, "banned": false}
        ]}}
        """
        let availability = try WorkshopItemAvailability.parse(Data(json.utf8))

        XCTAssertEqual(availability, [
            "1000000001": .available,
            "1000000002": .unavailable(.removedOrPrivate),
            "1000000003": .unavailable(.otherApp),
            "1000000004": .unavailable(.banned),
            "1000000005": .available,
        ])
    }

    func testAnyResultButOneIsUnavailable() throws {
        let json = #"{"response": {"publishedfiledetails": [{"publishedfileid": "1000000001", "result": 2}]}}"#
        XCTAssertEqual(try WorkshopItemAvailability.parse(Data(json.utf8))["1000000001"], .unavailable(.removedOrPrivate))
    }

    func testAnUnexpectedResponseDescribesNothing() throws {
        XCTAssertEqual(try WorkshopItemAvailability.parse(Data(#"{"response": {}}"#.utf8)), [:])
        XCTAssertThrowsError(try WorkshopItemAvailability.parse(Data("not json".utf8)))
    }

    func testRequestBodyAndPage() {
        XCTAssertEqual(String(decoding: WorkshopItemAvailability.detailsBody(ids: ["1000000001", "1000000002"]), as: UTF8.self),
                       "itemcount=2&publishedfileids[0]=1000000001&publishedfileids[1]=1000000002")
        XCTAssertEqual(WorkshopItemAvailability.workshopPageURL(for: "1000000001")?.absoluteString,
                       "https://steamcommunity.com/sharedfiles/filedetails/?id=1000000001")
        XCTAssertNil(WorkshopItemAvailability.workshopPageURL(for: "../x"))
        XCTAssertEqual(WorkshopItemAvailability.steamClientPageURL(for: "1000000001")?.absoluteString,
                       "steam://url/CommunityFilePage/1000000001")
        XCTAssertNil(WorkshopItemAvailability.steamClientPageURL(for: "../x"))
    }

    func testSteamCmdFileNotFound() {
        XCTAssertTrue(WorkshopItemAvailability.steamCmdReportsNotFound("ERROR! Download item 1000000001 failed (File Not Found)."))
        XCTAssertFalse(WorkshopItemAvailability.steamCmdReportsNotFound("ERROR! Download item 1000000001 failed (Timeout)."))
    }

    // MARK: - Skip store

    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    private func store(_ clock: Clock) -> UnavailableWorkshopItemStore {
        UnavailableWorkshopItemStore(fileURL: root.appending(path: "Unavailable.json"), now: { clock.now })
    }

    func testRecordedItemsAreSkippedUntilTheyExpire() {
        let clock = Clock()
        let items = store(clock)
        XCTAssertNil(items.skipReason(for: "1000000001"))

        items.record("1000000001", reason: .removedOrPrivate)
        XCTAssertEqual(items.skipReason(for: "1000000001"), .removedOrPrivate)

        clock.now += UnavailableWorkshopItemStore.recheckInterval - 60
        XCTAssertEqual(items.skipReason(for: "1000000001"), .removedOrPrivate)
        clock.now += 120
        XCTAssertNil(items.skipReason(for: "1000000001"), "checked again after seven days")
    }

    func testEntriesPersistAndRetryForgetsThem() {
        let clock = Clock()
        store(clock).record("1000000001", reason: .otherApp)
        store(clock).record("1000000002", reason: .banned)

        let reloaded = store(clock)
        XCTAssertEqual(reloaded.skipReason(for: "1000000001"), .otherApp)
        XCTAssertEqual(reloaded.skipReason(for: "1000000002"), .banned)

        reloaded.forget(["1000000001"])
        XCTAssertNil(store(clock).skipReason(for: "1000000001"))
        XCTAssertEqual(store(clock).skipReason(for: "1000000002"), .banned)
    }

    func testTheDefaultFileIsInTheIsolatedSupportFolder() {
        XCTAssertTrue(AppStorageLocation.current.isIsolated)
        XCTAssertEqual(UnavailableWorkshopItemStore.defaultFileURL.deletingLastPathComponent().standardizedFileURL,
                       AppStorageLocation.current.supportDirectory.standardizedFileURL)
    }
}
