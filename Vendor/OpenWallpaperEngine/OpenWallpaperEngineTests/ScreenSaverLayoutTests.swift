import XCTest
@testable import OpenWallpaperEngine

/// The screen saver's layout (WE's `wallpaperconfigscreensaver`): its default, the loops each
/// layout plans on the displays (`ScreenSaverLayoutPlan`), the manifest's per-display videos and
/// crops, and the saver's choice among them.
final class ScreenSaverLayoutTests: XCTestCase {
    private typealias Plan = ScreenSaverLayoutPlan
    private typealias Plugin = ScreenSaverPlugin

    private let a = Plan.Display(screenId: "1", identity: "A", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), scale: 2)
    private let b = Plan.Display(screenId: "2", identity: "B", frame: CGRect(x: 1920, y: 0, width: 2560, height: 1440), scale: 1)
    private let x = Plan.Content(id: "/x", properties: ["p": "1"])
    private let y = Plan.Content(id: "/y")

    private func plan(_ layout: ScreenSaverDisplayLayout, wallpaperLayout: DisplayLayoutMode = .perDisplay,
                      resolution: DisplayLayoutResolution = .empty, displays: [Plan.Display],
                      shown: [String: Plan.Content]) -> Plan {
        Plan(layout, wallpaperLayout: wallpaperLayout, resolution: resolution, displays: displays, shown: shown)
    }

    private func resolution(_ configuration: DisplayLayoutConfiguration, _ displays: [Plan.Display]) -> DisplayLayoutResolution {
        DisplayLayoutResolution(configuration, displays: displays.map {
            DisplayIdentity(screenId: $0.screenId, identity: $0.identity, frame: $0.frame)
        })
    }

    private func assertEqual(_ rect: CGRect?, _ expected: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        guard let rect else { return XCTFail("no rect", file: file, line: line) }
        for (value, wanted) in [(rect.minX, expected.minX), (rect.minY, expected.minY),
                                (rect.width, expected.width), (rect.height, expected.height)] {
            XCTAssertEqual(value, wanted, accuracy: 1e-9, "\(rect) ≠ \(expected)", file: file, line: line)
        }
    }

    // MARK: Default

    func testTheDefaultIsSameAsWallpaper() throws {
        XCTAssertTrue(ScreenSaverDisplayLayout().sameAsWallpaper)
        let decoded = try JSONDecoder().decode(ScreenSaverDisplayLayout.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded, ScreenSaverDisplayLayout())
        let name = "owe-screensaver-layout-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(ScreenSaverDisplayLayout.load(from: defaults), ScreenSaverDisplayLayout())
        for layout in DisplayLayoutMode.allCases {
            XCTAssertEqual(decoded.effectiveLayout(wallpaperLayout: layout), layout, "follows the wallpapers' layout")
        }
        XCTAssertEqual(ScreenSaverDisplayLayout(sameAsWallpaper: false, layout: .clone).effectiveLayout(wallpaperLayout: .stretch), .clone)
    }

    // MARK: Per display

    func testPerDisplayRecordsALoopPerShownWallpaper() {
        let plan = plan(ScreenSaverDisplayLayout(), displays: [a, b], shown: ["1": x, "2": y])
        XCTAssertEqual(plan.loops.map(\.content), [x, y])
        XCTAssertEqual(plan.loops.map(\.displays), [["A"], ["B"]])
        XCTAssertEqual(plan.loops[0].sizes, [Plan.Size(pixels: SIMD2(3840, 2160), points: SIMD2(1920, 1080))])
        XCTAssertTrue(plan.loops.allSatisfy { $0.canvas == nil && $0.crops.isEmpty })
    }

    func testDisplaysShowingTheSameWallpaperShareOneLoop() {
        let plan = plan(ScreenSaverDisplayLayout(sameAsWallpaper: false, layout: .perDisplay), displays: [a, b],
                        shown: ["1": x, "2": x])
        XCTAssertEqual(plan.loops.count, 1)
        XCTAssertEqual(plan.loops[0].displays, ["A", "B"])
        XCTAssertEqual(plan.loops[0].sizes.count, 2, "recorded at the largest of both")
        XCTAssertEqual(plan.displays, ["A", "B"])
    }

    func testOtherPropertiesAreAnotherLoop() {
        let plan = plan(ScreenSaverDisplayLayout(), displays: [a, b], shown: ["1": x, "2": Plan.Content(id: "/x")])
        XCTAssertEqual(plan.loops.count, 2)
    }

    func testASplitDisplayPlaysItsFirstRegionsWallpaper() {
        var configuration = DisplayLayoutConfiguration()
        configuration.setSplit(DisplaySplit(), at: "A")
        let resolution = resolution(configuration, [a, b])
        let regions = resolution.regions["1"] ?? []
        XCTAssertGreaterThanOrEqual(regions.count, 2)
        let displayed = [regions[0].id: x, regions[1].id: y, "2": y]
        XCTAssertEqual(Plan.shown(displayed, screenIds: ["1", "2"], resolution: resolution), ["1": x, "2": y])
    }

    // MARK: Clone

    func testCloneLayoutPlaysTheMainDisplaysLoopEverywhere() {
        let plan = plan(ScreenSaverDisplayLayout(sameAsWallpaper: false, layout: .clone), displays: [a, b],
                        shown: ["1": x, "2": y])
        XCTAssertEqual(plan.loops.map(\.content), [x])
        XCTAssertEqual(plan.loops[0].displays, ["A", "B"])
        XCTAssertNil(plan.loops[0].canvas)
    }

    func testSameAsWallpaperClonesTheWallpapersCloneSource() {
        var configuration = DisplayLayoutConfiguration(layout: .clone)
        configuration.setCloneSource("B", isSource: true, connected: ["A", "B"])
        let resolution = resolution(configuration, [a, b])
        let source = resolution.clones.first?.source
        XCTAssertNotNil(source)
        let shown = resolution.shown(["1": x, "2": y])
        let plan = plan(ScreenSaverDisplayLayout(), wallpaperLayout: .clone, resolution: resolution, displays: [a, b], shown: shown)
        XCTAssertEqual(plan.loops.count, 1)
        XCTAssertEqual(plan.loops[0].content, source == "2" ? y : x)
        XCTAssertEqual(plan.loops[0].displays, ["A", "B"])
    }

    // MARK: Stretch

    func testStretchRecordsOneLoopAtTheCanvasWithEachDisplaysCrop() throws {
        // Mixed resolutions, one display left of and above the main one, a gap on the right.
        let main = Plan.Display(screenId: "1", identity: "A", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), scale: 1)
        let left = Plan.Display(screenId: "2", identity: "B", frame: CGRect(x: -1280, y: 200, width: 1280, height: 1024), scale: 1)
        let right = Plan.Display(screenId: "3", identity: "C", frame: CGRect(x: 2000, y: 0, width: 1920, height: 1080), scale: 1)
        let plan = plan(ScreenSaverDisplayLayout(sameAsWallpaper: false, layout: .stretch), displays: [main, left, right],
                        shown: ["1": x, "2": y, "3": y])
        XCTAssertEqual(plan.loops.count, 1)
        let loop = try XCTUnwrap(plan.loops.first)
        XCTAssertEqual(loop.content, x, "the main display's wallpaper")
        XCTAssertEqual(loop.canvas, CGRect(x: -1280, y: 0, width: 5200, height: 1224))
        XCTAssertEqual(loop.sizes, [Plan.Size(pixels: SIMD2(5200, 1224), points: SIMD2(5200, 1224))])
        XCTAssertEqual(loop.displays, ["A", "B", "C"])
        assertEqual(loop.crops["A"], CGRect(x: 1280.0 / 5200, y: 144.0 / 1224, width: 1920.0 / 5200, height: 1080.0 / 1224))
        assertEqual(loop.crops["B"], CGRect(x: 0, y: 0, width: 1280.0 / 5200, height: 1024.0 / 1224))
        assertEqual(loop.crops["C"], CGRect(x: 3280.0 / 5200, y: 144.0 / 1224, width: 1920.0 / 5200, height: 1080.0 / 1224))

        // The live frames list the one ring once per display, each with its crop.
        let entries = Plugin.liveDisplayEntries([loop], pixels: [SIMD2(5200, 1224)], displays: ["A", "B", "C"])
        XCTAssertEqual(entries.map(\.ring), [0, 0, 0])
        XCTAssertEqual(entries.map(\.display), ["A", "B", "C"])
        let crop = try XCTUnwrap(entries.first?.crop)
        XCTAssertEqual(crop.x, 1280.0 / 5200, accuracy: 1e-9)
        XCTAssertEqual(crop.height, 1080.0 / 1224, accuracy: 1e-9)
    }

    func testAStretchOnRetinaDisplaysIsFittedAndEven() throws {
        let wide = (0..<3).map {
            Plan.Display(screenId: "\($0)", identity: "D\($0)", frame: CGRect(x: CGFloat($0) * 2560, y: 0, width: 2560, height: 1441), scale: 2)
        }
        let plan = plan(ScreenSaverDisplayLayout(sameAsWallpaper: false, layout: .stretch), displays: wide, shown: ["0": x])
        let size = try XCTUnwrap(plan.loops.first?.sizes.first)
        XCTAssertLessThanOrEqual(max(size.pixels.x, size.pixels.y), Int(Plan.maximumDimension))
        XCTAssertEqual(size.pixels.x % 2, 0)
        XCTAssertEqual(size.pixels.y % 2, 0)
        XCTAssertEqual(size.points.y % 2, 0)
    }

    func testSameAsWallpaperKeepsTheWallpapersStretchGroup() {
        let c = Plan.Display(screenId: "3", identity: "C", frame: CGRect(x: 4480, y: 0, width: 1920, height: 1080), scale: 2)
        var configuration = DisplayLayoutConfiguration()
        configuration.addGroup(["A", "B"], layout: .stretch)
        let resolution = resolution(configuration, [a, b, c])
        let shown = resolution.shown(["1": x, "3": y])
        let plan = plan(ScreenSaverDisplayLayout(), resolution: resolution, displays: [a, b, c], shown: shown)
        XCTAssertEqual(plan.loops.map(\.content), [y, x])
        XCTAssertEqual(plan.loops.map(\.displays), [["C"], ["A", "B"]])
        XCTAssertNil(plan.loops[0].canvas)
        XCTAssertEqual(plan.loops[1].canvas, CGRect(x: 0, y: 0, width: 4480, height: 1440))

        let own = self.plan(ScreenSaverDisplayLayout(sameAsWallpaper: false, layout: .perDisplay), resolution: resolution,
                            displays: [a, b, c], shown: shown)
        XCTAssertTrue(own.loops.allSatisfy { $0.canvas == nil }, "its own per-display layout has no groups")
    }

    func testAStretchOnOneDisplayShowsTheWholeLoop() {
        let plan = plan(ScreenSaverDisplayLayout(sameAsWallpaper: false, layout: .stretch), displays: [a], shown: ["1": x])
        XCTAssertEqual(plan.loops.count, 1)
        XCTAssertNil(plan.loops[0].canvas)
    }

    // MARK: Video wallpapers

    func testAVideoWallpapersStretchIsOneLiveRingCroppedPerDisplay() throws {
        let content = Plan.Content(id: "/videos/clip")
        let plan = plan(ScreenSaverDisplayLayout(sameAsWallpaper: false, layout: .stretch), displays: [a, b],
                        shown: ["1": content])
        let loop = try XCTUnwrap(plan.loops.first)
        let canvas = try XCTUnwrap(loop.sizes.first?.pixels)
        // A 1080p video over the 4480×1440 pt canvas: the ring keeps the canvas's shape at the
        // video's scale, so each display's rect of it is its rect of the canvas.
        let ring = ScreenSaverLiveVideo.ringPixels(loop: canvas, video: SIMD2(1920, 1080), placement: .fill)
        XCTAssertLessThan(ring.x, canvas.x, "not enlarged past the video")
        XCTAssertEqual(Double(ring.x) / Double(ring.y), Double(canvas.x) / Double(canvas.y), accuracy: 0.01)
        let entries = Plugin.liveDisplayEntries([loop], pixels: [ring], displays: ["A", "B"])
        XCTAssertEqual(entries.map(\.display), ["A", "B"])
        for entry in entries {
            let crop = try XCTUnwrap(entry.crop)
            let unit = try XCTUnwrap(loop.crops[try XCTUnwrap(entry.display)])
            XCTAssertEqual(crop.x, unit.minX, accuracy: 0.002)
            XCTAssertEqual(crop.width, unit.width, accuracy: 0.002)
            XCTAssertEqual(crop.height, unit.height, accuracy: 0.002)
        }
    }

    func testACropOfAFrameFillingTheCanvasIsItsMiddleBand() {
        // A 16:9 frame filling a 4480×1440 canvas: its middle band, the right half of it for B.
        let crop = ScreenSaverManifest.Crop(CGRect(x: 0.5, y: 0, width: 0.5, height: 1), canvas: CGSize(width: 4480, height: 1440),
                                            video: CGSize(width: 1920, height: 1080))
        let band = (1920.0 / 1080) / (4480.0 / 1440)
        XCTAssertEqual(crop.x + crop.width, 1, accuracy: 1e-9)
        XCTAssertEqual(crop.height, band, accuracy: 1e-9)
        XCTAssertEqual(crop.y, (1 - band) / 2, accuracy: 1e-9)
    }
}
