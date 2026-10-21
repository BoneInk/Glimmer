import XCTest
import OWEControlProtocol
@testable import OpenWallpaperEngine

/// A user property's value from an MCP client, checked and written as the Details panel stores it.
final class MCPUserPropertyValueTests: XCTestCase {
    private func property(_ type: String, minimum: Double = 0, maximum: Double = 1, fraction: Bool = true,
                          options: [ControlUserProperty.Option] = [], editable: Bool = false) -> ControlUserProperty {
        ControlUserProperty(key: "p", title: "P", type: type, value: "", defaultValue: "", minimum: minimum, maximum: maximum,
                            step: nil, fraction: fraction, editable: editable, options: options)
    }

    private func stored(_ value: JSONValue, _ property: ControlUserProperty) throws -> String {
        try ControlUserPropertyValue.stored(value, for: property)
    }

    func testSliders() throws {
        let slider = property("slider", minimum: -1, maximum: 10)
        XCTAssertEqual(try stored(2.5, slider), "2.5")
        XCTAssertEqual(try stored(3, slider), "3")
        XCTAssertEqual(try stored("4", slider), "4")
        XCTAssertThrowsError(try stored(11, slider))
        XCTAssertThrowsError(try stored(true, slider))
        XCTAssertThrowsError(try stored(1.5, property("slider", maximum: 5, fraction: false)))
    }

    func testBoolsCombosAndText() throws {
        XCTAssertEqual(try stored(true, property("bool")), "true")
        XCTAssertEqual(try stored("FALSE", property("bool")), "false")
        XCTAssertThrowsError(try stored("maybe", property("bool")))

        let combo = property("combo", options: [.init(label: "One", value: "1"), .init(label: "Two", value: "2")])
        XCTAssertEqual(try stored(2, combo), "2")
        XCTAssertEqual(try stored("one", combo), "1")
        XCTAssertThrowsError(try stored("3", combo))
        XCTAssertEqual(try stored("3", property("combo", options: combo.options, editable: true)), "3", "an editable combo takes any value")

        XCTAssertEqual(try stored("Hello", property("textinput")), "Hello")
        XCTAssertThrowsError(try stored("x", property("text")), "a notice row isn't a setting")
    }

    func testColours() throws {
        let color = property("color")
        XCTAssertEqual(try stored("1 0.5 0", color), "1 0.5 0")
        XCTAssertEqual(try stored("#ff0000", color), "1 0 0")
        XCTAssertEqual(try stored([0, 0, 1], color), "0 0 1")
        XCTAssertThrowsError(try stored("2 0 0", color))
        XCTAssertThrowsError(try stored("red", color))
    }

    func testPaths() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "MCPValue-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) } // Test scratch.
        let file = folder.appending(path: "a.png")
        try Data([0]).write(to: file)
        XCTAssertEqual(try stored(.string(file.path), property("file")), file.path)
        XCTAssertEqual(try stored(.string(folder.path), property("directory")), folder.standardizedFileURL.path)
        XCTAssertThrowsError(try stored(.string(folder.path), property("file")))
        XCTAssertThrowsError(try stored("relative.png", property("file")))
        XCTAssertThrowsError(try stored(.string(folder.appending(path: "missing").path), property("file")))
    }
}
