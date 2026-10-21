import Darwin
import Foundation

/// The app's end of the control channel: a Unix domain socket that only its user can reach.
///
/// - The socket sits in a folder of its own made `0700`, and is itself `0600`, so no other user
///   can connect; each connection's peer is also checked (`getpeereid`) and dropped unless it is
///   this process's user.
/// - Each connection reads one request line at a time and writes its response before the next.
///   Requests go to `handler`, which the app runs on its main actor.
/// - The socket file exists only between `start()` and `stop()`; a file left by a crash is removed
///   at the next start, but a socket another process still serves is left alone (`alreadyServed`).
///   The owner must call `stop()`: the accepting thread keeps the server alive until then.
public final class ControlSocketServer: @unchecked Sendable { // Mutable state is guarded by `lock`.
    public typealias Handler = @Sendable (ControlRequest) async -> ControlResponse

    public enum StartError: Error, Equatable, CustomStringConvertible {
        /// The path is longer than a socket address holds (`ControlSocketLocation.maxPathBytes`).
        case pathTooLong(String)
        /// Another process answers on the socket.
        case alreadyServed(String)
        /// The socket's folder can't be made owner-only.
        case folder(String)
        case system(SocketError)

        public var description: String {
            switch self {
            case .pathTooLong(let path): "The control socket's path is too long: \(path)"
            case .alreadyServed(let path): "Another process already serves the control socket at \(path)"
            case .folder(let reason): "The control socket's folder can't be prepared: \(reason)"
            case .system(let error): error.description
            }
        }
    }

    public let url: URL
    private let handler: Handler
    private let lock = NSLock()
    private var listening: (socket: Int32, wake: Int32)?
    private var connections: Set<Int32> = []

    public init(url: URL, handler: @escaping Handler) {
        self.url = url
        self.handler = handler
    }

    public var isRunning: Bool { lock.withLock { listening != nil } }

    /// Creates the socket and starts accepting connections. Does nothing while running.
    public func start() throws {
        guard !isRunning else { return }
        let path = url.path(percentEncoded: false)
        guard path.utf8.count <= ControlSocketLocation.maxPathBytes else { throw StartError.pathTooLong(path) }
        try prepareFolder()
        try removeStaleSocket(at: path)

        let fd: Int32
        do {
            fd = try UnixSocket.make()
            try UnixSocket.withAddress(path) { address, length in
                guard bind(fd, address, length) == 0 else { throw SocketError("bind") }
            }
        } catch let error as SocketError {
            throw StartError.system(error)
        }
        // Owner-only, before it accepts anyone; the folder is already 0700.
        if chmod(path, 0o600) != 0 || listen(fd, 8) != 0 {
            let error = SocketError("chmod/listen")
            Darwin.close(fd)
            unlink(path)
            throw StartError.system(error)
        }
        var pipeEnds: [Int32] = [0, 0]
        guard pipe(&pipeEnds) == 0 else {
            let error = SocketError("pipe")
            Darwin.close(fd)
            unlink(path)
            throw StartError.system(error)
        }
        lock.withLock { listening = (fd, pipeEnds[1]) }
        let wakeRead = pipeEnds[0]
        let wakeWrite = pipeEnds[1]
        let thread = Thread { [weak self] in
            self?.acceptLoop(socket: fd, wake: wakeRead)
            Darwin.close(fd)
            Darwin.close(wakeRead)
            Darwin.close(wakeWrite)
        }
        thread.name = "OWE.ControlSocket.accept"
        thread.start()
    }

    /// Stops accepting, closes every connection and removes the socket file.
    public func stop() {
        let (state, open) = lock.withLock { () -> ((socket: Int32, wake: Int32)?, Set<Int32>) in
            defer { listening = nil; connections = [] }
            return (listening, connections)
        }
        guard let state else { return }
        unlink(url.path(percentEncoded: false))
        var byte: UInt8 = 1
        _ = write(state.wake, &byte, 1)
        for fd in open { shutdown(fd, SHUT_RDWR) }
    }

