import AppKit
import CoreGraphics
import ImageIO
import OWETheming
import XCTest
@testable import OpenWallpaperEngine

/// Settings › General › Theming is stored with the global settings, off by default, and its menu
/// bar strip reaches the desktop pictures only through `DesktopPictureTheming`.
final class ThemingSettingsTests: XCTestCase {
    func testThemingIsOffByDefaultAndRoundTrips() throws {
        XCTAssertFalse(GlobalSettings().theming.isEnabled)
        var settings = GlobalSettings()
        settings.theming.isEnabled = true
        settings.theming.accentColor = true
        settings.theming.restoresOnQuit = false
        let decoded = try JSONDecoder().decode(GlobalSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.theming, settings.theming)
    }

    func testSettingsSavedBeforeThemingKeepItsDefaults() throws {
        let stored = Data(#"{"autoStart": true}"#.utf8)
        let decoded = try JSONDecoder().decode(GlobalSettings.self, from: stored)
        XCTAssertTrue(decoded.autoStart)
        XCTAssertEqual(decoded.theming, ThemingSettings())
    }

    func testGeneralTabResetsTheming() {
        var settings = GlobalSettings()
        settings.theming.isEnabled = true
        XCTAssertTrue(SettingsTab.general.fields.contains { $0.isChanged(settings) })
        XCTAssertEqual(SettingsTab.general.resetting(settings).theming, ThemingSettings())
    }

    /// Theming › Menu Bar alone turns the desktop pictures on, so their strips appear.
    func testThemingsMenuBarAloneMakesTheDesktopPicturesFollowTheWallpapers() {
        var settings = GlobalSettings()
        settings.lockScreenPicture = false
        settings.adjustMenuBarTint = false
        XCTAssertFalse(DesktopPictureController.followsWallpapers(settings))
        settings.theming.menuBar = true
        XCTAssertFalse(DesktopPictureController.followsWallpapers(settings), "the master switch is off")
        settings.theming.isEnabled = true
        XCTAssertTrue(DesktopPictureController.followsWallpapers(settings))
    }

    /// The menu bar is transparent over the wallpaper window, so the window's top gets the strip:
    /// the colour fading out over `MenuBarStrip.fadeHeightRatio` menu bar heights.
    @MainActor
    func testTheWallpaperWindowGetsTheStripOfItsDisplay() throws {
        let strips = DesktopPictureStrips(color: ThemeColor(red: 1, green: 0, blue: 0),
                                          displays: [7: MenuBarStripDisplay(size: CGSize(width: 400, height: 300),
                                                                             menuBarHeight: 30)])
        XCTAssertNil(MenuBarStripFill(strips, display: 8), "no menu bar on display 8")
        XCTAssertNil(MenuBarStripFill(nil, display: 7))
        let fill = try XCTUnwrap(MenuBarStripFill(strips, display: 7))
        XCTAssertEqual(fill.height, 30)

        let view = WallpaperWindowContentView(content: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        view.menuBarStrip = fill
        view.layoutSubtreeIfNeeded()
        let strip = try XCTUnwrap(view.layer?.sublayers?.last as? CAGradientLayer)
        XCTAssertFalse(strip === view.content?.layer, "the strip is above the wallpaper")
        XCTAssertEqual(strip.frame, CGRect(x: 0, y: 255, width: 400, height: 45), "the top 45 points: 1.5 menu bar heights")
        XCTAssertEqual(strip.startPoint, CGPoint(x: 0.5, y: 1), "full colour at the top")
        let colors = try XCTUnwrap(strip.colors as? [CGColor])
        XCTAssertEqual(colors.first?.alpha ?? 0, 0.4, accuracy: 0.001, "40% at the top")
        XCTAssertEqual(colors.last?.alpha, 0, "gone at the bottom")
        XCTAssertEqual(colors.first?.components?.prefix(3), fill.cgColor.components?.prefix(3))

        view.menuBarStrip = nil
        XCTAssertFalse(view.layer?.sublayers?.contains { $0 is CAGradientLayer } ?? false, "Menu Bar off: the strip goes")
    }

    @MainActor
    func testNoProviderMeansNoStrips() {
        XCTAssertNil(DesktopPictureTheming.provider, "only the app's delegate registers one")
        XCTAssertNil(DesktopPictureTheming.strips())
    }

    func testDrawFillsTheStripOfTheComposedPicture() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let picture = try XCTUnwrap(context.makeImage())

        XCTAssertTrue(DesktopPictureTheming.draw(nil, over: picture, display: 1) === picture,
                      "no strips leave the picture as composed")
        XCTAssertEqual(DesktopPictureTheming.signature(nil, display: 1), "")

        let strips = DesktopPictureStrips(color: ThemeColor(red: 1, green: 1, blue: 1),
                                          displays: [1: MenuBarStripDisplay(size: CGSize(width: 32, height: 32), menuBarHeight: 8)])
        XCTAssertTrue(DesktopPictureTheming.draw(strips, over: picture, display: 2) === picture, "display 2 has no strip")
        XCTAssertNotEqual(DesktopPictureTheming.signature(strips, display: 1), "")
        let image = DesktopPictureTheming.draw(strips, over: picture, display: 1)
        var pixels = [UInt8](repeating: 0, count: 64 * 64 * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let reader = CGContext(data: buffer.baseAddress, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            reader?.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        // An 8 pt bar on a 32 pt display at 2 pixels a point fades over the top 24 rows, from 40%.
        XCTAssertEqual(Double(pixels[(1 * 64 + 10) * 4]), 0.4 * 255, accuracy: 12, "40% of the colour at the top")
        XCTAssertGreaterThan(pixels[(12 * 64 + 10) * 4], 10, "fading partway down")
        XCTAssertLessThan(pixels[(12 * 64 + 10) * 4], pixels[(1 * 64 + 10) * 4])
        XCTAssertLessThan(pixels[(30 * 64 + 10) * 4], 5, "below the fade the picture is untouched")
    }
}
