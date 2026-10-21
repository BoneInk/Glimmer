import Darwin
import Foundation

/// Why the control socket couldn't be used.
public enum ControlConnectionError: Error, Equatable, CustomStringConvertible {
    /// No socket file: the app isn't running, or control by MCP clients is off.
    case noSocket(String)
    /// The file is there but nothing answers (the app quit without removing it).
    case refused(String)
    /// The socket is in a shared place, in a folder that isn't this user's own
    /// (`ControlSocketLocation.isOwnFolder`).
    case untrustedFolder(String)
    /// The app closed the connection.
    case closed
    case timedOut
    /// The app's answer isn't a control response.
    case malformedResponse(String)
    case system(SocketError)

    public var description: String {
        switch self {
        case .noSocket(let path): "No control socket at \(path)"
        case .refused(let path): "Nothing answers on the control socket at \(path)"
        case .untrustedFolder(let path): "The control socket's folder \(path) isn't yours; not connecting"
        case .closed: "The app closed the control connection"
        case .timedOut: "The app didn't answer in time"
        case .malformedResponse(let reason): "The app's answer couldn't be read: \(reason)"
        case .system(let error): error.description
        }
    }
}

/// A client's end of the control channel: one connection, one request at a time.
public final class ControlSocketClient {
    public let url: URL
    /// How long to wait for each response.
    public var timeout: TimeInterval
    private var fd: Int32 = -1
    private var reader: LineReader?

    public init(url: URL, timeout: TimeInterval = 60) {
        self.url = url
        self.timeout = timeout
    }

    deinit { close() }

    public var isConnected: Bool { fd >= 0 }

    public func connect() throws {
        guard fd < 0 else { return }
        let path = url.path(percentEncoded: false)
        // Under /private/tmp anyone can make a folder first: only the user's own is trusted.
        let folder = url.deletingLastPathComponent()
        if ControlSocketLocation.isInSharedRoot(url), FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)),
           !ControlSocketLocation.isOwnFolder(folder) {
            throw ControlConnectionError.untrustedFolder(folder.path(percentEncoded: false))
        }
        do {
            fd = try UnixSocket.connect(path: path)
        } catch let error as SocketError {
            switch error.code {
            case ENOENT: throw ControlConnectionError.noSocket(path)
            case ECONNREFUSED: throw ControlConnectionError.refused(path)
            default: throw ControlConnectionError.system(error)
            }
        }
        reader = LineReader(fd: fd)
    }

    /// Sends `request` and returns the app's response to it, connecting first when needed.
    public func send(_ request: ControlRequest) throws -> ControlResponse {
        try connect()
        guard let reader else { throw ControlConnectionError.closed }
        do {
            try UnixSocket.writeAll(fd, request.line())
            guard let line = try reader.readLine(timeout: timeout) else {
                close()
                throw ControlConnectionError.closed
            }
            let response = try JSONDecoder().decode(ControlResponse.self, from: line)
            guard response.id == request.id || response.id == 0 else {
                close()
                throw ControlConnectionError.malformedResponse("response \(response.id) to request \(request.id)")
            }
            return response
        } catch let error as SocketError {
            close()
            throw error.code == EPIPE || error.code == ECONNRESET ? ControlConnectionError.closed : ControlConnectionError.system(error)
        } catch LineReader.ReadError.timedOut {
            close()
            throw ControlConnectionError.timedOut
        } catch LineReader.ReadError.tooLong {
            close()
            throw ControlConnectionError.malformedResponse("longer than \(ControlProtocol.maxLineBytes) bytes")
        } catch let error as DecodingError {
            close()
            throw ControlConnectionError.malformedResponse(String(describing: error))
        }
    }

    public func close() {
        guard fd >= 0 else { return }
        Darwin.close(fd)
        fd = -1
        reader = nil
    }
}
