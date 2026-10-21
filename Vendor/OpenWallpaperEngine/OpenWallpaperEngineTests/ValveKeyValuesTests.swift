import XCTest
@testable import OpenWallpaperEngine

/// Valve's KeyValues text (VDF): what Steam writes in `.acf` and `.vdf` files.
final class ValveKeyValuesTests: XCTestCase {
    func testNestedBlocksKeepOrderAndLookupsIgnoreCase() throws {
        let text = """
        "AppWorkshop"
        {
        \t"appid"\t\t"431960"
        \t"WorkshopItemsInstalled"
        \t{
        \t\t"222"  { "size" "10" }
        \t\t"111"
        \t\t{
        \t\t\t"size"\t"20"
        \t\t}
        \t}
        }
        """
        let entries = try ValveKeyValues.parse(text)
        let root = try XCTUnwrap(entries["appworkshop"])
        XCTAssertEqual(root["APPID"]?.string, "431960")
        XCTAssertEqual(root["WorkshopItemsInstalled"]?.entries.map(\.key), ["222", "111"])
        XCTAssertEqual(root["WorkshopItemsInstalled"]?["111"]?["size"]?.string, "20")
        XCTAssertNil(root["missing"])
        XCTAssertNil(root["appid"]?["size"], "a string has no entries")
    }

    func testEscapesCommentsConditionsAndBareTokens() throws {
        let text = """
        // a comment line
        root {
            "quote" "say \\"hi\\""   // trailing comment
            "path"  "C:\\\\Program Files (x86)\\\\Steam"
            "win"   "1" [$WIN32]
            bare    value
            "tab"   "a\\tb"
            "unknown" "a\\qb"
            "dup" "1"
            "dup" "2"
            "empty" ""
        }
        """
        let root = try XCTUnwrap(try ValveKeyValues.parse(text)["root"])
        XCTAssertEqual(root["quote"]?.string, "say \"hi\"")
        XCTAssertEqual(root["path"]?.string, "C:\\Program Files (x86)\\Steam")
        XCTAssertEqual(root["win"]?.string, "1")
        XCTAssertEqual(root["bare"]?.string, "value")
        XCTAssertEqual(root["tab"]?.string, "a\tb")
        XCTAssertEqual(root["unknown"]?.string, "a\\qb")
        XCTAssertEqual(root.entries.filter { $0.key == "dup" }.map(\.value), [.string("1"), .string("2")])
        XCTAssertEqual(root["dup"]?.string, "1", "the first of repeated keys wins a lookup")
        XCTAssertEqual(root["empty"]?.string, "")
    }

    func testNestingIsBoundedWithAnError() throws {
        let limit = ValveKeyValues.maximumDepth
        let deepest = String(repeating: "k {\n", count: limit) + String(repeating: "}\n", count: limit)
        var value = try XCTUnwrap(ValveKeyValues.parse(deepest)["k"])
        for _ in 1..<limit { value = try XCTUnwrap(value["k"]) }
        XCTAssertEqual(value.entries, [])

        let tooDeep = String(repeating: "k {\n", count: limit + 1) + String(repeating: "}\n", count: limit + 1)
        XCTAssertThrowsError(try ValveKeyValues.parse(tooDeep)) {
            XCTAssertEqual($0 as? ValveKeyValues.ParseError, .nestedTooDeeply(line: limit + 1))
        }
        XCTAssertThrowsError(try ValveKeyValues.parse(String(repeating: "{", count: 100_000)))
    }

    func testMalformedTextThrowsWithTheLine() {
        XCTAssertThrowsError(try ValveKeyValues.parse("\"a\" {\n\"b\" \"c\"\n")) {
            XCTAssertEqual($0 as? ValveKeyValues.ParseError, .unterminatedBlock(key: "a"))
        }
        XCTAssertThrowsError(try ValveKeyValues.parse("\"a\" \"b\"\n}")) {
            XCTAssertEqual($0 as? ValveKeyValues.ParseError, .unexpectedCloseBrace(line: 2))
        }
        XCTAssertThrowsError(try ValveKeyValues.parse("\"a\"\n\"b")) {
            XCTAssertEqual($0 as? ValveKeyValues.ParseError, .unterminatedString(line: 2))
        }
        XCTAssertThrowsError(try ValveKeyValues.parse("\"lonely\"")) {
            XCTAssertEqual($0 as? ValveKeyValues.ParseError, .missingValue(key: "lonely", line: 1))
        }
        XCTAssertEqual(try ValveKeyValues.parse("  \n// only a comment\n"), [])
    }

    func testFilesWithABOMAndCRLFLineEnds() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "owe-vdf-\(UUID().uuidString).vdf")
        defer { try? FileManager.default.removeItem(at: url) } // scratch cleanup
        try Data([0xEF, 0xBB, 0xBF] + Array("\"users\"\r\n{\r\n\t\"76561190000000001\"\r\n\t{\r\n\t\t\"AccountName\"\t\t\"éva\"\r\n\t}\r\n}\r\n".utf8)).write(to: url)
        let entries = try ValveKeyValues.parse(contentsOf: url)
        XCTAssertEqual(entries["users"]?["76561190000000001"]?["AccountName"]?.string, "éva")
    }
}
