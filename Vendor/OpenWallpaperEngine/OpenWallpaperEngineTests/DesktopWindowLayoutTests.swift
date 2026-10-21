import XCTest
@testable import OpenWallpaperEngine

/// Which display a window belongs to, and what the playback rules see on each display
/// (`DesktopWindowLayout`), from synthetic window lists.
final class DesktopWindowLayoutTests: XCTestCase {
    /// The main display, 1920 × 1080 with a 25 pt menu bar and a 70 pt Dock.
    private let left = DesktopDisplay(id: "1", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                      visibleFrame: CGRect(x: 0, y: 25, width: 1920, height: 985))
    /// A second display to its right, 2560 × 1440 with a menu bar and no Dock.
    private let right = DesktopDisplay(id: "2", frame: CGRect(x: 1920, y: 0, width: 2560, height: 1440),
                                       visibleFrame: CGRect(x: 1920, y: 25, width: 2560, height: 1415))
    private var displays: [DesktopDisplay] { [left, right] }
    private let own: pid_t = 1
    private let app: pid_t = 100
    private let other: pid_t = 200

    private func conditions(_ windows: [DesktopWindow], frontmost: pid_t? = nil) -> [String: DisplayConditions] {
        DesktopWindowLayout.conditions(windows: windows, displays: displays, frontmostPID: frontmost, ignoredPIDs: [own])
    }

    // MARK: Display assignment

    func testAWindowBelongsToTheDisplayItOverlapsMost() {
        let mostlyRight = CGRect(x: 1800, y: 100, width: 800, height: 600)
        XCTAssertEqual(DesktopWindowLayout.display(of: mostlyRight, in: displays)?.id, "2")
        let mostlyLeft = CGRect(x: 1400, y: 100, width: 800, height: 600)
        XCTAssertEqual(DesktopWindowLayout.display(of: mostlyLeft, in: displays)?.id, "1")
    }

    func testAnOverlapTieGoesToTheDisplayListedFirst() {
        let straddling = CGRect(x: 1520, y: 100, width: 800, height: 600)
        XCTAssertEqual(DesktopWindowLayout.display(of: straddling, in: [left, right])?.id, "1")
        XCTAssertEqual(DesktopWindowLayout.display(of: straddling, in: [right, left])?.id, "2")
    }

    func testAWindowOffEveryDisplayBelongsToNone() {
        XCTAssertNil(DesktopWindowLayout.display(of: CGRect(x: -3000, y: 0, width: 400, height: 300), in: displays))
    }

    func testAWindowSpanningTwoDisplaysCountsOnOneOnly() {
        // Covers all of the left display and a third of the right one: it is the left one's.
        let spanning = DesktopWindow(ownerPID: other, bounds: CGRect(x: 0, y: 0, width: 2800, height: 1080))
        let result = conditions([spanning])
        XCTAssertEqual(result["1"], DisplayConditions(fullscreen: true))
        XCTAssertEqual(result["2"], DisplayConditions())
    }

    // MARK: Focused

    func testOnlyTheDisplayOfTheFrontmostApplicationsFrontWindowIsFocused() {
        let windows = [
            DesktopWindow(ownerPID: app, bounds: CGRect(x: 2100, y: 200, width: 900, height: 700)),
            DesktopWindow(ownerPID: app, bounds: CGRect(x: 100, y: 200, width: 900, height: 700)),
            DesktopWindow(ownerPID: other, bounds: CGRect(x: 300, y: 300, width: 400, height: 300)),
        ]
        let result = conditions(windows, frontmost: app)
        XCTAssertEqual(result["2"]?.focused, true, "the front window of the frontmost app is on the right display")
        XCTAssertEqual(result["1"]?.focused, false, "its other window, behind, doesn't focus the left display")
    }

    func testTheDesktopOrThisAppBeingFrontmostFocusesNothing() {
        let windows = [DesktopWindow(ownerPID: own, bounds: CGRect(x: 100, y: 100, width: 1000, height: 700)),
                       DesktopWindow(ownerPID: other, bounds: CGRect(x: 2000, y: 100, width: 1000, height: 700))]
        XCTAssertFalse(conditions(windows, frontmost: nil).values.contains { $0.focused }, "Finder's desktop")
        XCTAssertFalse(conditions(windows, frontmost: own).values.contains { $0.focused }, "this app")
    }

    func testAFrontmostApplicationWithoutAWindowHereFocusesNothing() {
        // Its windows are minimized, hidden or on another Space: not on screen.
        let windows = [DesktopWindow(ownerPID: app, bounds: CGRect(x: 100, y: 100, width: 1000, height: 700), isOnScreen: false)]
        XCTAssertFalse(conditions(windows, frontmost: app).values.contains { $0.focused })
    }

    // MARK: Maximized and fullscreen

    func testAZoomedWindowIsMaximizedOnItsDisplayOnly() {
        let zoomed = DesktopWindow(ownerPID: other, bounds: left.visibleFrame)
        let result = conditions([zoomed])
        XCTAssertEqual(result["1"], DisplayConditions(maximized: true))
        XCTAssertEqual(result["2"], DisplayConditions())
    }

    func testATiledWindowWithMarginsIsStillMaximized() {
        let tiled = DesktopWindow(ownerPID: other, bounds: right.visibleFrame.insetBy(dx: 8, dy: 8))
        XCTAssertEqual(conditions([tiled])["2"]?.maximized, true)
    }

