import Darwin
import XCTest
@testable import OWEControlProtocol

final class ControlSocketTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        // Short, so the socket's path fits a socket address.
        folder = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appending(path: "owe-ctl-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder) // Already gone when the test removed it.
    }

    private var socketURL: URL { ControlSocketLocation.socketURL(supportDirectory: folder) }

    private func echoServer() -> ControlSocketServer {
        ControlSocketServer(url: socketURL) { request in
            ControlResponse(id: request.id, result: ["method": .string(request.method), "params": .object(request.params)])
        }
    }

    private func mode(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func testRoundTripAndOwnerOnlySocket() throws {
        let server = echoServer()
        try server.start()
        defer { server.stop() }

        XCTAssertEqual(try mode(of: socketURL) & 0o777, 0o600)
        XCTAssertEqual(try mode(of: socketURL.deletingLastPathComponent()) & 0o777, 0o700)

        let client = ControlSocketClient(url: socketURL, timeout: 5)
        let response = try client.send(ControlRequest(id: 7, method: "get_status", params: ["display": "1"]))
        XCTAssertEqual(response.id, 7)
        XCTAssertEqual(response.result?["method"], "get_status")
        XCTAssertEqual(response.result?["params"]?["display"], "1")

        // The same connection serves the next request.
        XCTAssertEqual(try client.send(ControlRequest(id: 8, method: "pause")).result?["method"], "pause")
    }

    func testStopRemovesTheSocket() throws {
        let server = echoServer()
        try server.start()
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketURL.path(percentEncoded: false)))
        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketURL.path(percentEncoded: false)))
        XCTAssertFalse(server.isRunning)

        let client = ControlSocketClient(url: socketURL, timeout: 1)
        XCTAssertThrowsError(try client.connect()) { error in
            XCTAssertEqual(error as? ControlConnectionError, .noSocket(socketURL.path(percentEncoded: false)))
        }
    }

    func testOpenConnectionsCloseOnStop() throws {
        let server = echoServer()
        try server.start()
        let client = ControlSocketClient(url: socketURL, timeout: 2)
        _ = try client.send(ControlRequest(id: 1, method: "ping"))
        server.stop()
        XCTAssertThrowsError(try client.send(ControlRequest(id: 2, method: "ping")))
    }

    func testMalformedLinesAndOtherVersionsAreAnswered() throws {
        let server = echoServer()
        try server.start()
        defer { server.stop() }

        let fd = try UnixSocket.connect(path: socketURL.path(percentEncoded: false))
        defer { close(fd) }
        let reader = LineReader(fd: fd)
        try UnixSocket.writeAll(fd, Data("not json\n".utf8))
        let malformed = try JSONDecoder().decode(ControlResponse.self, from: XCTUnwrap(reader.readLine(timeout: 5)))
        XCTAssertEqual(malformed.error?.code, .invalidRequest)

        try UnixSocket.writeAll(fd, Data(#"{"version":99,"id":3,"method":"pause"}"#.utf8 + [0x0A]))
        let mismatch = try JSONDecoder().decode(ControlResponse.self, from: XCTUnwrap(reader.readLine(timeout: 5)))
        XCTAssertEqual(mismatch.id, 3)
        XCTAssertEqual(mismatch.error?.code, .versionMismatch)
    }

    func testStaleSocketFileIsReplaced() throws {
        try FileManager.default.createDirectory(at: socketURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // What a crashed app leaves: a bound socket nobody listens on.
        let stale = try UnixSocket.make()
        try UnixSocket.withAddress(socketURL.path(percentEncoded: false)) { address, length in
            XCTAssertEqual(Darwin.bind(stale, address, length), 0)
        }
        close(stale)

        let server = echoServer()
        try server.start()
        defer { server.stop() }
        XCTAssertEqual(try ControlSocketClient(url: socketURL, timeout: 5).send(ControlRequest(id: 1, method: "x")).id, 1)
    }

    func testASecondServerLeavesALiveSocketAlone() throws {
        let first = echoServer()
        try first.start()
        defer { first.stop() }
        XCTAssertThrowsError(try echoServer().start()) { error in
            XCTAssertEqual(error as? ControlSocketServer.StartError, .alreadyServed(socketURL.path(percentEncoded: false)))
        }
        XCTAssertEqual(try ControlSocketClient(url: socketURL, timeout: 5).send(ControlRequest(id: 2, method: "x")).id, 2)
    }

    func testTooLongPathIsRefused() {
        let deep = URL(fileURLWithPath: "/tmp/" + String(repeating: "a", count: 120))
        let server = ControlSocketServer(url: deep) { ControlResponse(id: $0.id, result: .null) }
        XCTAssertThrowsError(try server.start()) { error in
            guard case .pathTooLong = error as? ControlSocketServer.StartError else { return XCTFail("\(error)") }
        }
    }
}