    // MARK: - Setup

    private func prepareFolder() throws {
        let folder = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            // An existing folder (an older run, or made by hand) is made owner-only too.
            try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                  ofItemAtPath: folder.path(percentEncoded: false))
        } catch {
            throw StartError.folder(error.localizedDescription)
        }
        // In a shared place (an isolated copy's, under /private/tmp), a folder another user made
        // first, or a link, is never listened in.
        if ControlSocketLocation.isInSharedRoot(url), !ControlSocketLocation.isOwnFolder(folder) {
            throw StartError.folder("\(folder.path(percentEncoded: false)) isn't a folder of your own")
        }
    }

    /// Removes a socket file no process answers on; fails when one does.
    private func removeStaleSocket(at path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else { return }
        if let fd = try? UnixSocket.connect(path: path) { // A failed connect is the expected, stale case.
            Darwin.close(fd)
            throw StartError.alreadyServed(path)
        }
        unlink(path)
    }

    // MARK: - Connections

    private func acceptLoop(socket fd: Int32, wake: Int32) {
        var descriptors = [pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
                           pollfd(fd: wake, events: Int16(POLLIN), revents: 0)]
        while true {
            let ready = poll(&descriptors, 2, -1)
            if ready < 0 {
                if errno == EINTR { continue }
                return
            }
            if descriptors[1].revents != 0 { return }
            guard descriptors[0].revents & Int16(POLLIN) != 0 else { continue }
            let connection = accept(fd, nil, nil)
            guard connection >= 0 else { continue }
            UnixSocket.configure(connection)
            guard UnixSocket.peerUserID(connection) == getuid() else {
                Darwin.close(connection)
                continue
            }
            let accepted = lock.withLock { () -> Bool in
                guard listening?.socket == fd else { return false }
                connections.insert(connection)
                return true
            }
            guard accepted else {
                Darwin.close(connection)
                return
            }
            let thread = Thread { [weak self] in
                self?.serve(connection)
                self?.lock.withLock { _ = self?.connections.remove(connection) }
                Darwin.close(connection)
            }
            thread.name = "OWE.ControlSocket.connection"
            thread.start()
        }
    }

    private func serve(_ fd: Int32) {
        let reader = LineReader(fd: fd)
        while true {
            let line: Data?
            do { line = try reader.readLine() } catch { return }
            guard let line else { return }
            guard !line.allSatisfy({ $0 == 0x20 || $0 == 0x0D || $0 == 0x09 }) else { continue }
            let response = respond(to: line)
            do {
                try UnixSocket.writeAll(fd, response.line())
            } catch {
                return
            }
        }
    }

    private func respond(to line: Data) -> ControlResponse {
        let request: ControlRequest
        do {
            request = try JSONDecoder().decode(ControlRequest.self, from: line)
        } catch {
            return ControlResponse(id: 0, error: ControlError(.invalidRequest, "The line isn't a control request: \(error)"))
        }
        guard request.version == ControlProtocol.version else {
            return ControlResponse(id: request.id, error: ControlError(
                .versionMismatch,
                "The request is for control protocol version \(request.version), the app speaks \(ControlProtocol.version). Use the owe-mcp inside the running app."))
        }
        return Self.wait(for: handler, request)
    }

    /// Runs `handler` and waits for it on this connection's own thread.
    private static func wait(for handler: @escaping Handler, _ request: ControlRequest) -> ControlResponse {
        let box = ResponseBox()
        let done = DispatchSemaphore(value: 0)
        Task {
            box.set(await handler(request))
            done.signal()
        }
        done.wait()
        return box.get() ?? ControlResponse(id: request.id, error: ControlError(.failed, "The app gave no response."))
    }
}

private final class ResponseBox: @unchecked Sendable { // `value` is guarded by `lock`.
    private let lock = NSLock()
    private var value: ControlResponse?

    func set(_ response: ControlResponse) { lock.withLock { value = response } }
    func get() -> ControlResponse? { lock.withLock { value } }
}
