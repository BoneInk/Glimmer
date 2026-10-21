import CryptoKit
import XCTest
@testable import WEFormat

/// `Digest.hex` spells every byte as `String(format: "%02x")` did, so cache keys stay the same.
final class DigestTests: XCTestCase {
    func testEveryByteMatchesFormatSpelling() {
        let bytes: [UInt8] = Array(0...255)
        let expected: String = bytes.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(Digest.hex(bytes), expected)
    }

    func testDigestPrefixesAndEmptyInput() {
        let digest = SHA256.hash(data: Data("Open Wallpaper Engine".utf8))
        let full: String = digest.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(Digest.hex(digest), full)
        XCTAssertEqual(Digest.hex(digest.prefix(8)), String(full.prefix(16)))
        XCTAssertEqual(Digest.hex(Insecure.SHA1.hash(data: Data())), "da39a3ee5e6b4b0d3255bfef95601890afd80709")
        XCTAssertEqual(Digest.hex([UInt8]()), "")
    }
}
