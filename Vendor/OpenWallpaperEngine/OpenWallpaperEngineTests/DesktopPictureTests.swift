import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import OWETheming
@testable import OpenWallpaperEngine

/// Each display's desktop picture (lock screen, menu bar tint) is a picture of what that display
/// shows, always an existing file of OWE's own: the plans (layouts, display options), the drawing,
/// and the updates through a fake setter (the test host is isolated and never touches the real
/// desktop picture).
@MainActor
final class DesktopPictureTests: XCTestCase {
    private var root: URL!
    private var setter: FakeDesktopPictures!
    private var sync: DesktopPictureSync!

    private let red: [UInt8] = [255, 0, 0]
    private let blue: [UInt8] = [0, 0, 255]
    private let green: [UInt8] = [0, 96, 0]
    private let black: [UInt8] = [0, 0, 0]

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "DesktopPictureTests-\(UUID().uuidString)",
                                                                directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "app.openwallpaperengine.isolated.tests.desktoppicture.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let caches = root.appending(path: "Caches", directoryHint: .isDirectory)
        setter = FakeDesktopPictures()
        sync = DesktopPictureSync(setter: setter,
                                  files: LockScreenPicture(cache: DesktopSnapshotCache(cachesDirectory: caches), defaults: defaults),
                                  loader: DisplayPictureLoader(cachesDirectory: caches))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Fixtures

    private let left = DesktopPicturePlan.Display(id: 1, frame: CGRect(x: 0, y: 0, width: 160, height: 90), scale: 1)
    private let right = DesktopPicturePlan.Display(id: 2, frame: CGRect(x: 160, y: 0, width: 160, height: 90), scale: 1)
    private var displays: [DisplayIdentity] {
        [DisplayIdentity(screenId: "1", identity: "UUID-A", frame: left.frame),
         DisplayIdentity(screenId: "2", identity: "UUID-B", frame: right.frame)]
    }

