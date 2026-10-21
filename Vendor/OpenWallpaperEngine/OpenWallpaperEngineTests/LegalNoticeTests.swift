import XCTest
@testable import OpenWallpaperEngine

/// The Terms of Use and Privacy Policy notice: due on first run, recorded when read, shown again
/// once when the documents' version changes, and the bundled copies match `docs/legal`.
@MainActor
final class LegalNoticeTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suite = "owe-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    func testRequiredOnFirstRunAndNotShownAgainOnceRead() {
        XCTAssertTrue(LegalNotice.isDue(in: defaults, currentVersion: "terms-of-use 1.0, privacy-policy 1.0"))
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        LegalNotice.acknowledge(in: defaults, version: "terms-of-use 1.0, privacy-policy 1.0", date: date)
        XCTAssertEqual(LegalNotice.acknowledgement(in: defaults),
                       .init(version: "terms-of-use 1.0, privacy-policy 1.0", date: date))
        XCTAssertFalse(LegalNotice.isDue(in: defaults, currentVersion: "terms-of-use 1.0, privacy-policy 1.0"))
    }

    func testShownAgainOnceWhenAVersionChanges() {
        LegalNotice.acknowledge(in: defaults, version: "terms-of-use 1.0, privacy-policy 1.0")
        XCTAssertTrue(LegalNotice.isDue(in: defaults, currentVersion: "terms-of-use 1.0, privacy-policy 1.1"))
        LegalNotice.acknowledge(in: defaults, version: "terms-of-use 1.0, privacy-policy 1.1")
        XCTAssertFalse(LegalNotice.isDue(in: defaults, currentVersion: "terms-of-use 1.0, privacy-policy 1.1"))
    }

    /// Someone who finished setup before the notice existed has no record, so sees it once.
    func testExistingUsersSeeItOnce() {
        defaults.set(false, forKey: OnboardingFlow.showsAtLaunchKey)
        XCTAssertFalse(OnboardingFlow.showsAtLaunch(defaults: defaults))
        XCTAssertTrue(LegalNotice.isDue(in: defaults))
        LegalNotice.acknowledge(in: defaults)
        XCTAssertFalse(LegalNotice.isDue(in: defaults))
    }

    func testTheBundledDocumentsAreTheRepositoryOnesAndHaveAVersion() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        var editions: [LegalDocument: LegalDocument.Edition] = [:]
        for document in LegalDocument.allCases {
            let bundled = try XCTUnwrap(document.text(), "\(document.rawValue).md isn't in the app")
            let published = try String(contentsOf: repository.appending(path: "docs/legal/\(document.rawValue).md"), encoding: .utf8)
            XCTAssertEqual(bundled, published, "Resources/Legal/\(document.rawValue).md differs from docs/legal")
            XCTAssertFalse(bundled.contains("Draft for review"))
            let edition = try XCTUnwrap(LegalDocument.edition(of: bundled))
            XCTAssertEqual(edition.effectiveDate, document == .privacyPolicy ? "2026-10-06" : "2026-09-28")
            editions[document] = edition
        }
        XCTAssertEqual(LegalNotice.version(of: editions), LegalNotice.currentVersion)
        XCTAssertEqual(LegalNotice.currentVersion, "terms-of-use 1.0, privacy-policy 1.1")
    }

    func testTheMarkdownReaderFindsTheBlocks() {
        let blocks = LegalMarkdown.blocks(of: """
        # Title

        **Version 1.0 · Effective date: 2026-09-28**

        > **In short**
        >
        > A summary.

        - one
        - two
          continued
        | A | B |
        |---|---|
        | 1 | 2 |
        """)
        XCTAssertEqual(blocks, [
            .heading(level: 1, text: "Title"),
            .paragraph("**Version 1.0 · Effective date: 2026-09-28**"),
            .quote([.paragraph("**In short**"), .paragraph("A summary.")]),
            .list(["one", "two continued"]),
            .table([["A", "B"], ["1", "2"]]),
        ])
    }
}
