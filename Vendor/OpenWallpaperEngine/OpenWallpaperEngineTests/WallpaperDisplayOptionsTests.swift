import CoreGraphics
import XCTest
@testable import OpenWallpaperEngine

/// WE's per-wallpaper display options: the transform that places the picture on a display, and
/// the options kept per wallpaper and display.
@MainActor
final class WallpaperDisplayOptionsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName = ""
    private var folders: [URL] = []

    override func setUp() {
        super.setUp()
        suiteName = "owe-display-options-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        super.tearDown()
    }

    /// A wallpaper folder with a project.json, so it has an identity.
    private func wallpaper(_ title: String, type: String = "video", workshopID: String? = nil) throws -> WEWallpaper {
        let folder = FileManager.default.temporaryDirectory.appending(path: "owe-display-options-\(UUID())/\(workshopID ?? title)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        folders.append(folder.deletingLastPathComponent())
        let project = WEProject(file: "video.mp4", preview: "p.jpg", title: title, type: type)
        try JSONEncoder().encode(project).write(to: folder.appending(path: "project.json"))
        return WEWallpaper(using: project, where: folder)
    }

    private func assertPoint(_ point: CGPoint, _ expected: CGPoint, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(point.x, expected.x, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(point.y, expected.y, accuracy: 1e-9, file: file, line: line)
    }

    // MARK: - Transform maths

    func testIdentityLeavesThePictureAlone() {
        let options = WallpaperDisplayOptions.identity
        XCTAssertFalse(options.transformsPicture)
        XCTAssertTrue(options.transform(size: CGSize(width: 1920, height: 1080)).isIdentity)
    }

    func testZoomAndFlipAreAboutTheCentreAndTheOffsetIsAShareOfTheDisplay() {
        let size = CGSize(width: 2000, height: 1000)
        let centre = CGPoint(x: 1000, y: 500)
        var options = WallpaperDisplayOptions(zoom: 2)
        var transform = options.transform(size: size)
        assertPoint(centre.applying(transform), centre)
        assertPoint(CGPoint(x: 1500, y: 750).applying(transform), CGPoint(x: 2000, y: 1000))

        options = WallpaperDisplayOptions(flipHorizontal: true)
        transform = options.transform(size: size)
        assertPoint(CGPoint(x: 0, y: 100).applying(transform), CGPoint(x: 2000, y: 100))
        options = WallpaperDisplayOptions(flipVertical: true)
        assertPoint(CGPoint(x: 300, y: 0).applying(options.transform(size: size)), CGPoint(x: 300, y: 1000))

        // A quarter of the width right and a tenth of the height up, after the zoom.
        options = WallpaperDisplayOptions(offsetX: 0.25, offsetY: 0.1, zoom: 0.5)
        transform = options.transform(size: size)
        assertPoint(centre.applying(transform), CGPoint(x: 1500, y: 600))
        assertPoint(CGPoint(x: 0, y: 0).applying(transform), CGPoint(x: 1000, y: 350))
    }

    func testTheTransformFollowsTheLayersAnchorPoint() {
        // Core Animation applies a sublayer transform about the anchor point: the same picture
        // results whether the anchor is the corner or the centre.
        let size = CGSize(width: 800, height: 600)
        let options = WallpaperDisplayOptions(offsetX: -0.1, zoom: 1.5, flipHorizontal: true)
        let corner = options.transform(size: size, anchor: .zero)
        let anchor = CGPoint(x: 400, y: 300)
        let centred = options.transform(size: size, anchor: anchor)
        for point in [CGPoint(x: 0, y: 0), CGPoint(x: 800, y: 600), CGPoint(x: 123, y: 456)] {
            let viaCentre = CGPoint(x: point.x - anchor.x, y: point.y - anchor.y).applying(centred)
            assertPoint(CGPoint(x: viaCentre.x + anchor.x, y: viaCentre.y + anchor.y), point.applying(corner))
        }
    }

    func testValuesAreKeptInWEsRanges() throws {
        let stored = Data(#"{"offsetX": 3, "zoom": 0.01, "playbackRate": 99, "flipVertical": "yes"}"#.utf8)
        let options = try JSONDecoder().decode(WallpaperDisplayOptions.self, from: stored)
        XCTAssertEqual(options.offsetX, 1)
        XCTAssertEqual(options.zoom, WallpaperDisplayOptions.zoomRange.lowerBound)
        XCTAssertEqual(options.playbackRate, WallpaperDisplayOptions.playbackRateRange.upperBound)
        XCTAssertFalse(options.flipVertical, "an unreadable value keeps its default")
    }

    // MARK: - Persistence

    func testOptionsAreKeptPerWallpaperPerDisplay() throws {
        let rain = try wallpaper("Rain", workshopID: "123456")
        let city = try wallpaper("City")
        let store = WallpaperDisplayOptionsStore(defaults: defaults)
        let flipped = WallpaperDisplayOptions(offsetX: 0.2, flipHorizontal: true, playbackRate: 1.5)
        store.set(flipped, for: rain, on: ["1", "2"])
        store.set(WallpaperDisplayOptions(zoom: 2), for: rain, on: ["2"])
        XCTAssertEqual(store.options(for: rain, on: "1"), flipped)
        XCTAssertEqual(store.options(for: rain, on: "2"), WallpaperDisplayOptions(zoom: 2))
        XCTAssertEqual(store.options(for: rain, on: "3"), .identity)
        XCTAssertEqual(store.options(for: city, on: "1"), .identity, "another wallpaper keeps its own")

        // A new store reads them back; the Workshop item is found by its id, wherever it is.
        let reloaded = WallpaperDisplayOptionsStore(defaults: defaults)
        XCTAssertEqual(reloaded.options(for: rain, on: "1"), flipped)
        XCTAssertNotNil(reloaded.entries[WallpaperDisplayOptionsStore.key(identity: "workshop-123456", screenID: "1")])

        // Options back at their defaults aren't stored.
        reloaded.set(.identity, for: rain, on: ["1", "2"])
        XCTAssertTrue(WallpaperDisplayOptionsStore(defaults: defaults).entries.isEmpty)
    }

    func testAPreviewsOptionsStayInMemory() throws {
        let rain = try wallpaper("Rain")
        let store = WallpaperDisplayOptionsStore(defaults: nil)
        store.set(WallpaperDisplayOptions(zoom: 3), for: rain, on: ["preview"])
        XCTAssertEqual(store.options(for: rain, on: "preview").zoom, 3)
        XCTAssertNil(defaults.data(forKey: WallpaperDisplayOptionsStore.defaultsKey))
    }

    func testASharedVideoPlaysAtItsFirstDisplaysRate() throws {
        let rain = try wallpaper("Rain")
        let model = WallpaperViewModel(persistsWallpapers: false)
        XCTAssertEqual(model.displayPlaybackRate(of: rain), 1, "no display shows it")
        model.wallpapers = ["20": rain, "10": rain]
        model.setDisplayOptions(WallpaperDisplayOptions(playbackRate: 2), for: rain, on: ["20"])
        model.setDisplayOptions(WallpaperDisplayOptions(playbackRate: 0.5), for: rain, on: ["10"])
        let main = NSScreen.main.map(WallpaperViewModel.screenId(for:))
        XCTAssertEqual(model.displayPlaybackRate(of: rain), main == "20" ? 2 : 0.5)
        XCTAssertEqual(model.displayOptions(on: "20").playbackRate, 2)
    }
}
