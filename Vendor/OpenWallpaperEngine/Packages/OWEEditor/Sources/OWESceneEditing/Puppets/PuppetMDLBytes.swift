import Foundation
import simd

/// The `.mdl` primitives the editor writes (docs/models-plan.md §1.1; WEFormat's `MDLByteReader`
/// reads them): little-endian `u8/u16/u32/u64/f32`, NUL-terminated UTF-8 strings, blobs as a
/// `u32` byte length and the bytes.
struct PuppetMDLOutput {
    private(set) var bytes: [UInt8] = []

    var count: Int { bytes.count }

    mutating func u8(_ value: UInt8) { bytes.append(value) }
    mutating func u16(_ value: UInt16) { append(value) }
    mutating func u32(_ value: UInt32) { append(value) }
    mutating func i32(_ value: Int32) { append(UInt32(bitPattern: value)) }
    mutating func u64(_ value: UInt64) { append(value) }
    /// Negative zero is written as zero, so the same pose always writes the same bytes.
    mutating func f32(_ value: Float) { append((value + 0).bitPattern) }
    mutating func f32s(_ values: [Float]) { for value in values { f32(value) } }

    mutating func cstring(_ value: String) {
        bytes += Array(value.utf8).filter { $0 != 0 }
        bytes.append(0)
    }

    mutating func blob(_ data: [UInt8]) {
        u32(UInt32(data.count))
        bytes += data
    }

    mutating func raw(_ data: [UInt8]) { bytes += data }

    /// 16 floats in the file's order (a column-vector matrix's memory).
    mutating func matrix(_ m: simd_float4x4) {
        for column in [m.columns.0, m.columns.1, m.columns.2, m.columns.3] { f32s([column.x, column.y, column.z, column.w]) }
    }

    /// A section: `cstr tag`, `u32` absolute end offset, the body.
    mutating func section(_ tag: String, _ body: [UInt8]) {
        cstring(tag)
        u32(UInt32(bytes.count + 4 + body.count))
        bytes += body
    }

    private mutating func append<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value.littleEndian) { bytes += $0 }
    }
}

public enum PuppetMDLError: Error, Equatable, LocalizedError {
    case truncated(String, offset: Int)
    case malformed(String)
    case notAModel
    /// A rig the editor can't hold: no mesh, no skeleton, or a vertex format without positions.
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .truncated(let what, let offset): return "The model ends early (\(what) at \(offset))."
        case .malformed(let reason): return "The model is malformed: \(reason)."
        case .notAModel: return "The file isn't a Wallpaper Engine model."
        case .unsupported(let reason): return "The puppet can't be edited: \(reason)."
        }
    }
}

/// WE's 26 vertex attributes in interleaving order with their bits and sizes (docs/models-plan.md
/// §1.2; `MDLVertexAttribute`).
enum PuppetVertexLayout {
    static let order: [(mask: UInt32, size: Int)] = [
        (0x1, 12), (0x10000, 16), (0x2000000, 12), (0x2, 12), (0x4, 16), (0x800000, 16), (0x1000000, 16),
        (0x8, 8), (0x10, 12), (0x20, 16), (0x40, 8), (0x80, 12), (0x100, 16), (0x200, 8), (0x400, 12), (0x800, 16),
        (0x1000, 8), (0x2000, 12), (0x4000, 16), (0x20000, 8), (0x40000, 12), (0x80000, 16), (0x100000, 8),
        (0x200000, 12), (0x400000, 16), (0x8000, 16),
    ]
    static let knownBits: UInt32 = order.reduce(0) { $0 | $1.mask }

    static let position: UInt32 = 0x1
    static let positionVec4: UInt32 = 0x10000
    static let blendIndices: UInt32 = 0x800000
    static let blendWeights: UInt32 = 0x1000000
    static let texCoord: UInt32 = 0x8
    static let texCoordVec3: UInt32 = 0x10
    static let texCoordVec4: UInt32 = 0x20
    /// Position, blend indices, blend weights, texture coordinate: what WE's editor writes for a
    /// puppet (`0x1800009`, 52 bytes).
    static let puppet: UInt32 = position | blendIndices | blendWeights | texCoord

    static func stride(_ format: UInt32) -> Int {
        order.reduce(0) { format & $1.mask != 0 ? $0 + $1.size : $0 }
    }

    static func offset(of mask: UInt32, in format: UInt32) -> Int? {
        guard format & mask != 0 else { return nil }
        var offset = 0
        for entry in order {
            if entry.mask == mask { return offset }
            if format & entry.mask != 0 { offset += entry.size }
        }
        return nil
    }
}
