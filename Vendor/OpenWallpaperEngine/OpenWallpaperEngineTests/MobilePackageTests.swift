import Compression
import Foundation
import XCTest
@testable import OpenWallpaperEngine

/// WE's mobile package (`.mpkg`): the writer's layout and round trip, and byte compatibility with
/// WE 2.8.42's own exports of Workshop item 2515150033 ("Knight (Puppet Warp PBR Demo)").
///
/// The WE samples aren't in the repository (they are WE's output): `OWE_ANDROID_SAMPLES`
/// (`TEST_RUNNER_OWE_ANDROID_SAMPLES` through xcodebuild) names a folder with
/// `scene_dynamic_balanced_2515150033.mpkg`, `video_project.json`, `prerendered_project.json`
/// and `prerendered_scene.json` (the `we-test-wp-images` branch's `android-transfer/mpkg`), and
/// `OWE_ANDROID_SAMPLE_ITEM` the Workshop item's folder (its scene.pkg, or its files).
final class MobilePackageTests: XCTestCase {
    static let dynamicSample = "scene_dynamic_balanced_2515150033.mpkg"

    private static func samples() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["OWE_ANDROID_SAMPLES"], !path.isEmpty else {
            throw XCTSkip("needs WE's .mpkg samples: set OWE_ANDROID_SAMPLES")
        }
        return URL(filePath: path, directoryHint: .isDirectory)
    }

    private static func sampleItem() throws -> WEWallpaper {
        guard let path = ProcessInfo.processInfo.environment["OWE_ANDROID_SAMPLE_ITEM"], !path.isEmpty,
              let wallpaper = InstalledLibrary.wallpaper(at: URL(filePath: path, directoryHint: .isDirectory), hiding: []) else {
            throw XCTSkip("needs Workshop item 2515150033: set OWE_ANDROID_SAMPLE_ITEM")
        }
        return wallpaper
    }

    /// The branch's JSON samples were committed with Unix line ends; WE writes Windows ones (the
    /// .mpkg's own files have them).
    private static func windowsLineEnds(_ data: Data) -> Data {
        Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n").utf8)
    }

    // MARK: Layout

    func testHeaderTableAndDataLayout() throws {
        let data = try MobilePackageWriter.data([
            .init(path: "scene.json", data: Data("{}".utf8)),
            .init(path: "a/b.tex", data: Data([1, 2, 3])),
        ])
        var expected = Data()
        func word(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { expected.append(contentsOf: $0) } }
        word(8); expected.append(contentsOf: Array("PKGM0014".utf8))
        word(2)
        word(7); expected.append(contentsOf: Array("a/b.tex".utf8)); word(0); word(3)
        word(10); expected.append(contentsOf: Array("scene.json".utf8)); word(3); word(2)
        expected.append(contentsOf: [1, 2, 3])
        expected.append(contentsOf: Array("{}".utf8))
        XCTAssertEqual(data, expected)
    }

    func testRoundTripThroughTheReader() throws {
        let entries: [MobilePackageWriter.Entry] = [
            .init(path: "shaders/effects/pulse.frag", data: Data("void main() {}".utf8)),
            .init(path: "materials/centurion 1080p.json", data: Data("{\"passes\": []}".utf8)),
            .init(path: "materials/centurion 1080p_bg.tex", data: Data(repeating: 7, count: 70_000)),
            .init(path: "project.json", data: Data()),
            .init(path: "Video.mp4", data: Data(repeating: 1, count: 33)),
        ]
        let data = try MobilePackageWriter.data(entries)
        XCTAssertThrowsError(try PKGParser(data: data), "a scene.pkg reader refuses it")
        let parser = try PKGParser(data: data, magic: "PKGM")
        XCTAssertEqual(parser.header, MobilePackageWriter.magic)
        XCTAssertEqual(parser.fileList, ["Video.mp4", "materials/centurion 1080p.json", "materials/centurion 1080p_bg.tex",
                                         "project.json", "shaders/effects/pulse.frag"], "sorted by bytes, as WE lists them")
        for entry in entries {
            guard case .data(let bytes) = entry.source else { continue }
            XCTAssertEqual(parser.extractFile(named: entry.path), bytes, entry.path)
        }
    }

    func testFileEntriesAreCopiedWhole() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "mpkg-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: file) } // scratch cleanup
        let video = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 * 31) })
        try video.write(to: file)
        let data = try MobilePackageWriter.data([.init(path: "clip.mp4", file: file), .init(path: "project.json", data: Data("{}".utf8))])
        XCTAssertEqual(try PKGParser(data: data, magic: "PKGM").extractFile(named: "clip.mp4"), video)
    }

    func testDuplicatePathsAreRefused() {
        XCTAssertThrowsError(try MobilePackageWriter.data([.init(path: "a", data: Data()), .init(path: "a", data: Data([1]))]))
    }

    // MARK: WE's samples

    /// WE's Dynamic package, read and written again from its own entries: identical bytes.
    func testWESampleRepacksByteForByte() throws {
        let url = try Self.samples().appending(path: Self.dynamicSample)
        let original = try Data(contentsOf: url)
        let parser = try PKGParser(data: original, magic: "PKGM")
        XCTAssertEqual(parser.header, "PKGM0014")
        XCTAssertEqual(parser.fileList.count, 36)
        let entries = try parser.fileList.map { path in
            MobilePackageWriter.Entry(path: path, data: Data(try XCTUnwrap(parser.extractFile(named: path))))
        }
        XCTAssertEqual(MobilePackageWriter.ordered(entries).map(\.path), parser.fileList, "WE's order is the writer's")
        XCTAssertEqual(try MobilePackageWriter.data(entries), original)
    }

    /// The video package's project.json, for WE's sample video (2447928310).
    func testVideoProjectMatchesWE() throws {
        let expected = try Data(contentsOf: Self.samples().appending(path: "video_project.json"))
        let directory = FileManager.default.temporaryDirectory.appending(path: "mpkg-video-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) } // scratch cleanup
        let project = #"{"file": "Floating_In_Space_By_VISUALDON.mp4", "preview": "preview.gif", "title": "Floating In Space By VISUALDON", "type": "video", "tags": ["Sci-Fi"], "workshopid": "2447928310"}"#
        try Data(project.utf8).write(to: directory.appending(path: "project.json"))
        try Data([0, 0, 0, 24]).write(to: directory.appending(path: "Floating_In_Space_By_VISUALDON.mp4"))
        try Data("GIF89a".utf8).write(to: directory.appending(path: "preview.gif"))
        let wallpaper = try XCTUnwrap(InstalledLibrary.wallpaper(at: directory, hiding: []))
        let entries = try AndroidPackageBuilder.videoEntries(wallpaper)
        XCTAssertEqual(MobilePackageWriter.ordered(entries).map(\.path),
                       ["Floating_In_Space_By_VISUALDON.mp4", "preview.gif", "project.json"])
        guard case .data(let written) = try XCTUnwrap(entries.first { $0.path == "project.json" }).source else {
            return XCTFail("project.json is written")
        }
        XCTAssertEqual(written, Self.windowsLineEnds(expected))
    }

    /// The Pre-Rendered package's scene.json and project.json, from the Workshop item.
    func testPreRenderedFilesMatchWE() throws {
        let samples = try Self.samples()
        let wallpaper = try Self.sampleItem()
        let video = FileManager.default.temporaryDirectory.appending(path: "mpkg-\(UUID().uuidString).mp4")
        try Data([0]).write(to: video)
        defer { try? FileManager.default.removeItem(at: video) } // scratch cleanup
        let entries = try AndroidPackageBuilder.preRenderedEntries(wallpaper, video: video)
        XCTAssertEqual(MobilePackageWriter.ordered(entries).map(\.path), ["preview.jpg", "project.json", "scene.json", "wallpaper.mp4"])
        for (path, sample) in [("project.json", "prerendered_project.json"), ("scene.json", "prerendered_scene.json")] {
            guard case .data(let written) = try XCTUnwrap(entries.first { $0.path == path }).source else {
                return XCTFail("\(path) is written")
            }
            XCTAssertEqual(written, Self.windowsLineEnds(try Data(contentsOf: samples.appending(path: sample))), path)
        }
    }

    /// Our ETC2 blocks of the scene's background, against WE's: as close to the half-size picture.
    func testETC2QualityIsLikeWEs() throws {
        let sample = try PKGParser(url: Self.samples().appending(path: Self.dynamicSample), magic: "PKGM")
        let wallpaper = try Self.sampleItem()
        let path = "materials/centurion 1080p_bg.tex"
        let theirs = Data(try XCTUnwrap(sample.extractFile(named: path)))
        let source = try Data(contentsOf: wallpaper.wallpaperDirectory.appending(path: path))
        var result: (ours: Double, theirs: Double)?
        let done = expectation(description: "encoded")
        DispatchQueue.global().async {
            defer { done.fulfill() }
            guard let header = TEXFileHeader(source), let pixels = MobileTextureConverter.decode(source, header: header),
                  let weHeader = TEXFileHeader(theirs), let mipmap = weHeader.mipmaps.first else { return }
            let half = pixels.scaled(width: mipmap.width, height: mipmap.height)
            var blocks = [UInt8](repeating: 0, count: mipmap.uncompressedSize)
            let stored = [UInt8](theirs.subdata(in: mipmap.stored))
            _ = compression_decode_buffer(&blocks, blocks.count, stored, stored.count, nil, COMPRESSION_LZ4_RAW)
            let weDecoded = ETC2TestDecoder.decode(blocks, width: mipmap.width, height: mipmap.height)
            let ours = ETC2TestDecoder.decode(ETC2Encoder.encode(half.bytes, width: mipmap.width, height: mipmap.height),
                                              width: mipmap.width, height: mipmap.height)
            result = (ETC2TestDecoder.psnr(ours, half.bytes), ETC2TestDecoder.psnr(weDecoded, half.bytes))
        }
        wait(for: [done], timeout: 300)
        let psnr = try XCTUnwrap(result)
        XCTAssertGreaterThan(psnr.ours, psnr.theirs - 1.5, "ours \(psnr.ours) dB, WE's \(psnr.theirs) dB")
    }

    /// The Dynamic / Balanced package from the Workshop item against WE's: the same files in the
    /// same order, every file byte for byte except the converted textures' ETC2 blocks, whose
    /// headers (format, flags, sizes, mipmap layout) match WE's.
    func testDynamicBalancedMatchesWE() throws {
        let sample = try PKGParser(url: Self.samples().appending(path: Self.dynamicSample), magic: "PKGM")
        let wallpaper = try Self.sampleItem()
        var built: [MobilePackageWriter.Entry] = []
        let expectation = expectation(description: "built")
        DispatchQueue.global().async {
            do {
                built = try AndroidPackageBuilder.dynamicEntries(wallpaper, options: AndroidExportOptions(mode: .balanced))
            } catch {
                XCTFail("\(error)")
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 300)
        let package = try PKGParser(data: MobilePackageWriter.data(built), magic: "PKGM")
        XCTAssertEqual(package.fileList, sample.fileList)
        var converted: [String] = []
        for path in sample.fileList {
            let ours = try XCTUnwrap(package.extractFile(named: path)).map { $0 }
            let theirs = try XCTUnwrap(sample.extractFile(named: path)).map { $0 }
            if ours == theirs { continue }
            converted.append(path)
            let mine = try XCTUnwrap(TEXFileHeader(Data(ours)), path), we = try XCTUnwrap(TEXFileHeader(Data(theirs)), path)
            XCTAssertEqual(mine.format, we.format, path)
            XCTAssertEqual(mine.flags, we.flags, path)
            XCTAssertEqual([mine.textureWidth, mine.textureHeight, mine.imageWidth, mine.imageHeight],
                           [we.textureWidth, we.textureHeight, we.imageWidth, we.imageHeight], path)
            XCTAssertEqual(mine.colorWord, we.colorWord, path)
            XCTAssertEqual(mine.containerVersion, we.containerVersion, path)
            XCTAssertEqual(mine.mipmaps.map { [$0.width, $0.height, Int($0.compression), $0.uncompressedSize] },
                           we.mipmaps.map { [$0.width, $0.height, Int($0.compression), $0.uncompressedSize] }, path)
        }
        XCTAssertEqual(converted.sorted(), ["materials/centurion 1080p_bg.tex", "materials/centurion 1080p_sheet.tex",
                                            "materials/masks/centurion 1080p_sheet_mask_68b1b142.tex"],
                       "only the ETC2 textures' blocks differ")
        let total = built.reduce(0) { sum, entry in
            if case .data(let data) = entry.source { return sum + data.count }
            return sum
        }
        XCTAssertLessThan(abs(Double(total) / 7_361_302 - 1), 0.25, "about the size of WE's (\(total) bytes)")
    }
}
