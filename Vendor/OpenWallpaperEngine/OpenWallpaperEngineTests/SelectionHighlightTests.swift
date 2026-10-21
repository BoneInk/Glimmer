import AppKit
import XCTest
@testable import OpenWallpaperEngine

/// A selected tile has one indicator, drawn in the accent colour, and redraws when the accent
/// changes.
@MainActor
final class SelectionHighlightTests: XCTestCase {
    private static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "OpenWallpaperEngine")

    private func waitForMainQueue() {
        let drained = expectation(description: "main queue")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
    }

    func testSystemColorChangeBumpsRevision() {
        let center = NotificationCenter()
        let accent = SystemAccentColor(center: center, distributedCenter: NotificationCenter())
        center.post(name: NSColor.systemColorsDidChangeNotification, object: nil)
        waitForMainQueue()
        XCTAssertEqual(accent.revision, 1)
    }

    func testColorPreferencesChangeBumpsRevision() {
        let distributed = NotificationCenter()
        let accent = SystemAccentColor(center: NotificationCenter(), distributedCenter: distributed)
        distributed.post(name: SystemAccentColor.colorPreferencesChanged, object: nil)
        waitForMainQueue()
        XCTAssertEqual(accent.revision, 1)
    }

    /// The library tile and the Displays tile use only `selectionHighlight`: no square accent
    /// border and no hard-coded blue stroke on top of it.
    func testTilesDrawOneIndicator() throws {
        for path in ["UI/Explorer/ExplorerItem.swift", "UI/Explorer/Alerts/MonitorLayoutView.swift"] {
            let source = try String(contentsOf: Self.sources.appending(path: path), encoding: .utf8)
            XCTAssertTrue(source.contains(".selectionHighlight("), path)
            XCTAssertFalse(source.contains("Color.blue"), path)
            XCTAssertFalse(source.contains(".selected("), path)
        }
    }
}
