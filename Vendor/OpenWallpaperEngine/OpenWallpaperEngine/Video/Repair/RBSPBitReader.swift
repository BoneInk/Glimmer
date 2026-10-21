import Foundation

/// Reads the fixed-length and Exp-Golomb fields of a parameter set's RBSP (H.265 §7.2, §9.2).
struct RBSPBitReader {
    private let data: Data
    private var bit = 0

    init(_ rbsp: Data) {
        data = rbsp
    }

    mutating func read(_ count: Int) throws -> UInt64 {
        var value: UInt64 = 0
        for _ in 0..<count {
            guard bit < data.count * 8 else { throw VideoRepairError.malformed("parameter set ends early") }
            let byte = data.mp4UInt8(at: bit / 8)
            value = value << 1 | UInt64((byte >> (7 - UInt8(bit % 8))) & 1)
            bit += 1
        }
        return value
    }

    mutating func skip(_ count: Int) throws {
        _ = try read(count)
    }

    /// ue(v).
    mutating func readUnsignedExpGolomb() throws -> UInt64 {
        var leadingZeros = 0
        while try read(1) == 0 {
            leadingZeros += 1
            guard leadingZeros < 32 else { throw VideoRepairError.malformed("Exp-Golomb code too long") }
        }
        return (UInt64(1) << UInt64(leadingZeros)) - 1 + (try read(leadingZeros))
    }
}
