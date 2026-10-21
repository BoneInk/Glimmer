import AppKit
import CoreGraphics
import IOSurface
import Metal
import XCTest
@testable import OpenWallpaperEngine

/// The live screen saver's frames: rings of global surfaces, the manifest that lists them, the
/// stamps that announce each frame, and what a saver process reads back (`LiveFrameStore`).
final class ScreenSaverFramePublisherTests: XCTestCase {
    private final class RecordingNotifier: ScreenSaverFrameNotifier, @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [(String, UInt64)] = []
        var posts: [(String, UInt64)] { lock.withLock { stored } }
        func post(_ name: String, state: UInt64) { lock.withLock { stored.append((name, state)) } }
    }

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    private func publisher(_ notifier: RecordingNotifier) throws -> ScreenSaverFramePublisher {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        return ScreenSaverFramePublisher(manifestURL: folder.appending(path: ScreenSaverLiveManifest.fileName),
                                         notifier: notifier, device: device)
    }

    func testPublishListsARingOfGlobalSurfacesPerLoop() throws {
        let publisher = try publisher(RecordingNotifier())
        let previous = publisher.current.generation
        try publisher.publish(sizes: [SIMD2(64, 32), SIMD2(16, 16)],
                              displays: [.init(display: nil, ring: 0)], frameRate: 30)
        let manifest = try XCTUnwrap(ScreenSaverLiveManifest.read(folder.appending(path: ScreenSaverLiveManifest.fileName)))
        XCTAssertEqual(manifest, publisher.current)
        XCTAssertEqual(manifest.generation, ScreenSaverFramePublisher.nextGeneration(after: previous))
        XCTAssertEqual(manifest.pid, getpid())
        XCTAssertEqual(manifest.frameRate, 30)
        XCTAssertEqual(manifest.rings.map(\.surfaces.count), [ScreenSaverFramePublisher.ringSize, ScreenSaverFramePublisher.ringSize])
        XCTAssertEqual(manifest.rings.map(\.notifyName), [ScreenSaverLiveNames.frameNotification(ring: 0),
                                                          ScreenSaverLiveNames.frameNotification(ring: 1)])
        for id in manifest.rings[0].surfaces {
            // What the `.saver`'s sandboxed host does with the ids.
            let surface = try XCTUnwrap(IOSurfaceLookup(id), "surface \(id) is global")
            XCTAssertEqual(IOSurfaceGetWidth(surface), 64)
            XCTAssertEqual(IOSurfaceGetHeight(surface), 32)
        }
        XCTAssertTrue(publisher.framesMessage.isConsistent)
        XCTAssertEqual(publisher.framesMessage.surfaces(ofRing: 1).map(\.width), [16, 16, 16])
    }

    func testFramesGoRoundTheRingAndAreStampedOnceDrawn() throws {
        let notifier = RecordingNotifier()
        let publisher = try publisher(notifier)
        let stamps = LockedValue<[(Int, UInt64)]>([])
        publisher.onStamp = { ring, stamp in stamps.mutate { $0.append((ring, stamp)) } }
        try publisher.publish(sizes: [SIMD2(8, 8)], displays: [.init(display: nil, ring: 0)], frameRate: 60)
        let generation = publisher.current.generation

        let slots = (0..<4).compactMap { _ in publisher.target(ring: 0)?.slot }
        XCTAssertEqual(slots, [0, 1, 2, 0], "the slot after the newest, round the ring")
        XCTAssertNil(publisher.target(ring: 5))
        XCTAssertTrue(notifier.posts.isEmpty, "nothing is announced before the GPU is done")

        publisher.drawn(ring: 0, slot: 1, generation: generation)
        publisher.drawn(ring: 0, slot: 2, generation: generation)
        publisher.drawn(ring: 0, slot: 0, generation: generation - 1) // A frame of older rings.
        XCTAssertEqual(notifier.posts.map(\.0), [ScreenSaverLiveNames.frameNotification(ring: 0),
                                                ScreenSaverLiveNames.frameNotification(ring: 0)])
        let posted = notifier.posts.compactMap { ScreenSaverLiveStamp(state: $0.1) }
        XCTAssertEqual(posted, [ScreenSaverLiveStamp(generation: ScreenSaverLiveStamp.generation(generation), frame: 1, slot: 1),
                                ScreenSaverLiveStamp(generation: ScreenSaverLiveStamp.generation(generation), frame: 2, slot: 2)])
        XCTAssertEqual(stamps.value.map(\.1), notifier.posts.map(\.1), "the extension gets the same stamps")
    }

    func testClearListsNothingAndNewRingsReachTheExtension() throws {
        let publisher = try publisher(RecordingNotifier())
        let messages = LockedValue<[LiveSaverFramesMessage]>([])
        publisher.onRings = { message in messages.mutate { $0.append(message) } }
        try publisher.publish(sizes: [SIMD2(8, 8)], displays: [.init(display: "A", ring: 0)], frameRate: 60)
        let live = publisher.current.generation
        publisher.clear()
        let manifest = try XCTUnwrap(ScreenSaverLiveManifest.read(folder.appending(path: ScreenSaverLiveManifest.fileName)))
        XCTAssertFalse(manifest.isLive)
        XCTAssertNotEqual(manifest.generation, live, "a stamp of the old rings matches nothing")
        XCTAssertNil(publisher.target(ring: 0))
        XCTAssertEqual(messages.value.map(\.manifest.isLive), [true, false])
        XCTAssertEqual(messages.value.map(\.surfaces.count), [3, 0])
    }

    func testGenerationsWrapPastZero() {
        XCTAssertEqual(ScreenSaverFramePublisher.nextGeneration(after: 4), 5)
        XCTAssertEqual(ScreenSaverFramePublisher.nextGeneration(after: 0xFFFF), 1)
    }

    // MARK: What a saver reads

    func testTheStoreShowsTheNewestFrameOfTheCurrentRings() throws {
        let publisher = try publisher(RecordingNotifier())
        try publisher.publish(sizes: [SIMD2(8, 8)], displays: [.init(display: "A", ring: 0,
                                                                     crop: ScreenSaverManifest.Crop(x: 0, y: 0, width: 0.5, height: 1))],
                              frameRate: 60)
        let message = publisher.framesMessage
        let store = LiveFrameStore()
        store.use(message.manifest, surfaces: [0: message.surfaces(ofRing: 0)])
        let generation = ScreenSaverLiveStamp.generation(message.manifest.generation)
        XCTAssertNil(store.newestFrame(display: "A", pixels: (8, 8)), "nothing drawn yet")

        store.show(ring: 0, stamp: ScreenSaverLiveStamp(generation: generation, frame: 5, slot: 2))
        store.show(ring: 0, stamp: ScreenSaverLiveStamp(generation: generation, frame: 4, slot: 1)) // Late: ignored.
        store.show(ring: 0, stamp: ScreenSaverLiveStamp(generation: generation &+ 1, frame: 9, slot: 0)) // Other rings.
        let frame = try XCTUnwrap(store.newestFrame(display: "A", pixels: (8, 8)))
        XCTAssertEqual(frame.stamp.frame, 5)
        XCTAssertEqual(IOSurfaceGetID(frame.surface), message.manifest.rings[0].surfaces[2])
        XCTAssertEqual(frame.crop?.width, 0.5)
        XCTAssertEqual(frame.frameRate, 60)
        XCTAssertNil(store.newestFrame(display: "B", pixels: (8, 8)), "B plays its video")
    }

    func testTheStoreTellsItsViewsOfEachNewFrameAndWhetherFramesAreFresh() throws {
        let publisher = try publisher(RecordingNotifier())
        try publisher.publish(sizes: [SIMD2(8, 8)], displays: [.init(display: nil, ring: 0)], frameRate: 60)
        let message = publisher.framesMessage
        let store = LiveFrameStore()
        store.use(message.manifest, surfaces: [0: message.surfaces(ofRing: 0)])
        let generation = ScreenSaverLiveStamp.generation(message.manifest.generation)
        let heard = LockedValue(0)
        let owner = NSObject()
        store.addObserver(owner) { heard.mutate { $0 += 1 } }
        XCTAssertFalse(store.hasFreshFrame(at: 10, within: 0.5))

        store.show(ring: 0, stamp: ScreenSaverLiveStamp(generation: generation, frame: 1, slot: 0), at: 10)
        store.show(ring: 0, stamp: ScreenSaverLiveStamp(generation: generation, frame: 1, slot: 0), at: 10.1) // Not newer.
        XCTAssertEqual(heard.value, 1)
        XCTAssertTrue(store.hasFreshFrame(at: 10.4, within: 0.5))
        XCTAssertFalse(store.hasFreshFrame(at: 10.6, within: 0.5), "a repeated stamp isn't a new frame")

        store.removeObserver(owner)
        store.show(ring: 0, stamp: ScreenSaverLiveStamp(generation: generation, frame: 2, slot: 1), at: 11)
        XCTAssertEqual(heard.value, 1)
        store.use(ScreenSaverLiveManifest(), surfaces: [:])
        XCTAssertFalse(store.hasFreshFrame(at: 11, within: 0.5), "new rings start stale")
    }

    func testCountsTicksAndFramesAndRepeatsTheNewestForAStillPage() throws {
        let notifier = RecordingNotifier()
        let publisher = try publisher(notifier)
        try publisher.publish(sizes: [SIMD2(8, 8)], displays: [.init(display: nil, ring: 0)], frameRate: 60)
        let queue = try XCTUnwrap(MTLCreateSystemDefaultDevice()?.makeCommandQueue())
        publisher.repeatNewest(ring: 0, on: queue)
        XCTAssertTrue(notifier.posts.isEmpty, "nothing to repeat before the first frame")

        publisher.ticked(ring: 0)
        publisher.ticked(ring: 0)
        let target = try XCTUnwrap(publisher.target(ring: 0))
        publisher.drawn(ring: 0, slot: target.slot, generation: target.generation)
        XCTAssertEqual(publisher.takeCounts()[0], ScreenSaverFramePublisher.Counts(ticks: 2, drawn: 1))
        XCTAssertEqual(publisher.takeCounts()[0], ScreenSaverFramePublisher.Counts(), "taking them starts them again")

        let repeated = expectation(description: "repeated")
        DispatchQueue.global().async {
            while notifier.posts.count < 2 { usleep(1000) }
            repeated.fulfill()
        }
        publisher.repeatNewest(ring: 0, on: queue)
        wait(for: [repeated], timeout: 5)
        let stamps = notifier.posts.compactMap { ScreenSaverLiveStamp(state: $0.1) }
        XCTAssertEqual(stamps.map(\.frame), [1, 2])
        XCTAssertEqual(stamps.last?.slot, UInt8((target.slot + 1) % ScreenSaverFramePublisher.ringSize), "into the next slot")
    }

    func testStillsNameEachDisplaysPictureAndFallBackToAnyDisplays() throws {
        var stills = ScreenSaverStills()
        XCTAssertNil(stills.file(forDisplay: "A"))
        stills.stills = ["B": "still-B.heic"]
        XCTAssertEqual(stills.file(forDisplay: "A"), "still-B.heic", "a display not pictured yet shows another's")
        stills.stills["A"] = "still-A.jpg"
        XCTAssertEqual(stills.file(forDisplay: "A"), "still-A.jpg")
        XCTAssertEqual(ScreenSaverStills.fileName(display: "37D8832A-2D66/x", fileExtension: "heic"), "still-37D8832A-2D66_x.heic")
        stills.pick = "still-pick.jpg"
        XCTAssertEqual(stills.file(forDisplay: "A"), "still-pick.jpg", "the picked wallpaper's on every display")
        let old = try JSONDecoder().decode(ScreenSaverStills.self, from: Data(#"{"revision":1,"stills":{"A":"a.heic"}}"#.utf8))
        XCTAssertNil(old.pick, "stills written before the pick read as following the desktop")
    }

    /// A display's running scene is lent to the screen saver's ring (`ScreenSaverSharedScene`):
    /// its loaded content draws there, as the screen saver, on its own render thread, once at a
    /// time, and is given back as it was.
    @MainActor
    func testADisplaysRunningSceneIsLentToTheRingAndGivenBack() throws {
        _ = try Fixtures.assets()
        let directory = Fixtures.url("Scenes/still-layers")
        let project = try JSONDecoder().decode(WEProject.self, from: Fixtures.data("Scenes/still-layers/project.json"))
        let model = SceneContentLoader(wallpaper: WEWallpaper(using: project, where: directory))
        let renderer = try XCTUnwrap(SceneMetalRenderer(pixelFormat: .bgra8Unorm, scriptServices: nil, screenID: "test-lend"))
        let loop = SceneRenderLoop(renderer: renderer, name: "test lend")
        defer {
            loop.shutdown()
            Fixtures.removeStoredSettings(for: directory)
        }
        let content = try XCTUnwrap(model.metalContent())
        loop.thread.sync { renderer.setContent(content) }
        let publisher = try publisher(RecordingNotifier())
        try publisher.publish(sizes: [SIMD2(128, 64)], displays: [.init(display: nil, ring: 0)], frameRate: 30)
        let screen = try XCTUnwrap(NSScreen.main)
        let target = ScreenSaverLiveScene.Target(ring: 0, pixels: SIMD2(128, 64), points: SIMD2(128, 64), frameRate: 30)
        let shared = try XCTUnwrap(ScreenSaverSharedScene(renderLoop: loop, target: target, screen: screen,
                                                          publisher: publisher, name: "still-layers"))
        XCTAssertTrue(loop.isLent)
        XCTAssertNil(ScreenSaverSharedScene(renderLoop: loop, target: target, screen: screen, publisher: publisher, name: "again"),
                     "lent to one loop at a time")
        var drawn = 0
        let deadline = Date().addingTimeInterval(10)
        while drawn == 0, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            drawn += publisher.takeCounts()[0]?.drawn ?? 0
        }
        XCTAssertGreaterThan(drawn, 0, "the running scene's frames reach the ring")
        let frame = try XCTUnwrap(publisher.newestImage(ring: 0))
        XCTAssertEqual(frame.width, 128)
        let lent = loop.thread.sync { (renderer.fixedPointer, renderer.rendersScreenSaver) }
        XCTAssertEqual(lent.0, SIMD2(0.5, 0.5), "drawn as the screen saver: the pointer held at the centre")
        XCTAssertTrue(lent.1)

        shared.shutdown()
        XCTAssertFalse(loop.isLent)
        let back = loop.thread.sync { (renderer.fixedPointer, renderer.rendersScreenSaver) }
        XCTAssertNil(back.0, "given back as it was")
        XCTAssertFalse(back.1)
    }

    func testAPreviewFillsTheScreenInsteadOfStretching() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 160,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let preview = try XCTUnwrap(context.makeImage())
        let filled = try XCTUnwrap(ScreenSaverStillPublisher.filledAndBlurred(preview, pixels: SIMD2(1920, 1080)))
        XCTAssertEqual(filled.width, 1920)
        XCTAssertEqual(filled.height, 1080)
        XCTAssertNil(ScreenSaverStillPublisher.filledAndBlurred(preview, pixels: SIMD2(0, 1080)))
    }

    @MainActor
    func testThePickedWallpapersStillIsKeptAndDropped() throws {
        let shared = folder.appending(path: "shared", directoryHint: .isDirectory)
        let stills = ScreenSaverStillPublisher(folder: shared)
        let context = try XCTUnwrap(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let listedURL = shared.appending(path: ScreenSaverStills.fileName)
        stills.publishPick(image)
        let kept = expectation(description: "kept")
        func poll() {
            if ScreenSaverStills.read(listedURL)?.pick != nil { kept.fulfill() } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { MainActor.assumeIsolated { poll() } }
            }
        }
        poll()
        wait(for: [kept], timeout: 5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: shared.appending(path: ScreenSaverStillPublisher.pickFileName).path(percentEncoded: false)))
        stills.clearPick()
        XCTAssertNil(ScreenSaverStills.read(listedURL)?.pick)
        XCTAssertFalse(FileManager.default.fileExists(atPath: shared.appending(path: ScreenSaverStillPublisher.pickFileName).path(percentEncoded: false)))
    }

    @MainActor
    func testTheStillPublisherLinksTheDisplaysPictureAndListsIt() throws {
        let pictures = folder.appending(path: "pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: pictures, withIntermediateDirectories: true)
        let first = pictures.appending(path: "lock-1-a.heic"), second = pictures.appending(path: "lock-1-b.jpg")
        try Data("one".utf8).write(to: first)
        try Data("two".utf8).write(to: second)
        let shared = folder.appending(path: "shared", directoryHint: .isDirectory)
        let stills = ScreenSaverStillPublisher(folder: shared)

        stills.publish(first, display: "A")
        try FileManager.default.removeItem(at: first) // The desktop picture's slot is reused: the still stays.
        var listed = try XCTUnwrap(ScreenSaverStills.read(shared.appending(path: ScreenSaverStills.fileName)))
        XCTAssertEqual(try Data(contentsOf: shared.appending(path: try XCTUnwrap(listed.stills["A"]))), Data("one".utf8))

        stills.publish(second, display: "A")
        listed = try XCTUnwrap(ScreenSaverStills.read(shared.appending(path: ScreenSaverStills.fileName)))
        XCTAssertEqual(listed.stills["A"], "still-A.jpg")
        let files = try FileManager.default.contentsOfDirectory(atPath: shared.path(percentEncoded: false)).sorted()
        XCTAssertEqual(files, ["still-A.jpg", ScreenSaverStills.fileName], "the earlier format's still is gone, nothing staged is left")
    }
}

/// A value shared with XPC's and Metal's threads.
final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func mutate(_ body: (inout Value) -> Void) { lock.withLock { body(&stored) } }
}
