import Foundation

/// The HEVC decoder configuration record (`hvcC`, ISO/IEC 14496-15 §8.3.3). An `hvc1` sample entry
/// must carry every VPS, SPS and PPS here with `array_completeness` set; `hev1` may leave them in
/// band, which AVFoundation refuses to play.
enum HEVCDecoderConfiguration {
    static let vps: UInt8 = 32
    static let sps: UInt8 = 33
    static let pps: UInt8 = 34
    static let parameterSetTypes = [vps, sps, pps]
    /// Bytes before `numOfArrays`.
    private static let fixedSize = 22

    struct NALArray: Equatable {
        /// array_completeness (bit 7), reserved (bit 6), NAL_unit_type (bits 0–5).
        var header: UInt8
        var units: [Data]
        var type: UInt8 { header & 0x3F }
    }

    static func nalType(_ unit: Data) -> UInt8 {
        (unit.mp4UInt8(at: 0) >> 1) & 0x3F
    }

    static func lengthSize(of record: Data) throws -> Int {
        guard record.count > fixedSize else { throw VideoRepairError.malformed("hvcC shorter than its fields") }
        return Int(record.mp4UInt8(at: 21) & 3) + 1
    }

    static func arrays(in record: Data) throws -> [NALArray] {
        guard record.count > fixedSize else { throw VideoRepairError.malformed("hvcC shorter than its fields") }
        var offset = fixedSize + 1
        var arrays: [NALArray] = []
        for _ in 0..<Int(record.mp4UInt8(at: fixedSize)) {
            guard offset + 3 <= record.count else { throw VideoRepairError.malformed("hvcC array truncated") }
            let header = record.mp4UInt8(at: offset)
            let count = Int(record.mp4UInt16(at: offset + 1))
            offset += 3
            var units: [Data] = []
            for _ in 0..<count {
                guard offset + 2 <= record.count else { throw VideoRepairError.malformed("hvcC NAL length truncated") }
                let length = Int(record.mp4UInt16(at: offset))
                offset += 2
                guard offset + length <= record.count else { throw VideoRepairError.malformed("hvcC NAL unit truncated") }
                units.append(record.mp4Bytes(offset..<(offset + length)))
                offset += length
            }
            arrays.append(NALArray(header: header, units: units))
        }
        return arrays
    }

    /// The record with its VPS, SPS and PPS arrays complete: the parameter sets found in band
    /// (`inBand`, a sync sample's NAL units) replace the record's own of the same type, and the
    /// record's other arrays (SEI) are kept. A record whose profile fields were never filled in
    /// takes them from the SPS.
    static func rewrite(_ record: Data, inBand: [Data]) throws -> Data {
        let existing = try arrays(in: record)
        var fixed = record.mp4Bytes(0..<fixedSize)
        var arrays: [NALArray] = []
        for type in parameterSetTypes {
            let fromSample = inBand.filter { !$0.isEmpty && nalType($0) == type }
            let fromRecord = existing.filter { $0.type == type }.flatMap(\.units)
            var units: [Data] = []
            NALUnits.appendUnique(fromSample.isEmpty ? fromRecord : fromSample, to: &units)
            guard !units.isEmpty else { throw VideoRepairError.noParameterSets("HEVC") }
            arrays.append(NALArray(header: 0x80 | type, units: units))
        }
        arrays += existing.filter { !parameterSetTypes.contains($0.type) }

        // general_profile_idc 0 is no profile: the writer left the record's fields empty.
        if fixed.mp4UInt8(at: 1) & 0x1F == 0, let firstSPS = arrays[1].units.first {
            try applySPS(firstSPS, to: &fixed)
        }
        fixed[0] = 1
        return try serialize(fixed: fixed, arrays: arrays)
    }

    private static func serialize(fixed: Data, arrays: [NALArray]) throws -> Data {
        guard arrays.count <= 0xFF else { throw VideoRepairError.unsupported("\(arrays.count) hvcC arrays") }
        var data = fixed
        data.appendMP4(UInt8(arrays.count))
        for array in arrays {
            guard array.units.count <= 0xFFFF else { throw VideoRepairError.unsupported("\(array.units.count) NAL units in one hvcC array") }
            data.appendMP4(array.header)
            data.appendMP4(UInt16(array.units.count))
            for unit in array.units {
                guard unit.count <= 0xFFFF else { throw VideoRepairError.unsupported("parameter set of \(unit.count) bytes") }
                data.appendMP4(UInt16(unit.count))
                data.append(unit)
            }
        }
        return data
    }

    /// Fills the record's profile, tier, level, chroma format and bit depths from an SPS
    /// (H.265 §7.3.2.2, §7.3.3).
    private static func applySPS(_ sps: Data, to fixed: inout Data) throws {
        let rbsp = NALUnits.rbsp(sps, headerBytes: 2)
        guard rbsp.count >= 13 else { throw VideoRepairError.malformed("HEVC SPS too short") }
        var reader = RBSPBitReader(rbsp)
        try reader.skip(4)
        let maxSubLayersMinus1 = Int(try reader.read(3))
        try reader.skip(1)
        // general_profile_space … general_level_idc: 12 bytes, byte aligned after the first byte.
        fixed.replaceSubrange(1..<13, with: rbsp.mp4Bytes(1..<13))
        try reader.skip(96)
        var profilePresent: [Bool] = []
        var levelPresent: [Bool] = []
        for _ in 0..<maxSubLayersMinus1 {
            profilePresent.append(try reader.read(1) == 1)
            levelPresent.append(try reader.read(1) == 1)
        }
        if maxSubLayersMinus1 > 0 {
            for _ in maxSubLayersMinus1..<8 { try reader.skip(2) }
        }
        for index in 0..<maxSubLayersMinus1 {
            if profilePresent[index] { try reader.skip(88) }
            if levelPresent[index] { try reader.skip(8) }
        }
        _ = try reader.readUnsignedExpGolomb() // sps_seq_parameter_set_id
        let chromaFormat = try reader.readUnsignedExpGolomb()
        if chromaFormat == 3 { try reader.skip(1) }
        _ = try reader.readUnsignedExpGolomb() // pic_width_in_luma_samples
        _ = try reader.readUnsignedExpGolomb() // pic_height_in_luma_samples
        if try reader.read(1) == 1 {
            for _ in 0..<4 { _ = try reader.readUnsignedExpGolomb() } // conformance window
        }
        let lumaDepth = try reader.readUnsignedExpGolomb()
        let chromaDepth = try reader.readUnsignedExpGolomb()
        fixed[13] |= 0xF0
        fixed[15] |= 0xFC
        fixed[16] = 0xFC | UInt8(chromaFormat & 3)
        fixed[17] = 0xF8 | UInt8(lumaDepth & 7)
        fixed[18] = 0xF8 | UInt8(chromaDepth & 7)
    }
}
