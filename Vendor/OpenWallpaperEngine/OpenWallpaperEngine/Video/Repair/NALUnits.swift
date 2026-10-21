import Foundation

/// NAL units as MP4 stores them (ISO/IEC 14496-15 §4.3): each one prefixed by its length in
/// `lengthSize` bytes, the size the track's decoder configuration record declares.
enum NALUnits {
    /// Splits a sample into its NAL units.
    static func split(_ sample: Data, lengthSize: Int) throws -> [Data] {
        guard [1, 2, 4].contains(lengthSize) else { throw VideoRepairError.malformed("NAL length size \(lengthSize)") }
        var units: [Data] = []
        var offset = 0
        while offset < sample.count {
            guard offset + lengthSize <= sample.count else { throw VideoRepairError.malformed("truncated NAL length") }
            let length = (0..<lengthSize).reduce(0) { $0 << 8 | Int(sample.mp4UInt8(at: offset + $1)) }
            offset += lengthSize
            guard length > 0, offset + length <= sample.count else {
                throw VideoRepairError.malformed("NAL unit of \(length) bytes overruns the sample")
            }
            units.append(sample.mp4Bytes(offset..<(offset + length)))
            offset += length
        }
        return units
    }

    /// A NAL unit's payload with the emulation prevention bytes (`00 00 03`) removed, after the
    /// first `headerBytes` bytes (the NAL unit header).
    static func rbsp(_ unit: Data, headerBytes: Int) -> Data {
        var output = Data()
        guard unit.count > headerBytes else { return output }
        var zeros = 0
        for index in headerBytes..<unit.count {
            let byte = unit.mp4UInt8(at: index)
            if zeros >= 2, byte == 3 {
                zeros = 0
                continue
            }
            zeros = byte == 0 ? zeros + 1 : 0
            output.append(byte)
        }
        return output
    }

    /// Appends each unit of `units` not already in `list`, keeping order.
    static func appendUnique(_ units: [Data], to list: inout [Data]) {
        for unit in units where !list.contains(unit) { list.append(unit) }
    }
}
