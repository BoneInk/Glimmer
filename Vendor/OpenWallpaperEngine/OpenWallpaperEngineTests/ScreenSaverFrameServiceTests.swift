import IOSurface
import Metal
import XCTest
@testable import OpenWallpaperEngine

/// The screen saver extension's XPC transport, with a fake extension connecting to the app's
/// frame service through its anonymous endpoint in this process: the rings' surfaces really cross
/// XPC (as Mach ports), and attaches count as a saver showing.
@MainActor
final class ScreenSaverFrameServiceTests: XCTestCase {
    private final class FakeExtension: NSObject, LiveSaverClientProtocol, @unchecked Sendable {
        let messages = LockedValue<[LiveSaverFramesMessage]>([])
        let stamps = LockedValue<[(Int, UInt64)]>([])
        var onMessage: (() -> Void)?
        var onStamp: (() -> Void)?

        func use(_ message: LiveSaverFramesMessage) {
            messages.mutate { $0.append(message) }
            onMessage?()
        }

        func show(ring: Int, stamp: UInt64) {
            stamps.mutate { $0.append((ring, stamp)) }
            onStamp?()
        }
    }

    private var service: ScreenSaverFrameService!
    private var fake: FakeExtension!
    private var connection: NSXPCConnection!

    override func setUp() async throws {
        service = ScreenSaverFrameService(peerRequirement: nil)
        fake = FakeExtension()
        connection = NSXPCConnection(listenerEndpoint: service.listener.endpoint)
        connection.remoteObjectInterface = LiveSaverFramesMessage.serviceInterface()
        connection.exportedInterface = LiveSaverFramesMessage.clientInterface()
        connection.exportedObject = fake
        connection.resume()
    }

    override func tearDown() async throws {
        connection.invalidate()
        service.invalidate()
    }

    private var proxy: LiveSaverServiceProtocol {
        connection.remoteObjectProxyWithErrorHandler { XCTFail("XPC: \($0)") } as! LiveSaverServiceProtocol
    }

    private func attach(_ viewID: String, preview: Bool) -> Bool {
        let replied = expectation(description: "attach replied")
        let drawing = LockedValue(false)
        proxy.attach(viewID: viewID, display: "A", isPreview: preview) { value in
            drawing.mutate { $0 = value }
            replied.fulfill()
        }
        wait(for: [replied], timeout: 5)
        return drawing.value
    }

    private func message(surfaces count: Int, live: Bool = true) throws -> LiveSaverFramesMessage {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let surfaces = try (0..<count).map { _ in try WallpaperTransitionSurface.make(SIMD2(32, 16), device: device).surface }
        let manifest = live ? ScreenSaverLiveManifest(generation: 3, frameRate: 30, rings: [
            .init(id: 0, width: 32, height: 16, surfaces: surfaces.map { IOSurfaceGetID($0) }, notifyName: "n"),
        ], displays: [.init(display: nil, ring: 0, crop: nil)]) : ScreenSaverLiveManifest(generation: 4)
        return LiveSaverFramesMessage(manifest: manifest, surfaces: surfaces)
    }

    func testAnAttachedViewCountsAsShowingButAPreviewDoesNot() {
        var alive = 0
        let pinged = expectation(description: "alive")
        pinged.expectedFulfillmentCount = 2
        service.onAlive = {
            alive += 1
            pinged.fulfill()
        }
        service.isDrawing = { true }
        XCTAssertTrue(attach("preview", preview: true), "the reply says the app draws")
        XCTAssertTrue(attach("screen", preview: false))
        proxy.ping(viewID: "preview")
        proxy.ping(viewID: "screen")
        wait(for: [pinged], timeout: 5)
        XCTAssertEqual(alive, 2, "the screen view's attach and ping, never the preview's")
    }

    func testRingsAndStampsReachTheExtension() throws {
        let received = expectation(description: "rings")
        fake.onMessage = { received.fulfill() }
        _ = attach("screen", preview: false)
        let sent = try message(surfaces: 3)
        service.use(sent)
        wait(for: [received], timeout: 5)
        let got = try XCTUnwrap(fake.messages.value.last)
        XCTAssertEqual(got.manifest, sent.manifest)
        XCTAssertTrue(got.isConsistent)
        XCTAssertEqual(got.surfaces(ofRing: 0).map(\.width), [32, 32, 32])
        XCTAssertEqual(got.surfaces.map { IOSurfaceGetID($0) }, sent.surfaces.map { IOSurfaceGetID($0) },
                       "the same surfaces, not copies")

        let stamped = expectation(description: "stamp")
        fake.onStamp = { stamped.fulfill() }
        let stamp = ScreenSaverLiveStamp(generation: 3, frame: 1, slot: 0).state
        service.show(ring: 0, stamp: stamp)
        wait(for: [stamped], timeout: 5)
        XCTAssertEqual(fake.stamps.value.first?.1, stamp)
    }

    func testALateViewGetsTheCurrentRingsWhenItAttaches() throws {
        let received = expectation(description: "rings on attach")
        fake.onMessage = { received.fulfill() }
        service.use(try message(surfaces: 3))
        _ = attach("late", preview: false)
        wait(for: [received], timeout: 5)
        XCTAssertEqual(fake.messages.value.last?.manifest.generation, 3)
    }

    func testAMessageWhoseSurfacesDontMatchItsRingsIsRejected() throws {
        let mismatched = LiveSaverFramesMessage(manifest: try message(surfaces: 3).manifest,
                                                surfaces: try message(surfaces: 2).surfaces)
        XCTAssertFalse(mismatched.isConsistent)
        XCTAssertTrue(try message(surfaces: 0, live: false).isConsistent, "no rings, no surfaces")
    }
}
