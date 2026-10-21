import AppKit
import XCTest
@testable import OpenWallpaperEngine

/// A clone's or stretch's web page runs once: which displays mirror which page, how a mirror
/// shows it and maps the mouse back onto it, and the registry that hands mirrors their page.
@MainActor
final class WebPageMirroringTests: XCTestCase {
    private let a = DisplayIdentity(screenId: "1", identity: "UUID-A", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
    private let b = DisplayIdentity(screenId: "2", identity: "UUID-B", frame: CGRect(x: 1920, y: 0, width: 1920, height: 1080))
    private let c = DisplayIdentity(screenId: "3", identity: "UUID-C", frame: CGRect(x: 0, y: 1080, width: 1920, height: 1080))

    // MARK: Which page a display shows

    func testACloneLoadsOnePageForAllItsDisplays() {
        let resolution = DisplayLayoutResolution(DisplayLayoutConfiguration(layout: .clone), displays: [a, b, c])
        let shown: Set = ["1", "2", "3"]
        XCTAssertNil(resolution.pageSource(of: "1", shown: shown), "the main clone display loads the page")
        XCTAssertEqual(resolution.pageSource(of: "2", shown: shown), "1")
        XCTAssertEqual(resolution.pageSource(of: "3", shown: shown), "1")
        XCTAssertEqual(resolution.pageMembers(of: "1", shown: shown), ["1", "2", "3"])
        XCTAssertEqual(resolution.pageMembers(of: "2", shown: shown), ["2"])
    }

    func testAStretchLoadsOneCanvasPage() {
        let resolution = DisplayLayoutResolution(DisplayLayoutConfiguration(layout: .stretch), displays: [a, b])
        XCTAssertEqual(resolution.canvases["2"], CGRect(x: 0, y: 0, width: 3840, height: 1080))
        XCTAssertEqual(resolution.pageSource(of: "2", shown: ["1", "2"]), "1")
        XCTAssertEqual(resolution.pageMembers(of: "1", shown: ["1", "2"]), ["1", "2"])
    }

    func testAMemberWhoseSourceShowsNothingLoadsItsOwnPage() {
        let resolution = DisplayLayoutResolution(DisplayLayoutConfiguration(layout: .clone), displays: [a, b])
        XCTAssertNil(resolution.pageSource(of: "2", shown: ["2"]), "the main clone display is off or stopped")
        XCTAssertEqual(resolution.pageMembers(of: "1", shown: ["1"]), ["1"], "an off display isn't the page's")
    }

    func testDisplaysOutsideGroupsLoadTheirOwnPages() {
        var layout = DisplayLayoutConfiguration()
        layout.addGroup(["UUID-A", "UUID-B"], layout: .clone)
        let resolution = DisplayLayoutResolution(layout, displays: [a, b, c])
        let shown: Set = ["1", "2", "3"]
        XCTAssertNil(resolution.pageSource(of: "3", shown: shown))
        XCTAssertEqual(resolution.pageMembers(of: "3", shown: shown), ["3"])
        XCTAssertEqual(resolution.pageMembers(of: "1", shown: shown), ["1", "2"])
    }

    func testOnlyChromiumPagesAreShared() {
        XCTAssertTrue(WebPageMirroring.canMirror(.chromium))
        XCTAssertFalse(WebPageMirroring.canMirror(.webKit), "WebKit keeps a page per display")
    }

    // MARK: How a mirror shows the page

    func testAMirrorCoversItselfWithThePage() {
        let display = CGSize(width: 1920, height: 1080)
        XCTAssertEqual(WebPageMirroring.scale(source: display, mirror: display), 1, "equal displays and stretch members")
        XCTAssertEqual(WebPageMirroring.scale(source: display, mirror: CGSize(width: 2560, height: 1440)), 4.0 / 3)
        XCTAssertEqual(WebPageMirroring.scale(source: display, mirror: CGSize(width: 1920, height: 1200)), 1200.0 / 1080,
                       "a taller display: the page covers it, cut at the sides")
    }

    func testTheMouseOverACloneMemberReachesTheSamePointOfThePage() {
        let source = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let mirror = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(WebPageMirroring.sourcePoint(CGPoint(x: 2000, y: 100), mirrorFrame: mirror, sourceFrame: source),
                       CGPoint(x: 80, y: 100))
        // A flipped member shows the page mirrored in its window.
        XCTAssertEqual(WebPageMirroring.sourcePoint(CGPoint(x: 1930, y: 100), mirrorFrame: mirror, sourceFrame: source,
                                                    mirroredIn: mirror), CGPoint(x: 1910, y: 100))
        // A larger member shows the page scaled about its centre.
        let large = CGRect(x: 1920, y: 0, width: 2560, height: 1440)
        XCTAssertEqual(WebPageMirroring.sourcePoint(CGPoint(x: large.midX, y: large.midY), mirrorFrame: large, sourceFrame: source),
                       CGPoint(x: 960, y: 540))
        XCTAssertEqual(WebPageMirroring.sourcePoint(CGPoint(x: large.minX, y: large.minY), mirrorFrame: large, sourceFrame: source),
                       CGPoint(x: 0, y: 0))
    }

    func testTheMouseOverAStretchMemberIsAlreadyOnTheCanvasPage() {
        // Both views are the canvas's size, offset in their windows: a point is the same point.
        let canvas = CGRect(x: 0, y: 0, width: 3840, height: 1080)
        XCTAssertEqual(WebPageMirroring.sourcePoint(CGPoint(x: 2500, y: 500), mirrorFrame: canvas, sourceFrame: canvas),
                       CGPoint(x: 2500, y: 500))
    }

    func testTheWallpaperIsHitWhereThePointerIsNotWhereItMapsTo() {
        var state = ChromiumMouseMapping.State()
        var landed: [NSPoint] = []
        var input = ChromiumMouseMapping.Input(type: .leftMouseDown, screenPoint: NSPoint(x: 80, y: 980))
        input.hitPoint = NSPoint(x: 2000, y: 980)
        let events = ChromiumMouseMapping.events(for: input, viewFrameInScreen: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                                 state: &state, landsOnWallpaper: { landed.append($0); return true })
        XCTAssertEqual(landed, [NSPoint(x: 2000, y: 980)], "the window under the pointer decides")
        XCTAssertEqual(events.map(\.kind), [.move, .down])
        XCTAssertEqual(events.last?.x, 80)
        XCTAssertEqual(events.last?.y, 100)
    }

    // MARK: The registry

    func testEveryMirrorShowsTheOnePageAndFollowsItsReplacement() {
        let registry = WebPageMirrorRegistry()
        let first = NSView(), second = NSView()
        let mirrors = [WebPageMirrorView(registry: registry, sourceScreenId: "1"),
                       WebPageMirrorView(registry: registry, sourceScreenId: "1")]
        // A mirror made before its source shows it once it comes.
        registry.add(mirrors[0])
        XCTAssertNil(mirrors[0].source)
        registry.setSource(first, for: "1")
        registry.add(mirrors[1])
        XCTAssertTrue(mirrors.allSatisfy { $0.source === first })
        XCTAssertEqual(registry.mirrors(of: "1").count, 2)
        // The source view made again (another wallpaper or engine): the old one leaving later
        // doesn't take the new one's mirrors.
        registry.setSource(second, for: "1")
        registry.removeSource(first, for: "1")
        XCTAssertTrue(mirrors.allSatisfy { $0.source === second })
        registry.removeSource(second, for: "1")
        XCTAssertTrue(mirrors.allSatisfy { $0.source == nil })
        registry.remove(mirrors[0])
        XCTAssertEqual(registry.mirrors(of: "1").count, 1)
    }

}