    private func image(_ width: Int, _ height: Int, _ color: [UInt8], rightHalf: [UInt8]? = nil) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        func fill(_ color: [UInt8], _ rect: CGRect) {
            context.setFillColor(red: CGFloat(color[0]) / 255, green: CGFloat(color[1]) / 255,
                                 blue: CGFloat(color[2]) / 255, alpha: 1)
            context.fill(rect)
        }
        fill(color, CGRect(x: 0, y: 0, width: width, height: height))
        if let rightHalf { fill(rightHalf, CGRect(x: width / 2, y: 0, width: width - width / 2, height: height)) }
        return context.makeImage()!
    }

    /// A wallpaper folder with a project and, unless nil, a preview of `preview`'s colour.
    private func wallpaper(_ name: String, type: String = "scene", preview: [UInt8]? = nil) throws -> WEWallpaper {
        let folder = root.appending(path: "Library/\(name)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"type":"\#(type)","file":"scene.json"}"#.utf8).write(to: folder.appending(path: "project.json"))
        if let preview {
            let data = NSMutableData()
            let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, image(64, 64, preview), nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            try (data as Data).write(to: folder.appending(path: "preview.jpg"))
        }
        return WEWallpaper(using: WEProject(file: type == "video" ? "missing.mp4" : "scene.json",
                                            preview: preview == nil ? nil : "preview.jpg", title: name, type: type),
                           where: folder)
    }

    private func saveSnapshot(_ wallpaper: WEWallpaper, _ color: [UInt8], width: Int = 160, height: Int = 90) throws {
        let store = SceneLoadingSnapshotStore(cachesDirectory: root.appending(path: "Caches", directoryHint: .isDirectory))
        let key = try XCTUnwrap(SceneLoadingSnapshotStore.contentKey(for: wallpaper.wallpaperDirectory))
        try store.write(image(width, height, color), forWallpaperAt: wallpaper.wallpaperDirectory, contentKey: key)
    }

    private func plans(_ wallpapers: [String: WEWallpaper], layout: DisplayLayoutConfiguration = DisplayLayoutConfiguration(),
                       options: [String: WallpaperDisplayOptions] = [:]) -> [DesktopPicturePlan] {
        let resolution = DisplayLayoutResolution(layout, displays: displays)
        return DesktopPicturePlan.plans(displays: [left, right], resolution: resolution,
                                        wallpaper: { wallpapers[resolution.source(of: $0)] },
                                        options: { options[$0] ?? .identity })
    }

    /// The colour of the picture at a point given from its top-left, as fractions of its size.
    private func color(_ url: URL?, x: Double, y: Double, file: StaticString = #filePath, line: UInt = #line) throws -> [UInt8] {
        let url = try XCTUnwrap(url, file: file, line: line)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil), file: file, line: line)
        let picture = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil), file: file, line: line)
        return color(picture, x: x, y: y)
    }

    private func color(_ picture: CGImage, x: Double, y: Double) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: picture.width * picture.height * 4)
        let context = CGContext(data: &pixels, width: picture.width, height: picture.height, bitsPerComponent: 8,
                                bytesPerRow: picture.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(picture, in: CGRect(x: 0, y: 0, width: picture.width, height: picture.height))
        let index = (Int(y * Double(picture.height - 1)) * picture.width + Int(x * Double(picture.width - 1))) * 4
        return Array(pixels[index..<index + 3])
    }

    /// The top row of a menu bar strip in `strip` over `picture`: the fade's first stop,
    /// `MenuBarStrip.peakOpacity` of the colour.
    private static func strip(_ red: UInt8, _ green: UInt8, _ blue: UInt8, over picture: [UInt8]) -> [UInt8] {
        let alpha = Double(MenuBarStrip.fadeStops[0].alpha)
        return zip([red, green, blue], picture).map { UInt8((Double($0) * alpha + Double($1) * (1 - alpha)).rounded()) }
    }

    private func assertColor(_ actual: [UInt8], _ expected: [UInt8], _ message: String = "",
                             file: StaticString = #filePath, line: UInt = #line) {
        let close = zip(actual, expected).allSatisfy { abs(Int($0) - Int($1)) <= 24 }
        XCTAssertTrue(close, "\(actual) is not \(expected). \(message)", file: file, line: line)
    }

    // MARK: Plans

    /// A wallpaper change on display 2 only changes display 2's plan: each display shows its own.
    func testEachDisplayIsPlannedFromItsOwnWallpaper() throws {
        let a = try wallpaper("a")
        let b = try wallpaper("b")
        let before = plans(["1": a, "2": a])
        let after = plans(["1": a, "2": b])
        XCTAssertEqual(after[0], before[0])
        XCTAssertEqual(after[1].layers.map(\.wallpaperDirectory), [b.wallpaperDirectory])
        XCTAssertTrue(after.allSatisfy(\.isPlain))
        XCTAssertEqual(after[1].pixelSize, SIMD2(160, 90))
    }

    func testACloneMemberShowsTheSourceMirroredWhenFlipped() throws {
        let a = try wallpaper("a")
        var layout = DisplayLayoutConfiguration()
        layout.addGroup(["UUID-A", "UUID-B"], layout: .clone)
        _ = layout.toggleFlip("UUID-B", connected: ["UUID-A", "UUID-B"])
        let plans = plans(["1": a, "2": try wallpaper("b")], layout: layout)
        XCTAssertEqual(plans[1].layers.map(\.wallpaperDirectory), [a.wallpaperDirectory], "a clone shows its source's")
        XCTAssertEqual(plans[1].layers.first?.mirrored, true)
        XCTAssertFalse(plans[1].isPlain, "a mirrored picture is drawn")
        XCTAssertTrue(plans[0].isPlain)
    }

    func testAStretchedDisplayIsPlannedAsItsPartOfTheCanvas() throws {
        var layout = DisplayLayoutConfiguration()
        layout.addGroup(["UUID-A", "UUID-B"], layout: .stretch)
        let plans = plans(["1": try wallpaper("a")], layout: layout)
        XCTAssertEqual(plans[0].layers.first?.canvas, CGRect(x: 0, y: 0, width: 2, height: 1))
        XCTAssertEqual(plans[1].layers.first?.canvas, CGRect(x: -1, y: 0, width: 2, height: 1))
        XCTAssertEqual(plans[1].layers.first?.framePixelSize, SIMD2(320, 90), "the snapshot to look for is the canvas's")
    }

    func testASplitDisplayIsPlannedRegionByRegionWithEachRegionsOptions() throws {
        var layout = DisplayLayoutConfiguration()
        layout.setSplit(DisplaySplit(direction: .vertical, position: 0.5), at: "UUID-A")
        let zoomed = WallpaperDisplayOptions(zoom: 2)
        let plans = plans(["1/L": try wallpaper("a"), "1/R": try wallpaper("b")], layout: layout, options: ["1/R": zoomed])
        XCTAssertEqual(plans[0].layers.map(\.rect), [CGRect(x: 0, y: 0, width: 0.5, height: 1),
                                                     CGRect(x: 0.5, y: 0, width: 0.5, height: 1)])
        XCTAssertEqual(plans[0].layers.map(\.options), [.identity, zoomed])
    }

    // MARK: Drawing

    func testTheDrawingFollowsTheMirrorTheStretchAndTheOptions() throws {
        let halves = image(320, 90, red, rightHalf: blue)
        var layout = DisplayLayoutConfiguration()
        layout.addGroup(["UUID-A", "UUID-B"], layout: .stretch)
        let stretched = plans(["1": try wallpaper("a")], layout: layout)
        let source = DesktopPictureComposer.Source(image: halves, placement: .fill)
        let leftPicture = try XCTUnwrap(DesktopPictureComposer.compose(stretched[0], sources: [source]))
        let rightPicture = try XCTUnwrap(DesktopPictureComposer.compose(stretched[1], sources: [source]))
        assertColor(color(leftPicture, x: 0.5, y: 0.5), red, "the left display shows the canvas's left half")
        assertColor(color(rightPicture, x: 0.5, y: 0.5), blue, "the right display shows the canvas's right half")

        var mirrored = plans(["1": try wallpaper("b")])[0]
        mirrored.layers[0].mirrored = true
        let flipped = try XCTUnwrap(DesktopPictureComposer.compose(mirrored, sources: [source]))
        assertColor(color(flipped, x: 0.1, y: 0.5), blue, "a flipped clone is mirrored")

        var zoomedOut = plans(["1": try wallpaper("c")])[0]
        zoomedOut.layers[0].options = WallpaperDisplayOptions(zoom: 0.5)
        let small = try XCTUnwrap(DesktopPictureComposer.compose(zoomedOut, sources: [source]))
        assertColor(color(small, x: 0.02, y: 0.02), black, "what the picture leaves uncovered is black, as the window")
        assertColor(color(small, x: 0.4, y: 0.5), red)
    }

    // MARK: Updating

    func testEachDisplayGetsItsOwnSnapshotPinnedOutOfTheCachesReach() async throws {
        let a = try wallpaper("a")
        let b = try wallpaper("b")
        try saveSnapshot(a, red)
        try saveSnapshot(b, blue)
        await sync.update(plans(["1": a, "2": b]), placement: .fill)
        assertColor(try color(setter.pictures[1], x: 0.5, y: 0.5), red)
        assertColor(try color(setter.pictures[2], x: 0.5, y: 0.5), blue, "display 2 shows its own wallpaper, not display 1's")
        XCTAssertEqual(setter.pictures[2]?.lastPathComponent.hasPrefix("lock-2-"), true)
        // The snapshot store trims itself; the pictures in use are copies of their own.
        try FileManager.default.removeItem(at: root.appending(path: "Caches/Open Wallpaper Engine/LoadingSnapshots"))
        for url in setter.pictures.values { XCTAssertTrue(FileManager.default.fileExists(atPath: url.path)) }
    }

    /// Until a scene has a snapshot its display shows the preview, as the display itself does,
    /// never a stale or white picture; with no preview either, black. The snapshot replaces it.
    func testWithoutASnapshotThePreviewShowsThenTheSnapshotReplacesIt() async throws {
        let a = try wallpaper("a", preview: green)
        let bare = try wallpaper("bare")
        await sync.update(plans(["1": a, "2": bare]), placement: .fill)
        assertColor(try color(setter.pictures[1], x: 0.5, y: 0.5), green)
        assertColor(try color(setter.pictures[2], x: 0.5, y: 0.5), black)
        try saveSnapshot(a, red)
        await sync.update(plans(["1": a, "2": bare]), placement: .fill)
        assertColor(try color(setter.pictures[1], x: 0.5, y: 0.5), red)
    }

    func testVideoAndWebWallpapersGetPicturesToo() async throws {
        let video = try wallpaper("video", type: "video", preview: green)
        let web = try wallpaper("web", type: "web", preview: red)
        await sync.update(plans(["1": video, "2": web]), placement: .fill)
        assertColor(try color(setter.pictures[1], x: 0.5, y: 0.5), green, "a video with no frame to grab shows its preview")
        assertColor(try color(setter.pictures[2], x: 0.5, y: 0.5), red, "a page shows its preview until it draws")
        sync.webFrameCaptured(image(160, 90, blue), wallpaperDirectory: web.wallpaperDirectory)
        await sync.update(plans(["1": video, "2": web]), placement: .fill)
        assertColor(try color(setter.pictures[2], x: 0.5, y: 0.5), blue, "then the page's own snapshot")
    }

    func testAnUnchangedDisplayWritesNothing() async throws {
        let a = try wallpaper("a")
        try saveSnapshot(a, red)
        await sync.update(plans(["1": a, "2": a]), placement: .fill)
        let sets = setter.sets.count
        await sync.update(plans(["1": a, "2": a]), placement: .fill)
        XCTAssertEqual(setter.sets.count, sets)
    }

    /// Settings › Theming › Menu Bar: every display's picture gets its own menu bar strip in the
    /// scheme colour, stretched or split as well as plain; a new colour draws the pictures again.
    /// The strip is a fade (`MenuBarStrip.fadeStops`): `peakOpacity` of the colour over the picture
    /// at the top row, the picture untouched below `fadeHeightRatio` menu bar heights.
    func testThemingsMenuBarStripIsDrawnIntoEachDisplaysPicture() async throws {
        let a = try wallpaper("a")
        let b = try wallpaper("b")
        try saveSnapshot(a, red, width: 320)
        try saveSnapshot(b, blue)
        let bar = MenuBarStripDisplay(size: CGSize(width: 160, height: 90), menuBarHeight: 18)
        let white = DesktopPictureStrips(color: ThemeColor(red: 1, green: 1, blue: 1), displays: [1: bar, 2: bar])
        var layout = DisplayLayoutConfiguration()
        layout.addGroup(["UUID-A", "UUID-B"], layout: .stretch)
        await sync.update(plans(["1": a], layout: layout), placement: .fill, strips: white)
        for display: CGDirectDisplayID in [1, 2] {
            assertColor(try color(setter.pictures[display], x: 0.5, y: 0), Self.strip(255, 255, 255, over: red), "display \(display)'s strip")
            assertColor(try color(setter.pictures[display], x: 0.5, y: 0.35), red, "display \(display): below the fade")
            assertColor(try color(setter.pictures[display], x: 0.5, y: 0.6), red, "display \(display)'s part of the canvas")
        }

        await sync.update(plans(["1": a, "2": b]), placement: .fill, strips: white)
        assertColor(try color(setter.pictures[2], x: 0.5, y: 0), Self.strip(255, 255, 255, over: blue), "a plain display gets its strip too")
        assertColor(try color(setter.pictures[2], x: 0.5, y: 0.6), blue)

        let sets = setter.sets.count
        let whiteURLs = [setter.pictures[1], setter.pictures[2]]
        let green = DesktopPictureStrips(color: ThemeColor(red: 0, green: 96.0 / 255, blue: 0), displays: [1: bar, 2: bar])
        await sync.update(plans(["1": a, "2": b]), placement: .fill, strips: green)
        XCTAssertEqual(setter.sets.count, sets + 2, "a new colour draws both pictures again")
        for (index, display) in [CGDirectDisplayID(1), 2].enumerated() {
            XCTAssertNotEqual(setter.pictures[display], whiteURLs[index],
                              "display \(display): a new colour is a new file name, which macOS doesn't cache")
        }
        assertColor(try color(setter.pictures[1], x: 0.5, y: 0), Self.strip(0, 96, 0, over: red))

        await sync.update(plans(["1": a, "2": b]), placement: .fill)
        assertColor(try color(setter.pictures[2], x: 0.5, y: 0), blue, "Menu Bar off: the strip goes")
    }

    /// macOS sets a picture on the current Space only, and a wake or a reconnection may reset it.
    func testANewSpaceOrAWakeShowsTheCurrentPictureAgain() async throws {
        let a = try wallpaper("a")
        try saveSnapshot(a, red)
        await sync.update(plans(["1": a, "2": a]), placement: .fill)
        let current = try XCTUnwrap(setter.pictures[2])
        setter.pictures[2] = URL(filePath: "/System/Library/CoreServices/DefaultDesktop.heic") // another Space
        XCTAssertTrue(sync.reassert([1, 2]).isEmpty)
        XCTAssertEqual(setter.pictures[2], current)
        // An unchanged update shows it again too.
        setter.pictures[1] = nil
        await sync.update(plans(["1": a, "2": a]), placement: .fill)
        XCTAssertNotNil(setter.pictures[1])
        XCTAssertEqual(sync.reassert([3]), [3], "a display with no picture yet is drawn")
    }

    /// Another Space may still show an older picture: it stays on disk.
    func testOtherSpacesNeverPointAtAMissingFile() async throws {
        let a = try wallpaper("a")
        let b = try wallpaper("b")
        try saveSnapshot(a, red)
        try saveSnapshot(b, blue)
        await sync.update(plans(["1": a, "2": a]), placement: .fill)
        let first = try XCTUnwrap(setter.pictures[1])
        await sync.update(plans(["1": b, "2": a]), placement: .fill)
        XCTAssertNotEqual(setter.pictures[1], first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
    }

    func testRestorePutsBackTheUsersExistingPicturesAndKeepsOWEsOtherwise() async throws {
        let mine = root.appending(path: "mine.jpg")
        try Data([1]).write(to: mine)
        setter.pictures = [1: mine, 2: root.appending(path: "deleted.jpg")]
        let a = try wallpaper("a")
        try saveSnapshot(a, red)
        await sync.update(plans(["1": a, "2": a]), placement: .fill)
        let owe2 = try XCTUnwrap(setter.pictures[2])
        sync.restoreUsersPictures([1, 2], fallback: nil)
        XCTAssertEqual(setter.pictures[1], mine)
        XCTAssertEqual(setter.pictures[2], owe2, "the user's picture is gone: OWE's stays rather than a missing file")
        XCTAssertTrue(FileManager.default.fileExists(atPath: owe2.path))
    }

    // MARK: The screen saver's stills

    /// With the lock-screen picture on, the screen saver's still of each display is the desktop
    /// picture itself, hard-linked into the screen saver's folder.
    func testWithTheLockScreenPictureTheScreenSaverStillIsItsHardLink() async throws {
        let a = try wallpaper("a")
        try saveSnapshot(a, red)
        let folder = root.appending(path: "ScreenSaver", directoryHint: .isDirectory)
        let stills = ScreenSaverStillPublisher(folder: folder)
        sync.onPictureWritten = { url, display in stills.publish(url, display: "UUID-\(display)") }
        await sync.update(plans(["1": a, "2": a]), placement: .fill)
        let picture = try XCTUnwrap(setter.pictures[1])
        let still = folder.appending(path: ScreenSaverStills.fileName(display: "UUID-1", fileExtension: picture.pathExtension))
        let inode = { (url: URL) in try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int }
        XCTAssertEqual(try inode(still), try inode(picture), "the still is the lock-screen picture, linked")
    }

    /// With the lock-screen picture and the menu bar tint off, the screen saver still gets each
    /// display's picture, written for it alone: no desktop picture is set or recorded.
    func testWithoutTheLockScreenPictureTheScreenSaverStillIsWrittenAndTheDesktopUntouched() async throws {
        let a = try wallpaper("a")
        let b = try wallpaper("b")
        try saveSnapshot(a, red)
        try saveSnapshot(b, blue)
        let suite = "app.openwallpaperengine.isolated.tests.desktoppicture.saver.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let caches = root.appending(path: "Caches", directoryHint: .isDirectory)
        var files = LockScreenPicture(cache: DesktopSnapshotCache(cachesDirectory: caches), defaults: defaults)
        files.namePrefix = LockScreenPicture.saverPrefix
        let saverSync = DesktopPictureSync(setter: setter, files: files, loader: DisplayPictureLoader(cachesDirectory: caches),
                                           setsPictures: false)
        let folder = root.appending(path: "ScreenSaver", directoryHint: .isDirectory)
        let stills = ScreenSaverStillPublisher(folder: folder)
        var written: [CGDirectDisplayID: URL] = [:]
        saverSync.onPictureWritten = { url, display in
            written[display] = url
            stills.publish(url, display: "UUID-\(display)")
        }
        await saverSync.update(plans(["1": a, "2": b]), placement: .fill)
        XCTAssertTrue(setter.sets.isEmpty, "no desktop picture is set")
        XCTAssertTrue(setter.pictures.isEmpty)
        XCTAssertTrue(files.originals().isEmpty, "nothing is recorded as the user's picture")
        assertColor(try color(written[1], x: 0.5, y: 0.5), red)
        assertColor(try color(written[2], x: 0.5, y: 0.5), blue)
        XCTAssertEqual(written[1]?.lastPathComponent.hasPrefix("saver-1-"), true)
        let listed = try XCTUnwrap(ScreenSaverStills.read(folder.appending(path: ScreenSaverStills.fileName)))
        let still = try XCTUnwrap(listed.stills["UUID-2"])
        assertColor(try color(folder.appending(path: still), x: 0.5, y: 0.5), blue, "the screen saver's still of display 2")

        // A new wallpaper on display 2 writes its still again.
        try saveSnapshot(a, green)
        await saverSync.update(plans(["1": a, "2": a]), placement: .fill)
        assertColor(try color(written[2], x: 0.5, y: 0.5), green)
        XCTAssertTrue(setter.sets.isEmpty)
        saverSync.restoreUsersPictures([1, 2], fallback: nil)
        XCTAssertTrue(setter.sets.isEmpty, "and nothing is put back")
    }

    func testTheScreenSaverStillsAreWrittenAloneOnlyWhenTheDesktopPicturesDontFollow() {
        XCTAssertEqual(DesktopPictureController.mode(followsWallpapers: true, wantsScreenSaverStills: false), .desktop)
        XCTAssertEqual(DesktopPictureController.mode(followsWallpapers: true, wantsScreenSaverStills: true), .desktop)
        XCTAssertEqual(DesktopPictureController.mode(followsWallpapers: false, wantsScreenSaverStills: true), .screenSaverStills)
        XCTAssertNil(DesktopPictureController.mode(followsWallpapers: false, wantsScreenSaverStills: false))
    }
}

/// The desktop pictures of a fake desktop: one Space, ignoring the URL it already shows as macOS does.
@MainActor
private final class FakeDesktopPictures: DesktopPictureSetting {
    var pictures: [CGDirectDisplayID: URL] = [:]
    private(set) var sets: [(CGDirectDisplayID, URL)] = []

    func picture(for display: CGDirectDisplayID) -> URL? { pictures[display] }

    func setPicture(_ url: URL, for display: CGDirectDisplayID, ownPicture: Bool) throws {
        guard pictures[display] != url else { return }
        pictures[display] = url
        sets.append((display, url))
    }
}
