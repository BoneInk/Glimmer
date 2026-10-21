import AVFoundation
import CoreGraphics
import XCTest
@testable import OpenWallpaperEngine

/// Better Live Photos: the window with the most motion, the sharpest still near the middle, the
/// still marked at that frame in the movie, and the movie's ends blended into the still.
final class LivePhotoMotionTests: XCTestCase {
    // MARK: Best-motion window

    func testWindowCoversTheBurstWithoutCuttingIt() {
        var differences = [Double](repeating: 0, count: 240)
        for index in 100...140 { differences[index] = 1 }
        let length = 60
        let start = LivePhotoMotion.bestWindowStart(differences: differences, length: length)
        XCTAssertLessThanOrEqual(start, 100)
        XCTAssertGreaterThan(start + length, 140)
        XCTAssertEqual(LivePhotoMotion.edgeMotion(differences: differences, start: start, length: length), 0)
    }

    func testTheBusierOfTwoBurstsWins() {
        var differences = [Double](repeating: 0.01, count: 240)
        for index in 20..<40 { differences[index] = 0.5 }
        for index in 170..<200 { differences[index] = 0.8 }
        let start = LivePhotoMotion.bestWindowStart(differences: differences, length: 45)
        XCTAssertLessThanOrEqual(start, 170)
        XCTAssertGreaterThanOrEqual(start + 45, 200)
    }

    func testStillOrShortSeriesStartAtZero() {
        XCTAssertEqual(LivePhotoMotion.bestWindowStart(differences: [Double](repeating: 0, count: 240), length: 90), 0)
        XCTAssertEqual(LivePhotoMotion.bestWindowStart(differences: [0, 1, 1], length: 90), 0)
        XCTAssertEqual(LivePhotoMotion.bestWindowStart(differences: [], length: 90), 0)
    }

    func testBestStartIsInSeconds() {
        var differences = [Double](repeating: 0, count: 240)
        for index in 150...170 { differences[index] = 1 }
        let analysis = LivePhotoMotion.Analysis(frameRate: 30, differences: differences)
        XCTAssertEqual(analysis.seconds, 8, accuracy: 1e-9)
        let start = LivePhotoMotion.bestStart(in: analysis, length: 2)
        XCTAssertLessThanOrEqual(start, 150.0 / 30)
        XCTAssertGreaterThanOrEqual(start + 2, 170.0 / 30)
    }

    func testDifferencesStartAtZero() {
        let black = ScreenSaverFrameSignature(values: [Float](repeating: 0, count: 6))
        let white = ScreenSaverFrameSignature(values: [Float](repeating: 1, count: 6))
        let differences = LivePhotoMotion.differences([black, black, white])
        XCTAssertEqual(differences.count, 3)
        XCTAssertEqual(differences[0], 0)
        XCTAssertEqual(differences[1], 0)
        XCTAssertGreaterThan(differences[2], 0)
        XCTAssertTrue(LivePhotoMotion.differences([]).isEmpty)
    }

    // MARK: Key still

    func testStillIsTheSharpestNearTheMiddle() {
        let frameCount = 90
        let band = LivePhotoKeyFrame.candidates(frameCount: frameCount)
        XCTAssertTrue(band.contains(45))
        XCTAssertFalse(band.contains(0))
        XCTAssertFalse(band.contains(89))
        var sharpness: [Int: Double] = [:]
        for index in 0..<frameCount { sharpness[index] = 1 }
        sharpness[50] = 2
        sharpness[85] = 10 // outside the band: a frame near the end never becomes the still
        XCTAssertEqual(LivePhotoKeyFrame.choose(sharpness: sharpness, frameCount: frameCount), 50)
        // Equal sharpness: the middle frame.
        XCTAssertEqual(LivePhotoKeyFrame.choose(sharpness: [44: 1, 45: 1, 46: 1], frameCount: frameCount), 45)
        XCTAssertEqual(LivePhotoKeyFrame.choose(sharpness: [:], frameCount: frameCount), 45)
        // A slightly sharper frame at the band's edge loses to the middle.
        XCTAssertEqual(LivePhotoKeyFrame.choose(sharpness: [45: 1, band.lowerBound: 1.1], frameCount: frameCount), 45)
    }

