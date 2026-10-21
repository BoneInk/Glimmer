import AppKit
import SwiftUI
import XCTest
@testable import OpenWallpaperEngine

/// The Installed tab's "Scenes need Wallpaper Engine assets" banner keeps a small height at any
/// width. It sat in the library's top safe-area inset with its line sized to its full height, and
/// when the split view measured the column narrow, that height pushed the grid and the buttons under
/// it past the bottom edge of a 1000 × 692 window. The test host has the assets, so this measures
/// the banner's content (`AssetsMissingNotice`) directly.
@MainActor
final class InstalledAssetsBannerTests: XCTestCase {
    func testTheBannerStaysShortAtAnyWidth() {
        let controller = NSHostingController(rootView: AssetsMissingNotice())
        let wide = controller.sizeThatFits(in: CGSize(width: 1000, height: CGFloat.greatestFiniteMagnitude))
        XCTAssertLessThan(wide.height, 60, "one row in the library's width")
        for width: CGFloat in [0, 40, 120, 300, 500] {
            let size = controller.sizeThatFits(in: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
            XCTAssertLessThan(size.height, 90, "\(width) points wide: \(size.height) tall")
        }
    }
}
