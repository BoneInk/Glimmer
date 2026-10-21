import XCTest
@testable import OpenWallpaperEngine

/// GetPublishedFileDetails requests carry only Workshop ids, form encoded, and responses Steam
/// didn't answer in its shape are errors rather than "no results".
final class WorkshopItemDetailsRequestTests: XCTestCase {
    private func body(_ ids: [String]) -> String? {
        WorkshopAPIService.itemDetailsBody(workshopIds: ids).map { String(decoding: $0, as: UTF8.self) }
    }

    func testKeepsOnlyDigitIdsAndEncodesTheForm() throws {
        let form = try XCTUnwrap(body(["123", "4&itemcount=99", "٣", "", "456"]))
        XCTAssertEqual(form, "itemcount=2&includetags=true&includevotes=true&includeshortdescription=true"
                       + "&publishedfileids%5B0%5D=123&publishedfileids%5B1%5D=456")
        XCTAssertNil(body(["abc", "1 2"]), "no request without an id")
    }

    func testFileSizeIsANumberOrANumericString() {
        XCTAssertEqual(WorkshopAPIService.int64("3645971"), 3645971)
        XCTAssertEqual(WorkshopAPIService.int64(NSNumber(value: 42)), 42)
        XCTAssertNil(WorkshopAPIService.int64("big"))
        XCTAssertNil(WorkshopAPIService.int64(nil))
    }

    func testAResponseWithoutResponseThrows() throws {
        XCTAssertThrowsError(try WorkshopAPIService.parseItems(from: Data(#"{"error":"busy"}"#.utf8)))
        XCTAssertEqual(try WorkshopAPIService.parseItems(from: Data(#"{"response":{"total":0}}"#.utf8)).count, 0,
                       "a query without results is empty")
    }
}
