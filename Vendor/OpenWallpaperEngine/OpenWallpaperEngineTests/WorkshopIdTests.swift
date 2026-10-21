import XCTest
@testable import OpenWallpaperEngine

/// A Workshop id written as a number and as a string names the same item.
final class WorkshopIdTests: XCTestCase {
    func testNumberAndStringIdsAreEqual() throws {
        XCTAssertEqual(WorkshopId.int(1081733658), .string("1081733658"))
        XCTAssertNotEqual(WorkshopId.int(1), .string("2"))
        XCTAssertEqual(Set([WorkshopId.int(7), .string("7")]).count, 1)

        let number = try JSONDecoder().decode(WorkshopId.self, from: Data("42".utf8))
        let text = try JSONDecoder().decode(WorkshopId.self, from: Data(#""42""#.utf8))
        XCTAssertEqual(number, text)
    }
}
