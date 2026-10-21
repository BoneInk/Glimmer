import Foundation

/// The AVC decoder configuration record (`avcC`, ISO/IEC 14496-15 §5.3.3). An `avc1` sample entry
/// must list the stream's SPS and PPS here; `avc3` may leave them in band, which AVFoundation
/// refuses to play.
enum AVCDecoderConfiguration {
    static let sps: UInt8 = 7
    static let pps: UInt8 = 8
    /// Profiles whose record carries the chroma format and bit depth fields after the PPS list.
    private static let extendedProfiles: Set<UInt8> = [100, 110, 122, 144]

    static func nalType(_ unit: Data) -> UInt8 {
        unit.mp4UInt8(at: 0) & 0x1F
    }

    static func lengthSize(of record: Data) throws -> Int {
        guard record.count >= 7 else { throw VideoRepairError.malformed("avcC shorter than its fields") }
        return Int(record.mp4UInt8(at: 4) & 3) + 1
    }

    /// The record's SPS and PPS lists, and the bytes after them.
    static func parameterSets(in record: Data) throws -> (sps: [Data], pps: [Data], tail: Data) {
        guard record.count >= 7 else { throw VideoRepairError.malformed("avcC shorter than its fields") }
        var offset = 5
        func list(count: Int) throws -> [Data] {
            try (0..<count).map { _ in
                guard offset + 2 <= record.count else { throw VideoRepairError.malformed("avcC length truncated") }
                let length = Int(record.mp4UInt16(at: offset))
                offset += 2
                guard offset + length <= record.count else { throw VideoRepairError.malformed("avcC parameter set truncated") }
                defer { offset += length }
                return record.mp4Bytes(offset..<(offset + length))
            }
        }
        let spsCount = Int(record.mp4UInt8(at: offset) & 0x1F)
        offset += 1
        let spsList = try list(count: spsCount)
        guard offset < record.count else { throw VideoRepairError.malformed("avcC PPS count missing") }
        let ppsCount = Int(record.mp4UInt8(at: offset))
        offset += 1
        let ppsList = try list(count: ppsCount)
        return (spsList, ppsList, record.mp4Bytes(offset..<record.count))
    }

    /// The record listing the SPS and PPS found in band (`inBand`, a sync sample's NAL units) in
    /// place of its own, with the profile and level taken from the first SPS.
    static func rewrite(_ record: Data, inBand: [Data]) throws -> Data {
        let existing = try parameterSets(in: record)
        let sampleSPS = inBand.filter { !$0.isEmpty && nalType($0) == sps }
        let samplePPS = inBand.filter { !$0.isEmpty && nalType($0) == pps }
        var spsList: [Data] = []
        var ppsList: [Data] = []
        NALUnits.appendUnique(sampleSPS.isEmpty ? existing.sps : sampleSPS, to: &spsList)
        NALUnits.appendUnique(samplePPS.isEmpty ? existing.pps : samplePPS, to: &ppsList)
        guard let first = spsList.first, first.count >= 4, !ppsList.isEmpty else {
            throw VideoRepairError.noParameterSets("H.264")
        }
        guard spsList.count <= 31, ppsList.count <= 255 else {
            throw VideoRepairError.unsupported("\(spsList.count) SPS and \(ppsList.count) PPS")
        }
        let profile = first.mp4UInt8(at: 1)
        var data = Data([1, profile, first.mp4UInt8(at: 2), first.mp4UInt8(at: 3),
                         0xFC | (record.mp4UInt8(at: 4) & 3), 0xE0 | UInt8(spsList.count)])
        try append(spsList, to: &data)
        data.appendMP4(UInt8(ppsList.count))
        try append(ppsList, to: &data)
        if extendedProfiles.contains(profile) { data.append(existing.tail) }
        return data
    }

    private static func append(_ units: [Data], to data: inout Data) throws {
        for unit in units {
            guard unit.count <= 0xFFFF else { throw VideoRepairError.unsupported("parameter set of \(unit.count) bytes") }
            data.appendMP4(UInt16(unit.count))
            data.append(unit)
        }
    }
}
