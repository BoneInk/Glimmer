import XCTest
@testable import OpenWallpaperEngine

/// The lossless `hev1`/`avc3` → `hvc1`/`avc1` repair on MP4s built here box by box, with a few
/// fake NAL units: the sample entry and its configuration record, the chunk offsets when `moov`
/// grows ahead of `mdat`, and the media bytes left untouched.
final class VideoSampleEntryRepairTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "VideoSampleEntryRepairTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fake NAL units

    private static let vps = Data([0x40, 0x01, 0x0C, 0x01, 0xFF, 0xFF])
    private static let sps = Data([0x42, 0x01, 0x01, 0x01, 0x60, 0x00, 0x90])
    private static let oldSPS = Data([0x42, 0x01, 0x01, 0x02])
    private static let pps = Data([0x44, 0x01, 0xC1, 0x72])
    private static let prefixSEI = Data([0x4E, 0x01, 0x05, 0x10])
    private static let idrSlice = Data([0x26, 0x01, 0xAF, 0x11, 0x22, 0x33])
    private static let trailSlice = Data([0x02, 0x01, 0xD0, 0x44])

    private static let avcSPS = Data([0x67, 0x64, 0x00, 0x1F, 0xAC, 0xD9, 0x40])
    private static let avcPPS = Data([0x68, 0xEE, 0x3C, 0x80])
    private static let avcIDR = Data([0x65, 0x88, 0x84, 0x00, 0x21])
    private static let avcSlice = Data([0x41, 0x9A, 0x02])

    /// Length-prefixed (4 bytes) NAL units: one sample.
    private static func sample(_ units: [Data]) -> Data {
        units.reduce(into: Data()) { data, unit in
            data.appendMP4(UInt32(unit.count))
            data.append(unit)
        }
    }

    private static func box(_ type: String, _ payload: Data) -> Data {
        var data = Data()
        data.appendMP4(UInt32(payload.count + 8))
        data.appendMP4FourCC(type)
        data.append(payload)
        return data
    }

    private static func fullBox(_ type: String, _ payload: Data) -> Data {
        box(type, Data([0, 0, 0, 0]) + payload)
    }

    private static func uint32s(_ values: [UInt32]) -> Data {
        values.reduce(into: Data()) { $0.appendMP4($1) }
    }

    /// A stub `hvcC`: profile Main, level 3.1, 4-byte lengths, with `arrays` (header, units).
    private static func hvcC(arrays: [(UInt8, [Data])]) -> Data {
        var record = Data([1, 0x01, 0x60, 0, 0, 0, 0x90, 0, 0, 0, 0, 0, 0x5D, 0xF0, 0x00, 0xFC, 0xFD, 0xF8, 0xF8, 0, 0, 0x0F])
        record.append(UInt8(arrays.count))
        for (header, units) in arrays {
            record.append(header)
            record.appendMP4(UInt16(units.count))
            for unit in units {
                record.appendMP4(UInt16(unit.count))
                record.append(unit)
            }
        }
        return record
    }

    // MARK: - Synthetic files

    private enum Layout { case movieFirst, mediaFirst }

    private struct SyntheticMP4 {
        var entryType: String
        var configType: String
        var record: Data
        /// Three samples: the first two in chunk 1, the third in chunk 2.
        var samples: [Data]
        var layout: Layout
        var largeOffsets = false

        var mediaPayload: Data { samples.reduce(Data(), +) }

        func sampleEntry() -> Data {
            var fields = Data(count: 6)
            fields.appendMP4(UInt16(1))
            fields.append(Data(count: 16))
            fields.appendMP4(UInt16(1920))
            fields.appendMP4(UInt16(1080))
            fields.appendMP4(UInt32(0x0048_0000))
            fields.appendMP4(UInt32(0x0048_0000))
            fields.append(Data(count: 4))
            fields.appendMP4(UInt16(1))
            fields.append(Data(count: 32))
            fields.appendMP4(UInt16(0x18))
            fields.appendMP4(UInt16(0xFFFF))
            return box(entryType, fields + box(configType, record) + box("pasp", uint32s([1, 1])))
        }

        func movie(mediaStart: UInt64) -> Data {
            let chunks = [mediaStart, mediaStart + UInt64(samples[0].count + samples[1].count)]
            let offsets = largeOffsets
                ? fullBox("co64", uint32s([2]) + chunks.reduce(into: Data()) { $0.appendMP4($1) })
                : fullBox("stco", uint32s([2] + chunks.map(UInt32.init)))
            let stbl = box("stbl",
                           fullBox("stsd", uint32s([1]) + sampleEntry())
                           + fullBox("stts", uint32s([1, 3, 1000]))
                           + fullBox("stss", uint32s([1, 1]))
                           + fullBox("stsc", uint32s([2, 1, 2, 1, 2, 1, 1]))
                           + fullBox("stsz", uint32s([0, 3] + samples.map { UInt32($0.count) }))
                           + offsets)
            let minf = box("minf", fullBox("vmhd", Data(count: 8)) + box("dinf", Data()) + stbl)
            let mdia = box("mdia", fullBox("mdhd", Data(count: 20)) + fullBox("hdlr", Data(count: 4) + Data("vide".utf8) + Data(count: 13)) + minf)
            let trak = box("trak", fullBox("tkhd", Data(count: 80)) + mdia)
            return box("moov", fullBox("mvhd", Data(count: 96)) + trak)
        }

        func build() -> Data {
            let ftyp = box("ftyp", Data("isom".utf8) + uint32s([512]) + Data("isomiso2mp41".utf8))
            let mdat = box("mdat", mediaPayload)
            switch layout {
            case .movieFirst:
                let size = movie(mediaStart: 0).count
                return ftyp + movie(mediaStart: UInt64(ftyp.count + size + 8)) + mdat
            case .mediaFirst:
                return ftyp + mdat + movie(mediaStart: UInt64(ftyp.count + 8))
            }
        }
    }

    private func hevcFile(layout: Layout) -> SyntheticMP4 {
        SyntheticMP4(entryType: "hev1", configType: "hvcC",
                     record: Self.hvcC(arrays: [(0x21, [Self.oldSPS]), (0x27, [Self.prefixSEI])]),
                     samples: [Self.sample([Self.vps, Self.sps, Self.pps, Self.prefixSEI, Self.idrSlice]),
                               Self.sample([Self.trailSlice]), Self.sample([Self.trailSlice, Self.trailSlice])],
                     layout: layout)
    }

    private func avcFile(layout: Layout, largeOffsets: Bool = false) -> SyntheticMP4 {
        SyntheticMP4(entryType: "avc3", configType: "avcC",
                     record: Data([1, 0x64, 0x00, 0x28, 0xFF, 0xE0, 0x00]),
                     samples: [Self.sample([Self.avcSPS, Self.avcPPS, Self.avcIDR]),
                               Self.sample([Self.avcSlice]), Self.sample([Self.avcSlice])],
                     layout: layout, largeOffsets: largeOffsets)
    }

    /// Deleting a wallpaper removes the repaired copies of its videos (`InstalledLibraryModel
    /// .forgetDeletedWallpaper`), and only those.
    func testRepairedCopiesGoWithTheirWallpaper() throws {
        let cache = RepairedVideoCache(cachesDirectory: root.appending(path: "Caches"))
        let deleted = root.appending(path: "wallpapers/1234", directoryHint: .isDirectory)
        let kept = root.appending(path: "wallpapers/12345", directoryHint: .isDirectory)
        var copies: [URL] = []
        for folder in [deleted, kept] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let source = folder.appending(path: "video.mp4")
            try hevcFile(layout: .movieFirst).build().write(to: source)
            let copy = cache.playableURL(for: source)
            XCTAssertNotEqual(copy, source)
            let record = copy.deletingLastPathComponent().appending(path: RepairedVideoCache.sourceFileName)
            XCTAssertEqual(try String(contentsOf: record, encoding: .utf8), source.standardizedFileURL.path(percentEncoded: false))
            copies.append(copy)
        }
        try FileManager.default.removeItem(at: deleted)
        _ = expectThreadGuardViolations { cache.removeCopies(forSourcesIn: deleted) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: copies[0].deletingLastPathComponent().path(percentEncoded: false)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: copies[1].path(percentEncoded: false)),
                      "a wallpaper whose folder name starts the same keeps its copy")
    }

    // MARK: - Helpers

    private func write(_ data: Data, name: String) throws -> URL {
        let url = root.appending(path: name)
        try data.write(to: url)
        return url
    }

    private func topLevel(_ data: Data) throws -> [(box: MP4Box, range: Range<Int>)] {
        var result: [(MP4Box, Range<Int>)] = []
        var offset = 0
        while offset < data.count {
            let (box, size) = try MP4Box.parse(data, at: offset)
            result.append((box, offset..<(offset + size)))
            offset += size
        }
        return result
    }

    private func stbl(of data: Data) throws -> MP4Box {
        let moov = try XCTUnwrap(try topLevel(data).first { $0.box.type == "moov" }?.box)
        return try XCTUnwrap(moov.descendant(["trak", "mdia", "minf", "stbl"]))
    }

    private func mediaBytes(_ data: Data) throws -> Data {
        let mdat = try XCTUnwrap(try topLevel(data).first { $0.box.type == "mdat" })
        return data.mp4Bytes(mdat.range)
    }

    /// Every sample, read back through the file's own sample table, is the sample it was built with.
    private func assertSamplesResolve(_ data: Data, _ file: SyntheticMP4, line: UInt = #line) throws {
        let table = try MP4SampleTable(stbl: try stbl(of: data))
        for (index, sample) in file.samples.enumerated() {
            let location = try table.location(ofSample: index + 1)
            XCTAssertEqual(data.mp4Bytes(Int(location.offset)..<(Int(location.offset) + location.size)), sample,
                           "sample \(index + 1)", line: line)
        }
    }

    private func repair(_ file: SyntheticMP4) throws -> (original: Data, repaired: Data) {
        let original = file.build()
        let source = try write(original, name: "source-\(UUID().uuidString).mp4")
        let destination = root.appending(path: "repaired-\(UUID().uuidString).mp4")
        XCTAssertTrue(try VideoSampleEntryRepair.needsRepair(source))
        XCTAssertTrue(try VideoSampleEntryRepair.repair(source, to: destination))
        return (original, try Data(contentsOf: destination))
    }

    // MARK: - Tests

    func testSyntheticFilesResolveTheirSamples() throws {
        try assertSamplesResolve(hevcFile(layout: .movieFirst).build(), hevcFile(layout: .movieFirst))
        try assertSamplesResolve(avcFile(layout: .mediaFirst).build(), avcFile(layout: .mediaFirst))
    }

    func testHEV1BecomesHVC1WithCompleteParameterSetArrays() throws {
        let file = hevcFile(layout: .movieFirst)
        let (original, repaired) = try repair(file)

        let entry = try XCTUnwrap(try stbl(of: repaired).child("stsd")?.children?.first)
        XCTAssertEqual(entry.type, "hvc1")
        let originalEntry = try XCTUnwrap(try stbl(of: original).child("stsd")?.children?.first)
        XCTAssertEqual(entry.body, originalEntry.body, "the visual sample entry's fields are unchanged")
        XCTAssertEqual(entry.child("pasp")?.body, originalEntry.child("pasp")?.body)
        // The in-band VPS, SPS and PPS, complete; the record's own older SPS replaced; SEI kept.
        let expected = Self.hvcC(arrays: [(0xA0, [Self.vps]), (0xA1, [Self.sps]), (0xA2, [Self.pps]), (0x27, [Self.prefixSEI])])
        XCTAssertEqual(entry.child("hvcC")?.body, expected)
        XCTAssertEqual(try mediaBytes(repaired), try mediaBytes(original), "mdat is byte-identical")
        try assertSamplesResolve(repaired, file)
    }

    func testChunkOffsetsMoveWithTheGrownMovieBoxAheadOfMediaData() throws {
        let file = hevcFile(layout: .movieFirst)
        let (original, repaired) = try repair(file)
        let delta = UInt32(repaired.count - original.count)
        XCTAssertGreaterThan(delta, 0)

        let before = try XCTUnwrap(try stbl(of: original).child("stco")?.body)
        let after = try XCTUnwrap(try stbl(of: repaired).child("stco")?.body)
        XCTAssertEqual(after.mp4UInt32(at: 8), before.mp4UInt32(at: 8) + delta)
        XCTAssertEqual(after.mp4UInt32(at: 12), before.mp4UInt32(at: 12) + delta)
        // Everything before moov is copied as it was.
        let movieStart = try XCTUnwrap(try topLevel(original).first { $0.box.type == "moov" }?.range.lowerBound)
        XCTAssertEqual(repaired.prefix(movieStart), original.prefix(movieStart))
    }

    func testAVC3BecomesAVC1WithTheInBandSPSAndPPS() throws {
        let file = avcFile(layout: .mediaFirst)
        let (original, repaired) = try repair(file)

        let entry = try XCTUnwrap(try stbl(of: repaired).child("stsd")?.children?.first)
        XCTAssertEqual(entry.type, "avc1")
        var expected = Data([1, 0x64, 0x00, 0x1F, 0xFF, 0xE1])
        expected.appendMP4(UInt16(Self.avcSPS.count))
        expected.append(Self.avcSPS)
        expected.append(1)
        expected.appendMP4(UInt16(Self.avcPPS.count))
        expected.append(Self.avcPPS)
        XCTAssertEqual(entry.child("avcC")?.body, expected)
        // moov after mdat: no offset moves, and the file up to moov is untouched.
        XCTAssertEqual(try stbl(of: repaired).child("stco")?.body, try stbl(of: original).child("stco")?.body)
        let movieStart = try XCTUnwrap(try topLevel(original).first { $0.box.type == "moov" }?.range.lowerBound)
        XCTAssertEqual(repaired.prefix(movieStart), original.prefix(movieStart))
        XCTAssertEqual(try mediaBytes(repaired), try mediaBytes(original))
        try assertSamplesResolve(repaired, file)
    }

    func testLargeChunkOffsetsMoveToo() throws {
        let file = avcFile(layout: .movieFirst, largeOffsets: true)
        let (original, repaired) = try repair(file)
        let delta = UInt64(repaired.count - original.count)
        let before = try XCTUnwrap(try stbl(of: original).child("co64")?.body)
        let after = try XCTUnwrap(try stbl(of: repaired).child("co64")?.body)
        XCTAssertEqual(after.mp4UInt64(at: 8), before.mp4UInt64(at: 8) + delta)
        XCTAssertEqual(try mediaBytes(repaired), try mediaBytes(original))
        try assertSamplesResolve(repaired, file)
    }

    func testOutOfBandEntriesAreLeftAlone() throws {
        var file = avcFile(layout: .movieFirst)
        file.entryType = "avc1"
        let source = try write(file.build(), name: "plain.mp4")
        let destination = root.appending(path: "plain-repaired.mp4")
        XCTAssertFalse(try VideoSampleEntryRepair.needsRepair(source))
        XCTAssertFalse(try VideoSampleEntryRepair.repair(source, to: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)))
    }

    func testSampleEntryTypesListEveryTrack() throws {
        let source = try write(hevcFile(layout: .movieFirst).build(), name: "types.mp4")
        XCTAssertEqual(try VideoSampleEntryRepair.sampleEntryTypes(source), ["hev1"])
    }

    /// A video wallpaper whose track is in band gets its repaired copy in the screen saver store.
    func testEmptyRecordTakesItsProfileFromTheSPS() throws {
        // profile_tier_level with emulation prevention bytes, then sps_id 0, chroma 4:2:0,
        // width and height 0, no conformance window, 10-bit luma and chroma.
        let sps = Data([0x42, 0x01, 0x01, 0x01, 0x60, 0x00, 0x00, 0x03, 0x00, 0x90, 0x00, 0x00, 0x03, 0x00, 0x00,
                        0x03, 0x00, 0x5D, 0xAC, 0xDC])
        var stub = Data(count: 22)
        stub[21] = 0x0F
        stub.append(0)
        let record = try HEVCDecoderConfiguration.rewrite(stub, inBand: [Self.vps, sps, Self.pps])
        XCTAssertEqual(record.mp4Bytes(0..<22),
                       Data([1, 0x01, 0x60, 0, 0, 0, 0x90, 0, 0, 0, 0, 0, 0x5D, 0xF0, 0, 0xFC, 0xFD, 0xFA, 0xFA, 0, 0, 0x0F]))
        XCTAssertEqual(try HEVCDecoderConfiguration.arrays(in: record).map(\.units), [[Self.vps], [sps], [Self.pps]])
    }

    func testMissingParameterSetsFailWithoutWriting() throws {
        var file = hevcFile(layout: .movieFirst)
        file.samples[0] = Self.sample([Self.idrSlice])
        file.record = Self.hvcC(arrays: [])
        let source = try write(file.build(), name: "bare.mp4")
        let destination = root.appending(path: "bare-repaired.mp4")
        XCTAssertThrowsError(try VideoSampleEntryRepair.repair(source, to: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)))
    }

    func testCacheMakesOneCopyPerSourceVersionAndFallsBackToTheOriginal() throws {
        let cache = RepairedVideoCache(cachesDirectory: root.appending(path: "Caches"))
        let source = try write(hevcFile(layout: .movieFirst).build(), name: "wallpaper.mp4")

        var announced = 0
        let copy = cache.playableURL(for: source) { announced += 1 }
        XCTAssertNotEqual(copy, source)
        XCTAssertTrue(copy.path(percentEncoded: false).hasPrefix(cache.directory.path(percentEncoded: false)))
        XCTAssertEqual(announced, 1)
        XCTAssertEqual(cache.playableURL(for: source) { announced += 1 }, copy)
        XCTAssertEqual(announced, 1, "an existing copy is reused")

        // A changed source gets a new copy, and the old one goes.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)],
                                              ofItemAtPath: source.path(percentEncoded: false))
        let newer = cache.playableURL(for: source)
        XCTAssertNotEqual(newer, copy)
        XCTAssertTrue(FileManager.default.fileExists(atPath: newer.path(percentEncoded: false)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path(percentEncoded: false)))

        let broken = try write(Data([0, 0, 0, 0x20]) + Data("ftyp".utf8), name: "broken.mp4")
        XCTAssertEqual(cache.playableURL(for: broken), broken)
        var plain = avcFile(layout: .movieFirst)
        plain.entryType = "avc1"
        let plainURL = try write(plain.build(), name: "plain.mp4")
        XCTAssertEqual(cache.playableURL(for: plainURL), plainURL)
    }
}
