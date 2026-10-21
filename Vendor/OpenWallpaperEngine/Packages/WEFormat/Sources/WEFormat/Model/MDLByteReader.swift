import Foundation
import simd

/// The primitives of WE's `.mdl` stream reader (docs/models-plan.md §1.1; dd-models FORMAT.md §0),
/// strict: a read past the end throws `MDLError.truncated` where WE's returns zeros. No count
/// from the file sizes an allocation before the bytes it needs are known to be there.
public struct MDLByteReader {
    public let bytes: [UInt8]
    public private(set) var offset = 0

    public init(_ bytes: [UInt8]) { self.bytes = bytes }

    public var count: Int { bytes.count }

    public mutating func seek(to offset: Int) { self.offset = offset }

    public func need(_ size: Int, _ what: @autoclosure () -> String) throws {
        guard size >= 0, size <= bytes.count - offset else { throw MDLError.truncated(reading: what(), offset: offset) }
    }

    private mutating func little<T: FixedWidthInteger>(_ type: T.Type, _ what: String) throws -> T {
        let size = MemoryLayout<T>.size
        try need(size, what)
        var value: T = 0
        for index in 0..<size { value |= T(truncatingIfNeeded: bytes[offset + index]) << (8 * index) }
        offset += size
        return value
    }

    public mutating func u8() throws -> UInt8 { try little(UInt8.self, "u8") }
    public mutating func u16() throws -> UInt16 { try little(UInt16.self, "u16") }
    public mutating func u32() throws -> UInt32 { try little(UInt32.self, "u32") }
    public mutating func i32() throws -> Int32 { try little(Int32.self, "i32") }
    public mutating func u64() throws -> UInt64 { try little(UInt64.self, "u64") }
    public mutating func f32() throws -> Float { Float(bitPattern: try little(UInt32.self, "f32")) }

    /// `count` u32s.
    public mutating func u32s(_ count: Int) throws -> [UInt32] {
        try need(4 * count, "u32[\(count)]")
        return try (0..<count).map { _ in try u32() }
    }

    /// `count` f32s.
    public mutating func f32s(_ count: Int) throws -> [Float] {
        try need(4 * count, "f32[\(count)]")
        return try (0..<count).map { _ in try f32() }
    }

    public mutating func vector3() throws -> SIMD3<Float> {
        let v = try f32s(3)
        return SIMD3(v[0], v[1], v[2])
    }

    /// 16 floats: a row-vector matrix, read as four columns (see `MDLBone`).
    public mutating func matrix() throws -> simd_float4x4 {
        Self.matrix(try f32s(16))
    }

    public static func matrix(_ v: [Float]) -> simd_float4x4 {
        simd_float4x4(SIMD4(v[0], v[1], v[2], v[3]), SIMD4(v[4], v[5], v[6], v[7]),
                      SIMD4(v[8], v[9], v[10], v[11]), SIMD4(v[12], v[13], v[14], v[15]))
    }

    /// `count` raw bytes.
    public mutating func raw(_ count: Int, _ what: String) throws -> ArraySlice<UInt8> {
        try need(count, what)
        defer { offset += count }
        return bytes[offset..<(offset + count)]
    }

    /// A `u32` byte length and that many bytes (0x14009c5c0).
    public mutating func blob(_ what: String = "blob") throws -> ArraySlice<UInt8> {
        let size = Int(try u32())
        return try raw(size, "\(what)[\(size)]")
    }

    /// 0x1400d3ef0: an `i32` length, then `min(length, maximum)` bytes. WE zero-fills when the
    /// length and `maximum` bytes aren't all there; that is a truncation here.
    public mutating func capped(_ maximum: Int) throws -> (length: Int, bytes: ArraySlice<UInt8>) {
        try need(4 + maximum, "capped[\(maximum)]")
        let length = Int(try i32())
        guard length >= 0 else { throw MDLError.malformed("negative capped length at 0x\(String(offset - 4, radix: 16))") }
        let kept = Swift.min(length, maximum)
        return (length, try raw(kept, "capped"))
    }

    /// A NUL-terminated string (0x14009c500), as UTF-8 with invalid bytes replaced.
    public mutating func cstring() throws -> String {
        guard let end = bytes[offset...].firstIndex(of: 0) else {
            throw MDLError.truncated(reading: "unterminated string", offset: offset)
        }
        defer { offset = end + 1 }
        return String(decoding: bytes[offset..<end], as: UTF8.self)
    }

    /// The raw bytes of a NUL-terminated string, for tag comparisons.
    public mutating func cstringBytes() throws -> ArraySlice<UInt8> {
        guard let end = bytes[offset...].firstIndex(of: 0) else {
            throw MDLError.truncated(reading: "unterminated string", offset: offset)
        }
        defer { offset = end + 1 }
        return bytes[offset..<end]
    }

    /// The `u32` absolute end offset of a section (0x140261770).
    public mutating func sectionEnd() throws -> Int {
        let end = Int(try u32())
        guard end <= bytes.count else {
            throw MDLError.malformed("section end 0x\(String(end, radix: 16)) beyond the file (0x\(String(bytes.count, radix: 16)))")
        }
        return end
    }
}
