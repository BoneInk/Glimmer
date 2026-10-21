import Darwin
import Foundation

/// A failed socket call, with its `errno`.
public struct SocketError: Error, Equatable, CustomStringConvertible {
    public let operation: String
    public let code: Int32

    init(_ operation: String, code: Int32 = errno) {
        self.operation = operation
        self.code = code
    }

    public var description: String { "\(operation): \(String(cString: strerror(code)))" }
}

/// The POSIX calls of the control socket: stream sockets in the local domain, read and written a
/// line at a time.
enum UnixSocket {
    /// A new socket that isn't inherited by child processes and never raises SIGPIPE.
    static func make() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError("socket") }
        configure(fd)
        return fd
    }

    static func configure(_ fd: Int32) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Runs `body` with `path` as a local-domain address; throws when the path doesn't fit.
    static func withAddress<Result>(_ path: String,
                                    _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> Result) throws -> Result {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { throw SocketError("address", code: ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                try body(address, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    /// A socket connected to the server at `path`.
    static func connect(path: String) throws -> Int32 {
        let fd = try make()
        do {
            try withAddress(path) { address, length in
                guard Darwin.connect(fd, address, length) == 0 else { throw SocketError("connect") }
            }
        } catch {
            Darwin.close(fd)
            throw error
        }
        return fd
    }

    /// Writes all of `data`, retrying after interruptions.
    static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard var pointer = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let written = Darwin.write(fd, pointer, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw SocketError("write")
                }
                remaining -= written
                pointer += written
            }
        }
    }

    /// Waits until `fd` can be read; false after `timeout` (nil: no limit).
    static func waitReadable(_ fd: Int32, timeout: TimeInterval?) throws -> Bool {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let milliseconds = timeout.map { Int32(max(0, min($0 * 1000, Double(Int32.max)))) } ?? -1
        while true {
            let ready = poll(&descriptor, 1, milliseconds)
            if ready < 0 {
                if errno == EINTR { continue }
                throw SocketError("poll")
            }
            return ready > 0
        }
    }

    /// The user id of the process at the other end of `fd`.
    static func peerUserID(_ fd: Int32) -> uid_t? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 ? uid : nil
    }
}

/// Reads newline-terminated lines from a socket.
final class LineReader {
    enum ReadError: Error, Equatable {
        case tooLong
        case timedOut
    }

    private let fd: Int32
    private var buffer = Data()
    private let maxBytes: Int

    init(fd: Int32, maxBytes: Int = ControlProtocol.maxLineBytes) {
        self.fd = fd
        self.maxBytes = maxBytes
    }

    /// The next line without its newline; nil once the other end has closed. `timeout` bounds
    /// each wait for more bytes (nil: no limit).
    func readLine(timeout: TimeInterval? = nil) throws -> Data? {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                return Data(line)
            }
            guard buffer.count <= maxBytes else { throw ReadError.tooLong }
            guard try UnixSocket.waitReadable(fd, timeout: timeout) else { throw ReadError.timedOut }
            let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw SocketError("read")
            }
            if count == 0 { return nil }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }
}
