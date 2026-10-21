// New bounded implementation based on the public LZ4 block specification (v1.10.0).
// TEX uses independent raw blocks, not Apple's framed COMPRESSION_LZ4 format.
import Foundation
import Compression

struct SceneLZ4Block {
    static func validate(_ data: Data, decodedByteCount: Int, maximumBytes: Int) throws {
        guard decodedByteCount > 0, decodedByteCount <= maximumBytes, !data.isEmpty else { throw failure() }
        let bytes = [UInt8](data)
        var input = 0, output = 0, lastMatchStart: Int?
        func length(_ nibble: Int) throws -> Int {
            var value = nibble
            if nibble == 15 {
                while true {
                    guard input < bytes.count else { throw failure() }
                    let next = Int(bytes[input]); input += 1
                    guard value <= decodedByteCount, next <= decodedByteCount - value else { throw failure() }
                    value += next
                    if next != 255 { break }
                }
            }
            return value
        }
        while input < bytes.count {
            try Task.checkCancellation()
            let token = bytes[input]; input += 1
            let literals = try length(Int(token >> 4))
            guard literals <= bytes.count - input, literals <= decodedByteCount - output else { throw failure() }
            input += literals; output += literals
            if input == bytes.count {
                guard output == decodedByteCount,
                      (lastMatchStart == nil || (literals >= 5 && decodedByteCount - lastMatchStart! >= 12)) else { throw failure() }
                return
            }
            guard bytes.count - input >= 2 else { throw failure() }
            let offset = Int(bytes[input]) | (Int(bytes[input + 1]) << 8); input += 2
            guard offset > 0, offset <= output else { throw failure() }
            let match = try length(Int(token & 15))
            guard decodedByteCount - output >= 4, match <= decodedByteCount - output - 4 else { throw failure() }
            lastMatchStart = output
            output += match + 4
        }
        throw failure()
    }

    static func decode(_ data: Data, decodedByteCount: Int, maximumBytes: Int) throws -> Data {
        try validate(data, decodedByteCount: decodedByteCount, maximumBytes: maximumBytes)
        guard decodedByteCount < Int.max else { throw failure() }
        // Apple's buffer API returns dst_size on truncated output. One extra byte
        // plus exact count prevents a declared-size allocation from masking that.
        let capacity = decodedByteCount + 1
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                compression_decode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    source.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_LZ4_RAW)
            }
        }
        guard written == decodedByteCount else { throw failure() }
        output.removeLast()
        return output
    }
    private static func failure() -> SceneWallpaperFailure {
        SceneWallpaperFailure(message: "Invalid, truncated or over-budget raw LZ4 TEX block.")
    }
}
