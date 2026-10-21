import AppKit
import XCTest
@testable import OpenWallpaperEngine

/// The settings window first opens just wide enough for the toolbar in the current language and
/// 80% of the screen's visible height, and can be resized freely.
@MainActor
final class SettingsWindowSizeTests: XCTestCase {
    private let visibleFrame = NSRect(x: 0, y: 25, width: 2560, height: 1415)

    func testTheStartingWidthFitsEveryTabItemInTheCurrentLanguage() {
        let labels = SettingsTab.toolbarLabels
        XCTAssertEqual(labels.count, SettingsTab.allCases.count)
        XCTAssertFalse(labels.contains(where: \.isEmpty))
        let items = labels.reduce(CGFloat(0)) { $0 + SettingsTab.toolbarItemWidth(label: $1) }
        XCTAssertGreaterThanOrEqual(SettingsTab.initialWindowSize(visibleFrame: visibleFrame).width, items)
    }

    func testTheStartingWidthFollowsTheLabelsNotTheWidestTranslation() {
        let short = SettingsTab.allCases.map { _ in "A" }
        let long = SettingsTab.allCases.map { _ in "A much longer tab label" }
        XCTAssertLessThan(SettingsTab.toolbarFittingWidth(labels: short),
                          SettingsTab.toolbarFittingWidth(labels: long))
    }

    func testTheStartingHeightIsEightyPercentOfTheVisibleFrame() {
        let size = SettingsTab.initialWindowSize(visibleFrame: visibleFrame)
        XCTAssertEqual(size.height, visibleFrame.height * 0.8, accuracy: 0.001)
    }

    func testTheWindowHasNoMinimumWidth() {
        let window = AppDelegate.makeSettingsWindow()
        XCTAssertLessThanOrEqual(window.contentMinSize.width, 1)
        XCTAssertLessThanOrEqual(window.minSize.width, 1)
    }
}
