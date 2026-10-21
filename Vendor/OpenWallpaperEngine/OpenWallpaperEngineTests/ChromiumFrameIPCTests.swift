import IOSurface
import Metal
import XCTest
@testable import OpenWallpaperEngine

/// The XPC frame messages between the app and owe-chromium-helper, with a fake helper behind an
/// anonymous listener in this process: IOSurfaces really cross XPC, no CEF involved.
final class ChromiumFrameIPCTests: XCTestCase {
    private var listener: NSXPCListener!
    private var fakeHelper: FakeChromiumHelper!

    override func setUp() {
        fakeHelper = FakeChromiumHelper()
        listener = NSXPCListener.anonymous()
        listener.delegate = fakeHelper
        listener.resume()
    }

    override func tearDown() {
        listener.invalidate()
    }

    private func device() throws -> MTLDevice {
        try XCTUnwrap(MTLCreateSystemDefaultDevice())
    }

    private func session(onFrame: @escaping (ChromiumFrame) -> Void) throws -> ChromiumEngineSession {
        ChromiumEngineSession(connection: NSXPCConnection(listenerEndpoint: listener.endpoint), device: try device(),
                              onFrame: onFrame)
    }

    private func start(_ session: ChromiumEngineSession, width: Int = 64, height: Int = 32) -> String? {
        let replied = expectation(description: "start replied")
        let result = LockedBox<String?>(nil)
        session.start(url: URL(string: "https://example.com/")!, install: URL(fileURLWithPath: "/tmp/engine"),
                      profile: URL(fileURLWithPath: "/tmp/profile"), width: width, height: height, frameRate: 30) { error in
            result.set(error)
            replied.fulfill()
        }
        wait(for: [replied], timeout: 5)
        return result.value
    }

    func testStartPassesTheRequestToTheHelper() throws {
        let session = try session { _ in }
        defer { session.stop() }
        XCTAssertNil(start(session, width: 640, height: 360))

        let request = try XCTUnwrap(fakeHelper.lastRequest)
        XCTAssertEqual(request.url, "https://example.com/")
        XCTAssertEqual(request.engineBundle, "/tmp/engine/OWE Chromium.app")
        XCTAssertFalse(request.debugNoSandbox)
        XCTAssertEqual(request.cacheDirectory, "/tmp/profile")
        XCTAssertEqual(request.width, 640)
        XCTAssertEqual(request.height, 360)
        XCTAssertEqual(request.frameRate, 30)
    }

    func testAHelperErrorReachesTheApp() throws {
        fakeHelper.startError = "CEF didn't initialize"
        let session = try session { _ in }
        defer { session.stop() }
        XCTAssertEqual(start(session), "CEF didn't initialize")
    }

    func testFramesArriveAsTexturesOverTheSameSurface() throws {
        let frames = LockedBox<[ChromiumFrame]>([])
        let received = expectation(description: "frames")
        received.expectedFulfillmentCount = 3
        let session = try session { frame in
            frames.mutate { $0.append(frame) }
            received.fulfill()
        }
        defer { session.stop() }
        fakeHelper.framesToSend = 3
        XCTAssertNil(start(session, width: 64, height: 32))
        wait(for: [received], timeout: 5)

        let all = frames.value
        XCTAssertEqual(all.map(\.frameNumber), [1, 2, 3])
        for frame in all {
            XCTAssertEqual(frame.texture.width, 64)
            XCTAssertEqual(frame.texture.height, 32)
            XCTAssertEqual(frame.texture.pixelFormat, .bgra8Unorm)
            XCTAssertNotNil(frame.texture.iosurface)
            // The pixels the fake painted, read through the surface the app received.
            frame.surface.lock(options: .readOnly, seed: nil)
            let first = frame.surface.baseAddress.load(as: UInt32.self)
            frame.surface.unlock(options: .readOnly, seed: nil)
            XCTAssertEqual(first, FakeChromiumHelper.fill)
        }
        XCTAssertEqual(session.framesDropped, 0)
    }