    func testSharpnessIsTheLaplacianVariance() throws {
        let flat = [Double](repeating: 0.5, count: 64)
        XCTAssertEqual(LivePhotoKeyFrame.laplacianVariance(flat, width: 8, height: 8), 0, accuracy: 1e-12)
        let checker: [Double] = (0..<64).map { index in ((index % 8) + (index / 8)) % 2 == 0 ? 0 : 1 }
        let soft: [Double] = (0..<64).map { index in ((index % 8) + (index / 8)) % 2 == 0 ? 0.4 : 0.6 }
        let sharp = LivePhotoKeyFrame.laplacianVariance(checker, width: 8, height: 8)
        XCTAssertGreaterThan(sharp, LivePhotoKeyFrame.laplacianVariance(soft, width: 8, height: 8))
        XCTAssertGreaterThan(LivePhotoKeyFrame.sharpness(of: try Self.checkerImage(64)), LivePhotoKeyFrame.sharpness(of: try Self.solidImage(64)))
    }

    // MARK: The movie

    func testMovieEndsBlendIntoTheStill() {
        let frameCount = 90
        let fade = LivePhotoMovieEncoder.fadeFrames(frameCount: frameCount, frameRate: 30)
        XCTAssertEqual(fade, 8)
        let first = LivePhotoMovieEncoder.stillWeight(index: 0, frameCount: frameCount, fade: fade)
        let last = LivePhotoMovieEncoder.stillWeight(index: frameCount - 1, frameCount: frameCount, fade: fade)
        XCTAssertEqual(first, Double(fade) / Double(fade + 1), accuracy: 1e-12)
        XCTAssertEqual(last, first, accuracy: 1e-12)
        XCTAssertEqual(LivePhotoMovieEncoder.stillWeight(index: fade, frameCount: frameCount, fade: fade), 0)
        XCTAssertEqual(LivePhotoMovieEncoder.stillWeight(index: 45, frameCount: frameCount, fade: fade), 0)
        XCTAssertGreaterThan(LivePhotoMovieEncoder.stillWeight(index: 1, frameCount: frameCount, fade: fade),
                             LivePhotoMovieEncoder.stillWeight(index: 2, frameCount: frameCount, fade: fade))
        // A one-second clip still fades, over at most a quarter of it.
        XCTAssertLessThanOrEqual(LivePhotoMovieEncoder.fadeFrames(frameCount: 12, frameRate: 30), 3)
    }

    func testBitrateFollowsTheDevicesPixels() {
        let proMax = SIMD2(1320, 2868), mini = SIMD2(1080, 2340)
        XCTAssertGreaterThan(LivePhotoQuality.high.bitRate(for: proMax, frameRate: 30), LivePhotoQuality.high.bitRate(for: mini, frameRate: 30))
        XCTAssertGreaterThan(LivePhotoQuality.best.bitRate(for: proMax, frameRate: 30), LivePhotoQuality.smaller.bitRate(for: proMax, frameRate: 30))
        let high = LivePhotoQuality.high.bitRate(for: proMax, frameRate: 30)
        XCTAssertGreaterThan(high, 8_000_000)
        XCTAssertLessThan(high, 40_000_000)
    }

    /// The still-image-time track marks the chosen key frame, the content identifier is in the
    /// movie, and the track is tagged Rec. 709.
    func testStillImageTimeMarksTheChosenKeyFrame() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "livephoto-motion-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let frameCount = 30
        var sharpness: [Int: Double] = [:]
        for index in 0..<frameCount { sharpness[index] = 1 }
        sharpness[17] = 3
        let keyFrame = LivePhotoKeyFrame.choose(sharpness: sharpness, frameCount: frameCount)
        XCTAssertEqual(keyFrame, 17)

