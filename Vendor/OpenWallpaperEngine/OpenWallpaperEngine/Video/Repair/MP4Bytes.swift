import Foundation

/// Big-endian reads and writes for ISO base media file format structures. Offsets are relative to
/// the data's own start, so slices read the same as copies; callers check bounds first.
extension Data {
    func mp4UInt8(at offset: Int) -> UInt8 {
        self[startIndex + offset]
    }

    func mp4UInt16(at offset: Int) -> UInt16 {
        UInt16(mp4UInt8(at: offset)) << 8 | UInt16(mp4UInt8(at: offset + 1))
    }

    func mp4UInt32(at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 << 8 | UInt32(mp4UInt8(at: offset + $1)) }
    }

    func mp4UInt64(at offset: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { $0 << 8 | UInt64(mp4UInt8(at: offset + $1)) }
    }

    /// The bytes `range` names, relative to the start, as a copy that indexes from zero.
    func mp4Bytes(_ range: Range<Int>) -> Data {
        Data(self[(startIndex + range.lowerBound)..<(startIndex + range.upperBound)])
    }

    /// Four ASCII characters: a box or sample entry type.
    func mp4FourCC(at offset: Int) -> String {
        String(decoding: mp4Bytes(offset..<(offset + 4)), as: UTF8.self)
    }

    mutating func appendMP4(_ value: UInt8) {
        append(value)
    }

    mutating func appendMP4(_ value: UInt16) {
        append(contentsOf: [UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    mutating func appendMP4(_ value: UInt32) {
        append(contentsOf: (0..<4).reversed().map { UInt8((value >> (8 * UInt32($0))) & 0xFF) })
    }

    mutating func appendMP4(_ value: UInt64) {
        append(contentsOf: (0..<8).reversed().map { UInt8((value >> (8 * UInt64($0))) & 0xFF) })
    }

    mutating func appendMP4FourCC(_ type: String) {
        append(contentsOf: Array(type.utf8.prefix(4)))
    }

    mutating func setMP4(_ value: UInt32, at offset: Int) {
        for index in 0..<4 {
            self[startIndex + offset + index] = UInt8((value >> (8 * UInt32(3 - index))) & 0xFF)
        }
    }

    mutating func setMP4(_ value: UInt64, at offset: Int) {
        for index in 0..<8 {
            self[startIndex + offset + index] = UInt8((value >> (8 * UInt64(7 - index))) & 0xFF)
        }
    }
}