    func testInvalidFramesAreDropped() throws {
        let received = expectation(description: "valid frame")
        let session = try session { frame in
            XCTAssertEqual(frame.frameNumber, 2)
            received.fulfill()
        }
        defer { session.stop() }
        fakeHelper.sendsWrongFormatFirst = true
        fakeHelper.framesToSend = 1
        XCTAssertNil(start(session))
        wait(for: [received], timeout: 5)
        XCTAssertEqual(session.framesDropped, 1)
    }

    func testFrameValidation() throws {
        let surface = try XCTUnwrap(FakeChromiumHelper.surface(width: 8, height: 8, format: ChromiumHelperIPC.pixelFormat))
        XCTAssertTrue(ChromiumFrameMessage(surface: surface, frameNumber: 1).isValid)
        XCTAssertFalse(ChromiumFrameMessage(surface: surface, frameNumber: 0).isValid)
        let rgba = try XCTUnwrap(FakeChromiumHelper.surface(width: 8, height: 8, format: 0x5247_4241)) // 'RGBA'
        XCTAssertFalse(ChromiumFrameMessage(surface: rgba, frameNumber: 1).isValid)
        XCTAssertNil(ChromiumEngineSession.texture(for: ChromiumFrameMessage(surface: rgba, frameNumber: 1), device: try device()))
    }
}

/// Stands in for owe-chromium-helper: records the start request, then paints frames filled with
/// one colour into fresh IOSurfaces and sends them back over the connection.
private final class FakeChromiumHelper: NSObject, NSXPCListenerDelegate, ChromiumHelperProtocol, @unchecked Sendable {
    struct Request {
        let url: String
        let engineBundle: String
        let debugNoSandbox: Bool
        let cacheDirectory: String
        let width: Int
        let height: Int
        let frameRate: Int
    }

    static let fill: UInt32 = 0xFF33_6699

    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var request: Request?
    var startError: String?
    var framesToSend = 0
    var sendsWrongFormatFirst = false

    var lastRequest: Request? { lock.withLock { request } }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = .chromiumHelper
        connection.exportedObject = self
        connection.remoteObjectInterface = .chromiumHost
        connection.resume()
        lock.withLock { self.connection = connection }
        return true
    }

    func start(url: String, engineBundle: String, cacheDirectory: String, width: Int, height: Int,
               frameRate: Int, debugNoSandbox: Bool, reply: @escaping (String?) -> Void) {
        lock.withLock {
            request = Request(url: url, engineBundle: engineBundle, debugNoSandbox: debugNoSandbox, cacheDirectory: cacheDirectory,
                              width: width, height: height, frameRate: frameRate)
        }
        reply(startError)
        guard startError == nil, let host = lock.withLock({ connection })?.remoteObjectProxy as? ChromiumHostProtocol else { return }
        var number: Int64 = 0
        if sendsWrongFormatFirst, let wrong = Self.surface(width: width, height: height, format: 0x5247_4241) {
            number += 1
            host.didPaint(ChromiumFrameMessage(surface: wrong, frameNumber: number))
        }
        for _ in 0..<framesToSend {
            guard let surface = Self.surface(width: width, height: height, format: ChromiumHelperIPC.pixelFormat) else { continue }
            number += 1
            host.didPaint(ChromiumFrameMessage(surface: surface, frameNumber: number))
        }
    }

    func stop() {}

    static func surface(width: Int, height: Int, format: OSType) -> IOSurface? {
        guard let surface = IOSurface(properties: [.width: width, .height: height, .bytesPerElement: 4,
                                                   .pixelFormat: format]) else { return nil }
        surface.lock(options: [], seed: nil)
        let pixels = surface.baseAddress.bindMemory(to: UInt32.self, capacity: surface.allocationSize / 4)
        for index in 0..<(surface.allocationSize / 4) { pixels[index] = fill }
        surface.unlock(options: [], seed: nil)
        return surface
    }
}

/// A value shared between XPC's queue and the test.
private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value { lock.withLock { stored } }
    func set(_ value: Value) { lock.withLock { stored = value } }
    func mutate(_ change: (inout Value) -> Void) { lock.withLock { change(&stored) } }
}