        let size = SIMD2(64, 128)
        let frame = try Self.solidImage(size.x, height: size.y)
        let still = try Self.checkerImage(size.x, height: size.y)
        let movie = directory.appending(path: "clip.MOV")
        let identifier = UUID().uuidString
        try LivePhotoMovieEncoder.write(to: movie, pixelSize: size, frameRate: 30, frameCount: frameCount, keyFrame: keyFrame,
                                        still: still, identifier: identifier,
                                        bitRate: LivePhotoQuality.high.bitRate(for: size, frameRate: 30)) { _ in frame }

        let time = try await LivePhotoMetadata.movieStillImageTime(at: movie)
        XCTAssertEqual(time.map(CMTimeGetSeconds) ?? -1, Double(keyFrame) / 30, accuracy: 1e-6)
        let movieIdentifier = try await LivePhotoMetadata.movieIdentifier(at: movie)
        XCTAssertEqual(movieIdentifier, identifier)
        let tracks = try await AVURLAsset(url: movie).loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let formats = try await track.load(.formatDescriptions)
        let primaries = formats.first.flatMap { CMFormatDescriptionGetExtension($0, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String }
        XCTAssertEqual(primaries, kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String)
    }

    /// The movie carries what the Lock Screen needs to play it as a wallpaper, as the camera
    /// writes it: 8-bit HEVC at 30 fps; a `live-photo-info` track with the camera's 144-byte
    /// sample at every frame; one still sample in the 600 timescale holding still-image-time -1
    /// and an identity still-image transform; both tracks referring to the video (`cdsc`).
    func testTheMovieCarriesTheLockScreensWallpaperMetadata() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "livephoto-wallpaper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let frameCount = 45, keyFrame = 22
        let size = SIMD2(64, 128)
        let frame = try Self.solidImage(size.x, height: size.y)
        let movie = directory.appending(path: "clip.MOV")
        try LivePhotoMovieEncoder.write(to: movie, pixelSize: size, frameRate: 30, frameCount: frameCount, keyFrame: keyFrame,
                                        still: try Self.checkerImage(size.x, height: size.y), identifier: UUID().uuidString,
                                        bitRate: LivePhotoQuality.high.bitRate(for: size, frameRate: 30)) { _ in frame }

