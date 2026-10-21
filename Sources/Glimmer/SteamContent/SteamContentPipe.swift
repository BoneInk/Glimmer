import Foundation
import Darwin

/// Bounded ordered framing. Each `next()` reads exactly one line, so the OS pipe
/// provides backpressure instead of dropping a valid burst of metadata events.
enum SteamContentPipe {
    static let lineLimit = 65_536

    struct Lines: AsyncSequence, AsyncIteratorProtocol {
        typealias Element = Data
        fileprivate let reader: Reader
        func makeAsyncIterator() -> Lines { self }
        mutating func next() async throws -> Data? {
            try Task.checkCancellation()
            let currentReader = reader
            let line = try await Task.detached { try currentReader.nextLine() }.value
            try Task.checkCancellation()
            return line
        }
    }

    fileprivate final class Reader: @unchecked Sendable {
        private let descriptor: Int32
        private var buffer = [UInt8](repeating: 0, count: 4096)
        private var cursor = 0
        private var count = 0
        private var pending = Data()
        private var ended = false

        init(_ handle: FileHandle) { descriptor = handle.fileDescriptor }

        func nextLine() throws -> Data? {
            guard !ended else { return nil }
            while true {
                if cursor == count {
                    repeat { count = Darwin.read(descriptor, &buffer, buffer.count) } while count < 0 && errno == EINTR
                    cursor = 0
                    if count < 0 { throw SteamContentBrokerError.protocolViolation }
                    if count == 0 {
                        ended = true
                        guard pending.isEmpty else { throw SteamContentBrokerError.protocolViolation }
                        return nil
                    }
                }
                let byte = buffer[cursor]; cursor += 1
                if byte == 10 {
                    if pending.last == 13 { pending.removeLast() }
                    guard !pending.isEmpty, String(data: pending, encoding: .utf8) != nil else {
                        throw SteamContentBrokerError.protocolViolation
                    }
                    let line = pending; pending.removeAll(keepingCapacity: true); return line
                }
                pending.append(byte)
                guard pending.count <= lineLimit else { throw SteamContentBrokerError.protocolViolation }
            }
        }
    }

    static func lines(_ handle: FileHandle) -> Lines { Lines(reader: Reader(handle)) }
}