    func testAHalfScreenWindowIsNotMaximized() {
        let half = DesktopWindow(ownerPID: other, bounds: CGRect(x: 0, y: 25, width: 960, height: 985))
        XCTAssertEqual(conditions([half])["1"], DisplayConditions())
    }

    func testAFullScreenSpaceIsFullscreenNotMaximized() {
        // A native full-screen window fills the display, menu bar area included.
        let fullScreen = DesktopWindow(ownerPID: app, bounds: right.frame)
        let result = conditions([fullScreen], frontmost: app)
        XCTAssertEqual(result["2"], DisplayConditions(focused: true, fullscreen: true))
        XCTAssertEqual(result["1"], DisplayConditions(), "the other display's desktop is unaffected")
    }

    // MARK: Windows that don't count

    func testMinimizedHiddenAndOtherSpaceWindowsAreIgnored() {
        let offScreen = DesktopWindow(ownerPID: other, bounds: left.frame, isOnScreen: false)
        XCTAssertEqual(conditions([offScreen], frontmost: other)["1"], DisplayConditions())
    }

    func testOverlaysMenuBarAndHelperWindowsAreIgnored() {
        let windows = [
            DesktopWindow(ownerPID: other, bounds: CGRect(x: 0, y: 0, width: 1920, height: 25), layer: 24),  // menu bar
            DesktopWindow(ownerPID: other, bounds: left.frame, layer: 20),  // Dock / overlay level
            DesktopWindow(ownerPID: other, bounds: left.frame, alpha: 0),  // invisible
            DesktopWindow(ownerPID: other, bounds: CGRect(x: 10, y: 10, width: 1, height: 1)),  // helper
            DesktopWindow(ownerPID: own, bounds: left.frame),  // this app's own window
            // A background agent's overlay at the normal level, e.g. a border drawn around the
            // focused window, reaching past the display's edges.
            DesktopWindow(ownerPID: other, bounds: left.frame.insetBy(dx: -13, dy: -13), ownerIsApplication: false),
        ]
        let result = conditions(windows, frontmost: other)
        XCTAssertEqual(result["1"], DisplayConditions())
        XCTAssertEqual(result["2"], DisplayConditions())
    }

    func testEveryDisplayGetsAnEntry() {
        XCTAssertEqual(Set(conditions([]).keys), ["1", "2"])
    }

    // MARK: Covered displays

    /// Two windows tiling the visible area, with the gaps macOS leaves between tiles, cover the
    /// display, though neither is maximized and the menu bar still shows the wallpaper.
    func testWindowsTilingADisplayCoverIt() {
        let leftHalf = DesktopWindow(ownerPID: app, bounds: CGRect(x: 6, y: 31, width: 948, height: 973))
        let rightHalf = DesktopWindow(ownerPID: other, bounds: CGRect(x: 966, y: 31, width: 948, height: 973))
        XCTAssertFalse(conditions([leftHalf, rightHalf])["1"]!.maximized)
        XCTAssertEqual(DesktopWindowLayout.coveredDisplays(windows: [leftHalf, rightHalf], displays: displays), ["1"])
        XCTAssertEqual(DesktopWindowLayout.coveredDisplays(windows: [leftHalf], displays: displays), [])
    }

    /// This app's own windows count (the library over a display hides it too); overlays,
    /// invisible windows and windows of other Spaces don't.
    func testCoverageCountsOwnWindowsButNotOverlays() {
        let whole = CGRect(x: 1920, y: 25, width: 2560, height: 1415)
        XCTAssertEqual(DesktopWindowLayout.coveredDisplays(
            windows: [DesktopWindow(ownerPID: own, bounds: whole)], displays: displays), ["2"])
        for window in [DesktopWindow(ownerPID: app, bounds: whole, layer: 25),
                       DesktopWindow(ownerPID: app, bounds: whole, alpha: 0),
                       DesktopWindow(ownerPID: app, bounds: whole, isOnScreen: false),
                       DesktopWindow(ownerPID: app, bounds: whole, ownerIsApplication: false)] {
            XCTAssertEqual(DesktopWindowLayout.coveredDisplays(windows: [window], displays: displays), [])
        }
    }

    /// A window spanning two displays covers its part of each.
    func testAWindowAcrossDisplaysCoversItsPartOfEach() {
        let spanning = DesktopWindow(ownerPID: app, bounds: CGRect(x: 0, y: 0, width: 4480, height: 1440))
        XCTAssertEqual(DesktopWindowLayout.coveredDisplays(windows: [spanning], displays: displays), ["1", "2"])
    }

    func testUnionAreaCountsOverlapsOnce() {
        XCTAssertEqual(DesktopWindowLayout.unionArea([]), 0)
        XCTAssertEqual(DesktopWindowLayout.unionArea([CGRect(x: 0, y: 0, width: 10, height: 10),
                                                      CGRect(x: 5, y: 5, width: 10, height: 10)]), 175)
        XCTAssertEqual(DesktopWindowLayout.unionArea([CGRect(x: 0, y: 0, width: 10, height: 10),
                                                      CGRect(x: 2, y: 2, width: 3, height: 3)]), 100)
    }
}
