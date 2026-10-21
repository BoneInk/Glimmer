import AppKit
import Metal
import XCTest
@testable import OpenWallpaperEngine

/// Playing a transition on the wallpaper windows: where it shows (one render per changing
/// wallpaper, a clone's and a stretch's members sharing it, a split region in its rect), the
/// change waiting for its capture, and everything freed when it ends.
@MainActor
final class WallpaperTransitionPlaybackTests: XCTestCase {
    private let displays = [
        DisplayIdentity(screenId: "1", identity: "UUID-A", frame: CGRect(x: 0, y: 0, width: 1512, height: 982)),
        DisplayIdentity(screenId: "2", identity: "UUID-B", frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440)),
    ]

    private func wallpaper(_ name: String) -> WEWallpaper {
        WEWallpaper(using: WEProject(file: "scene.json", preview: "p.jpg", title: name, type: "scene"),
                    where: URL(fileURLWithPath: "/tmp/owe-transition/\(name)"))
    }

    private func model() -> WallpaperViewModel {
        let model = WallpaperViewModel(persistsWallpapers: false)
        model.connectedDisplays = { [displays] in displays }
        model.audioOutputEnabled = false
        model.wallpapers = ["1": wallpaper("a"), "2": wallpaper("b")]
        return model
    }

    private func geometry(_ model: WallpaperViewModel, _ target: String) -> WallpaperTransitionGeometry? {
        WallpaperTransitionGeometry.make(target: target, windowIds: ["1", "2"], resolution: model.layoutResolution,
                                         frame: { model.displayRect(of: $0) }, scale: { $0 == "1" ? 2 : 1 })
    }

    // MARK: - Where it shows

    func testADisplayShowsItsOwnTransition() throws {
        let geometry = try XCTUnwrap(geometry(model(), "2"))
        XCTAssertEqual(geometry.pixelSize, SIMD2(2560, 1440))
        XCTAssertEqual(geometry.members.map(\.windowId), ["2"])
        XCTAssertEqual(geometry.members[0].contentsRect, WallpaperTransitionGeometry.wholeFrame)
        XCTAssertEqual(geometry.members[0].frame, CGRect(x: 0, y: 0, width: 2560, height: 1440))
    }

    func testACloneRendersOnceForEveryMember() throws {
        let model = model()
        model.setLayout(.clone)
        let source = model.layoutResolution.source(of: "2")
        let geometry = try XCTUnwrap(geometry(model, source))
        XCTAssertEqual(geometry.members.map(\.windowId), ["1", "2"], "both displays show the one render")
        XCTAssertTrue(geometry.members.allSatisfy { $0.contentsRect == WallpaperTransitionGeometry.wholeFrame })
        XCTAssertEqual(geometry.captureWindowId, source)
    }

    func testAStretchShowsEachMembersRectOfTheCanvas() throws {
        let model = model()
        model.setLayout(.stretch)
        let source = model.layoutResolution.source(of: "1")
        let geometry = try XCTUnwrap(geometry(model, source))
        let canvas = try XCTUnwrap(model.layoutResolution.canvases["1"])
        XCTAssertEqual(geometry.pixelSize, SIMD2(Int(canvas.width * 2), Int(canvas.height * 2)), "the densest member's pixels")
        let rects = Dictionary(uniqueKeysWithValues: geometry.members.map { ($0.windowId, $0.contentsRect) })
        XCTAssertEqual(rects["1"], DisplayCanvas.unitRect(of: displays[0].frame, in: canvas))
        XCTAssertEqual(rects["2"], DisplayCanvas.unitRect(of: displays[1].frame, in: canvas))
    }

    func testASplitRegionShowsInItsRect() throws {
        let model = model()
        model.split("2", DisplaySplit(direction: .vertical, position: 0.5))
        let region = try XCTUnwrap(model.layoutResolution.regions["2"]?.last)
        let geometry = try XCTUnwrap(geometry(model, region.id))
        XCTAssertEqual(geometry.members.map(\.windowId), ["2"])
        XCTAssertEqual(geometry.members[0].frame.width, 1280)
        XCTAssertEqual(geometry.members[0].frame.minX, 1280, "the right half, in the window's points")
        XCTAssertEqual(geometry.pixelSize, SIMD2(1280, 1440))
    }

    func testNoWindowNoTransition() {
        XCTAssertNil(WallpaperTransitionGeometry.make(target: "3", windowIds: ["1"], resolution: model().layoutResolution,
                                                      frame: { _ in nil }, scale: { _ in 1 }))
    }

    // MARK: - The change

    func testAChangeWaitsForItsCaptureAndAnotherChangeAppliesItFirst() {
        let model = model()
        let transitions = DeferringTransitions()
        model.transitions = transitions
        model.selectedScreenIds = ["1"]
        model.apply(wallpaper("c"))
        XCTAssertEqual(transitions.performed.map(\.kind), [.door])
        XCTAssertEqual(model.wallpaper(for: "1").project.title, "a", "the outgoing picture is captured first")
        model.setWallpaper(wallpaper("d"), for: "2")
        XCTAssertEqual(model.wallpaper(for: "1").project.title, "c", "a later change applies the waiting one first")
        XCTAssertEqual(model.wallpaper(for: "2").project.title, "d", "a change without a transition applies at once")
    }

    func testTheSameWallpaperDoesntTransition() {
        let model = model()
        let transitions = DeferringTransitions()
        model.transitions = transitions
        model.setWallpaper(wallpaper("a"), for: ["1"], transition: .manual)
        XCTAssertTrue(transitions.performed.isEmpty)
    }

    func testWithoutWindowsTheChangeAppliesAtOnce() {
        let model = model()
        let coordinator = WallpaperTransitionCoordinator(wallpapers: model, settings: { .playlistDefault },
                                                         windows: { [:] })
        var applied = false
        coordinator.perform(.fade, duration: 1, on: ["1"]) { applied = true }
        XCTAssertTrue(applied)
        XCTAssertFalse(coordinator.isCapturing)
        XCTAssertTrue(coordinator.players.isEmpty)
    }

    // MARK: - Freed

    private func outgoingPicture(_ device: MTLDevice, width: Int = 64, height: Int = 36) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.shaderRead]
        return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    }

    /// Waits for what `queue` was given so far to finish on the GPU, then for `freed`.
    private func waitUntilFreed(_ queue: MTLCommandQueue, _ freed: () -> Bool, _ message: String) {
        let barrier = queue.makeCommandBuffer()
        barrier?.commit()
        barrier?.waitUntilCompleted()
        XCTAssertTrue(spin(until: freed, timeout: 2), message)
    }

    func testAPlayerFreesItsFramesAndPictureWhenItEnds() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        let renderer = try WallpaperTransitionRenderer(device: device)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        try renderer.preparePipelines(for: .crt, pixelFormat: .bgra8Unorm)
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 64, height: 36))
        weak var outgoing: MTLTexture?
        weak var frames: WallpaperTransitionFrameLoop?
        var finished: [WallpaperTransitionPlayer] = []
        try autoreleasepool {
            let texture = try outgoingPicture(device)
            outgoing = texture
            let overlay = WallpaperTransitionOverlayView(frame: host.bounds, contentsRect: WallpaperTransitionGeometry.wholeFrame)
            host.addSubview(overlay)
            let player = try WallpaperTransitionPlayer(kind: .crt, duration: 1, target: "1", outgoing: texture,
                                                       pixelSize: SIMD2(64, 36), renderer: renderer, queue: queue,
                                                       overlays: [overlay])
            XCTAssertTrue(overlay.layer === overlay.metalLayer, "the frames are presented to the overlay's own layer")
            XCTAssertEqual(overlay.metalLayer.drawableSize, CGSize(width: 64, height: 36))
            XCTAssertTrue(overlay.metalLayer.framebufferOnly, "one display: nothing copies its frames")
            try player.showFirstFrame()
            XCTAssertFalse(overlay.metalLayer.presentsWithTransaction, "only the first frame goes with the transaction")
            frames = player.frames
            player.run { finished.append($0) }
            player.stop()
            XCTAssertTrue(player.isFinished)
            XCTAssertTrue(player.overlays.isEmpty)
        }
        XCTAssertEqual(finished.count, 1)
        XCTAssertTrue(host.subviews.isEmpty, "the overlay left the window")
        waitUntilFreed(queue, { outgoing == nil && frames == nil }, "the frames and the outgoing picture are freed")
    }

    func testAPlayerEndsByItselfAndFreesItsPicture() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        let renderer = try WallpaperTransitionRenderer(device: device)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        try renderer.preparePipelines(for: .fade, pixelFormat: .bgra8Unorm)
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 64, height: 36))
        weak var outgoing: MTLTexture?
        let ended = expectation(description: "the transition ends")
        var player: WallpaperTransitionPlayer?
        try autoreleasepool {
            let texture = try outgoingPicture(device)
            outgoing = texture
            // A clone: two overlays show the one render.
            let overlays = (0..<2).map { _ in
                WallpaperTransitionOverlayView(frame: host.bounds, contentsRect: WallpaperTransitionGeometry.wholeFrame)
            }
            overlays.forEach { host.addSubview($0) }
            let playing = try WallpaperTransitionPlayer(kind: .fade, duration: 0.05, target: "1", outgoing: texture,
                                                       pixelSize: SIMD2(64, 36), renderer: renderer, queue: queue,
                                                       overlays: overlays)
            XCTAssertTrue(overlays.allSatisfy { !$0.metalLayer.framebufferOnly }, "the other display's frames are copies")
            try playing.showFirstFrame()
            playing.run { _ in ended.fulfill() }
            player = playing
        }
        // Off screen, the display link may not run: the player still ends just after its time.
        wait(for: [ended], timeout: 3)
        XCTAssertEqual(player?.isFinished, true)
        XCTAssertTrue(host.subviews.isEmpty, "the overlays left the window")
        player = nil
        waitUntilFreed(queue, { outgoing == nil }, "the outgoing picture is freed")
    }

    func testTheClockHoldsForTheLeadIn() {
        let clock = WallpaperTransitionClock(startTime: 10, duration: 1)
        XCTAssertEqual(clock.progress(at: 10.05), 0)
        XCTAssertEqual(clock.progress(at: 10.6), 0.5, accuracy: 0.0001)
        XCTAssertEqual(clock.end, 11.1, accuracy: 1e-9)
    }

    func testProgressRunsOverTheTransitionTime() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        let renderer = try WallpaperTransitionRenderer(device: device)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 8, height: 8, mipmapped: false)
        descriptor.usage = [.shaderRead]
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let player = try WallpaperTransitionPlayer(kind: .fade, duration: 2, target: "1", outgoing: texture,
                                                   pixelSize: SIMD2(8, 8), renderer: renderer, queue: queue,
                                                   startTime: 100, overlays: [])
        XCTAssertEqual(player.progress(at: 100), 0, "nothing has played yet")
        XCTAssertEqual(player.progress(at: 100.1), 0, "WE holds the start for its lead-in")
        XCTAssertEqual(player.progress(at: 101.1), 0.5, accuracy: 0.0001)
        XCTAssertEqual(player.progress(at: 102.1), 1)
        XCTAssertEqual(player.progress(at: 99), 0)
        player.stop()
    }
}

/// Records transitions and applies their change only when flushed, as a capture in flight does.
@MainActor
private final class DeferringTransitions: WallpaperTransitionPerforming {
    var manualSettings = WallpaperTransitionSettings(choice: .kind(.door), milliseconds: 500)
    var performed: [(kind: WallpaperTransitionKind, screens: Set<String>)] = []
    private var pending: (@MainActor () -> Void)?

    func perform(_ kind: WallpaperTransitionKind, duration: TimeInterval, on screens: Set<String>,
                 apply: @escaping @MainActor () -> Void) {
        performed.append((kind, screens))
        pending = apply
    }

    func flushPending() {
        let apply = pending
        pending = nil
        apply?()
    }
}