        let asset = AVURLAsset(url: movie)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let video = try XCTUnwrap(videoTracks.first)
        let videoFormats = try await video.load(.formatDescriptions)
        let videoFormat = try XCTUnwrap(videoFormats.first)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(videoFormat), kCMVideoCodecType_HEVC)
        let depth = CMFormatDescriptionGetExtension(videoFormat, extensionKey: kCMFormatDescriptionExtension_BitsPerComponent) as? Int
        XCTAssertEqual(depth, 8)
        let frameRate = try await video.load(.nominalFrameRate)
        XCTAssertEqual(Double(frameRate), 30, accuracy: 0.01)

        var info: AVAssetTrack?, still: AVAssetTrack?
        for track in try await asset.loadTracks(withMediaType: .metadata) {
            let identifiers = try await track.load(.formatDescriptions).flatMap(LivePhotoMetadata.identifiers(of:))
            if identifiers == ["mdta/" + LivePhotoMetadata.infoKey] { info = track }
            if Set(identifiers) == ["mdta/" + LivePhotoMetadata.stillImageTimeKey, "mdta/" + LivePhotoMetadata.stillImageTransformKey] {
                still = track
            }
        }
        let infoTrack = try XCTUnwrap(info, "no live-photo-info track")
        let stillTrack = try XCTUnwrap(still, "no still-image-time + still-image-transform track")
        for track in [infoTrack, stillTrack] {
            let referred = try await track.loadAssociatedTracks(ofType: .metadataReferent)
            XCTAssertEqual(referred.map(\.trackID), [video.trackID])
        }

        // live-photo-info: one sample a frame, each the camera's record at the frame's time.
        let infoSamples = try Self.samples(of: infoTrack, in: asset)
        XCTAssertEqual(infoSamples.count, frameCount)
        for (index, sample) in infoSamples.enumerated() {
            XCTAssertEqual(sample.time, LivePhotoMetadata.time(ofFrame: index, frameRate: 30))
            XCTAssertEqual(sample.bytes.count, 144)
            XCTAssertEqual(sample.bytes.suffix(136), LivePhotoMetadata.cameraInfoPayload)
        }
        let infoReader = try AVAssetReader(asset: asset)
        let infoOutput = AVAssetReaderTrackOutput(track: infoTrack, outputSettings: nil)
        infoReader.add(infoOutput)
        let infoAdaptor = AVAssetReaderOutputMetadataAdaptor(assetReaderTrackOutput: infoOutput)
        XCTAssertTrue(infoReader.startReading())
        let infoGroup = try XCTUnwrap(infoAdaptor.nextTimedMetadataGroup())
        XCTAssertEqual(infoGroup.items.first?.dataType, LivePhotoMetadata.infoDataType)
        infoReader.cancelReading()

        // The still: one sample at the key frame (in the 600 timescale), -1 and the identity.
        XCTAssertEqual(try Self.samples(of: stillTrack, in: asset).count, 1)
        let stillTimescale = try await stillTrack.load(.naturalTimeScale)
        XCTAssertEqual(stillTimescale, 600)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: stillTrack, outputSettings: nil)
        reader.add(output)
        let adaptor = AVAssetReaderOutputMetadataAdaptor(assetReaderTrackOutput: output)
        XCTAssertTrue(reader.startReading())
        let group = try XCTUnwrap(adaptor.nextTimedMetadataGroup())
        XCTAssertEqual(CMTimeGetSeconds(group.timeRange.start), Double(keyFrame) / 30, accuracy: 1e-6)
        let time = try XCTUnwrap(group.items.first { $0.identifier?.rawValue == LivePhotoMetadata.stillImageTimeIdentifier })
        let value = try await time.load(.numberValue)
        XCTAssertEqual(value?.intValue, -1)
        let transform = try XCTUnwrap(group.items.first { $0.identifier?.rawValue == "mdta/" + LivePhotoMetadata.stillImageTransformKey })
        let matrix = try await transform.load(.value) as? [NSNumber]
        XCTAssertEqual(matrix?.map(\.doubleValue), [1, 0, 0, 0, 1, 0, 0, 0, 1])
        reader.cancelReading()
    }

    /// A track's samples (with data) in order: their times and bytes.
    private static func samples(of track: AVAssetTrack, in asset: AVAsset) throws -> [(time: CMTime, bytes: Data)] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var samples: [(time: CMTime, bytes: Data)] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            guard length > 0 else { continue }
            var data = Data(count: length)
            data.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            samples.append((CMSampleBufferGetPresentationTimeStamp(sample), data))
        }
        return samples
    }

    // MARK: Images

    private static func solidImage(_ width: Int, height: Int? = nil) throws -> CGImage {
        let context = try context(width, height ?? width)
        context.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height ?? width))
        return try XCTUnwrap(context.makeImage())
    }

    private static func checkerImage(_ width: Int, height: Int? = nil) throws -> CGImage {
        let rows = height ?? width
        let context = try context(width, rows)
        for y in 0..<rows {
            for x in 0..<width {
                let on = (x / 2 + y / 2) % 2 == 0
                context.setFillColor(red: on ? 1 : 0, green: on ? 1 : 0, blue: on ? 1 : 0, alpha: 1)
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return try XCTUnwrap(context.makeImage())
    }

    private static func context(_ width: Int, _ height: Int) throws -> CGContext {
        try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
    }
}
