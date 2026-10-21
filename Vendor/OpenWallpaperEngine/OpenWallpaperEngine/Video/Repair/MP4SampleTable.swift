import Foundation

/// Locates samples through a track's sample table (`stbl`, ISO/IEC 14496-12 §8.7): sizes from
/// `stsz`, chunks from `stsc` and `stco`/`co64`, sync samples from `stss`.
struct MP4SampleTable {
    private var sampleSizes: [UInt32]
    private var constantSize: UInt32
    private var sampleCount: Int
    private var chunkRuns: [(firstChunk: Int, samplesPerChunk: Int)]
    private var chunkOffsets: [UInt64]
    /// nil when every sample is a sync sample (no `stss`).
    private var syncSamples: [Int]?

    init(stbl: MP4Box) throws {
        guard let stsz = stbl.child("stsz") else {
            if stbl.child("stz2") != nil { throw VideoRepairError.unsupported("compact sample sizes (stz2)") }
            throw VideoRepairError.missingBox("stbl/stsz")
        }
        let sizes = stsz.body
        guard sizes.count >= 12 else { throw VideoRepairError.malformed("stsz too short") }
        constantSize = sizes.mp4UInt32(at: 4)
        sampleCount = Int(sizes.mp4UInt32(at: 8))
        if constantSize == 0 {
            guard sizes.count >= 12 + sampleCount * 4 else { throw VideoRepairError.malformed("stsz entries truncated") }
            sampleSizes = (0..<sampleCount).map { sizes.mp4UInt32(at: 12 + $0 * 4) }
        } else {
            sampleSizes = []
        }
        // A fragmented file keeps its samples in `moof` boxes; the header's table is empty.
        guard sampleCount > 0 else { throw VideoRepairError.unsupported("no samples in moov (fragmented MP4)") }

        guard let stsc = stbl.child("stsc")?.body, stsc.count >= 8 else { throw VideoRepairError.missingBox("stbl/stsc") }
        let runCount = Int(stsc.mp4UInt32(at: 4))
        guard stsc.count >= 8 + runCount * 12 else { throw VideoRepairError.malformed("stsc entries truncated") }
        chunkRuns = (0..<runCount).map {
            (Int(stsc.mp4UInt32(at: 8 + $0 * 12)), Int(stsc.mp4UInt32(at: 12 + $0 * 12)))
        }

        chunkOffsets = try Self.chunkOffsets(in: stbl)

        if let stss = stbl.child("stss")?.body {
            guard stss.count >= 8 else { throw VideoRepairError.malformed("stss too short") }
            let count = Int(stss.mp4UInt32(at: 4))
            guard stss.count >= 8 + count * 4 else { throw VideoRepairError.malformed("stss entries truncated") }
            syncSamples = (0..<count).map { Int(stss.mp4UInt32(at: 8 + $0 * 4)) }
        } else {
            syncSamples = nil
        }
    }

    private static func chunkOffsets(in stbl: MP4Box) throws -> [UInt64] {
        if let stco = stbl.child("stco")?.body {
            guard stco.count >= 8 else { throw VideoRepairError.malformed("stco too short") }
            let count = Int(stco.mp4UInt32(at: 4))
            guard stco.count >= 8 + count * 4 else { throw VideoRepairError.malformed("stco entries truncated") }
            return (0..<count).map { UInt64(stco.mp4UInt32(at: 8 + $0 * 4)) }
        }
        if let co64 = stbl.child("co64")?.body {
            guard co64.count >= 8 else { throw VideoRepairError.malformed("co64 too short") }
            let count = Int(co64.mp4UInt32(at: 4))
            guard co64.count >= 8 + count * 8 else { throw VideoRepairError.malformed("co64 entries truncated") }
            return (0..<count).map { co64.mp4UInt64(at: 8 + $0 * 8) }
        }
        throw VideoRepairError.missingBox("stbl/stco")
    }

    /// The first sync sample's number (1-based).
    var firstSyncSample: Int {
        get throws {
            guard let syncSamples else { return 1 }
            guard let first = syncSamples.first, first >= 1, first <= sampleCount else {
                throw VideoRepairError.malformed("no usable sync sample")
            }
            return first
        }
    }

    private func size(ofSample number: Int) -> UInt64 {
        UInt64(constantSize != 0 ? constantSize : sampleSizes[number - 1])
    }

    /// Where sample `number` (1-based) lies in the file.
    func location(ofSample number: Int) throws -> (offset: UInt64, size: Int) {
        guard number >= 1, number <= sampleCount else { throw VideoRepairError.malformed("sample \(number) out of range") }
        var firstSampleOfRun = 1
        for (index, run) in chunkRuns.enumerated() {
            let nextFirstChunk = index + 1 < chunkRuns.count ? chunkRuns[index + 1].firstChunk : chunkOffsets.count + 1
            guard run.firstChunk >= 1, run.samplesPerChunk > 0, nextFirstChunk > run.firstChunk else {
                throw VideoRepairError.malformed("stsc run \(index) is inconsistent")
            }
            let samplesInRun = (nextFirstChunk - run.firstChunk) * run.samplesPerChunk
            if number < firstSampleOfRun + samplesInRun {
                let chunkInRun = (number - firstSampleOfRun) / run.samplesPerChunk
                let chunk = run.firstChunk + chunkInRun
                guard chunk <= chunkOffsets.count else { throw VideoRepairError.malformed("chunk \(chunk) out of range") }
                let firstSampleOfChunk = firstSampleOfRun + chunkInRun * run.samplesPerChunk
                let preceding = (firstSampleOfChunk..<number).reduce(UInt64(0)) { $0 + size(ofSample: $1) }
                return (chunkOffsets[chunk - 1] + preceding, Int(size(ofSample: number)))
            }
            firstSampleOfRun += samplesInRun
        }
        throw VideoRepairError.malformed("sample \(number) lies in no chunk")
    }
}
