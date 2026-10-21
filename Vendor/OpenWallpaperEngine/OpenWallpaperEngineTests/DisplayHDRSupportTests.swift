import XCTest
@testable import OpenWallpaperEngine

/// "Ultra (Display HDR)" is offered only where a display can show HDR, as WE's settings do
/// (`runtime.displayhdrsupport`), and a saved "displayhdr" is kept as "ultra" where none can.
final class DisplayHDRSupportTests: XCTestCase {
    func testOfferedOnlyWithEDRHeadroom() {
        XCTAssertFalse(DisplayHDRSupport.isAvailable(headrooms: []))
        XCTAssertFalse(DisplayHDRSupport.isAvailable(headrooms: [1, 1]), "SDR displays")
        XCTAssertTrue(DisplayHDRSupport.isAvailable(headrooms: [1, 16]), "an XDR display")
    }

    func testDisplayHDRIsKeptAsUltraWithoutAnHDRDisplay() {
        XCTAssertEqual(DisplayHDRSupport.coerced(.displayhdr, available: false), .ultra)
        XCTAssertEqual(DisplayHDRSupport.coerced(.displayhdr, available: true), .displayhdr)
        for quality in [GSPostProcessingQuality.disabled, .enabled, .ultra] {
            XCTAssertEqual(DisplayHDRSupport.coerced(quality, available: false), quality)
        }
    }
}
