import AVFoundation
import CoreGraphics
import XCTest
@testable import OpenWallpaperEngine

final class LivePhotoTests: XCTestCase {
    private let landscape = SIMD2<Double>(1920, 1080)
    private let proMax = DeviceModel.model(id: "iPhone 17 Pro Max")
    private let pro = DeviceModel.model(id: "iPhone 17 Pro")

    // MARK: Crop and scale

    func testDefaultDeviceIsTheNewestLargestIPhone() {
        XCTAssertEqual(DeviceModel.defaultModel.name, "iPhone 17 Pro Max")
        XCTAssertEqual(proMax.pixelSize, SIMD2(1320, 2868))
        XCTAssertEqual(pro.pixelSize, SIMD2(1206, 2622))
        XCTAssertEqual(DeviceModel.model(id: "iPhone 16").pixelSize, SIMD2(1179, 2556))
        XCTAssertEqual(DeviceModel.model(id: "no such device"), DeviceModel.defaultModel)
    }

    func testCoverFitIsTheTallestPortraitWindowInALandscapeScene() {
        let crop = LivePhotoCrop(sceneSize: landscape, outputPixels: proMax.pixelSize)
        XCTAssertEqual(crop.coverSize.y, 1080, accuracy: 1e-9)
        XCTAssertEqual(crop.coverSize.x, 1080 * 1320 / 2868, accuracy: 1e-9)
        XCTAssertEqual(crop.cropRect.midX, 960, accuracy: 1e-9)
        XCTAssertEqual(crop.cropRect.minY, 0, accuracy: 1e-9)
    }

    func testCoverFitInAPortraitSceneUsesItsWidth() {
        let crop = LivePhotoCrop(sceneSize: SIMD2(1000, 4000), outputPixels: proMax.pixelSize)
        XCTAssertEqual(crop.coverSize.x, 1000, accuracy: 1e-9)
        XCTAssertEqual(crop.coverSize.y, 1000 * 2868 / 1320, accuracy: 1e-9)
    }

    func testPanIsClampedInsideTheScene() {
        var crop = LivePhotoCrop(sceneSize: landscape, outputPixels: proMax.pixelSize)
        crop.pan(by: SIMD2(-10_000, -10_000))
        XCTAssertEqual(crop.cropRect.minX, 0, accuracy: 1e-9)
        XCTAssertEqual(crop.cropRect.minY, 0, accuracy: 1e-9)
        crop.pan(by: SIMD2(10_000, 10_000))
        XCTAssertEqual(crop.cropRect.maxX, 1920, accuracy: 1e-9)
        XCTAssertEqual(crop.cropRect.maxY, 1080, accuracy: 1e-9)
    }

    func testZoomIsClampedAndShrinksTheWindow() {
        var crop = LivePhotoCrop(sceneSize: landscape, outputPixels: proMax.pixelSize)
        crop.setZoom(0.2)
        XCTAssertEqual(crop.zoom, 1)
        crop.setZoom(10)
        XCTAssertEqual(crop.zoom, LivePhotoCrop.maximumZoom)
        XCTAssertEqual(crop.cropSize.y, 360, accuracy: 1e-9)
        // Zooming at an edge keeps the window inside.
        crop.setZoom(1)
        crop.pan(by: SIMD2(10_000, 0))
        crop.setZoom(2)
        XCTAssertLessThanOrEqual(crop.cropRect.maxX, 1920 + 1e-9)
    }

    func testRenderScaleIsNeverBelowAuthoredNorThePhonesPixels() {
        for device in DeviceModel.all {
            for zoom in [1.0, 1.5, 2, 3] {
                let crop = LivePhotoCrop(sceneSize: landscape, outputPixels: device.pixelSize, zoom: zoom)
                XCTAssertGreaterThanOrEqual(crop.renderScale, 1)
                let rect = crop.renderCropRect
                XCTAssertGreaterThanOrEqual(Double(rect.height) + 1, Double(device.pixelSize.y), "\(device) \(zoom)")
                XCTAssertGreaterThanOrEqual(Double(rect.width) + 1, Double(device.pixelSize.x), "\(device) \(zoom)")
            }
        }
        // A scene far larger than the phone renders at its authored size.
        let large = LivePhotoCrop(sceneSize: SIMD2(7680, 4320), outputPixels: proMax.pixelSize)
        XCTAssertEqual(large.renderScale, 1)
        XCTAssertEqual(large.renderPixelSize, SIMD2(7680, 4320))
    }

    func testOutputIsExactlyTheDevicesPixels() throws {
        let crop = LivePhotoCrop(sceneSize: SIMD2(64, 36), outputPixels: SIMD2(33, 71), zoom: 2)
        let size = crop.renderPixelSize
        let context = try XCTUnwrap(CGContext(data: nil, width: size.x, height: size.y, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: size.x, height: size.y))
        let frame = try XCTUnwrap(context.makeImage())
        let output = try XCTUnwrap(crop.outputImage(from: frame))
        XCTAssertEqual(output.width, 33)
        XCTAssertEqual(output.height, 71)
    }

    // MARK: Clip

    func testClipStartIsClampedAndTheStillIsTheMiddleFrame() {
        var clip = LivePhotoClip(start: -4)
        XCTAssertEqual(clip.start, 0)
        clip.setStart(1_000)
        XCTAssertEqual(clip.start, LivePhotoClip.timelineLength - LivePhotoClip.duration)
        XCTAssertEqual(clip.end, LivePhotoClip.timelineLength)
        clip.setStart(.nan)
        XCTAssertEqual(clip.start, 0)
        clip.setStart(2)
        XCTAssertEqual(clip.frameCount, 90)
        XCTAssertEqual(clip.leadInFrames, 60)
        XCTAssertEqual(clip.keyFrameIndex, 45)
        XCTAssertEqual(clip.keyFrameSeconds, 1.5, accuracy: 1e-9)
    }

    /// The Lock Screen won't play a Live Photo whose still is in its first half second.
    func testTheStillIsNeverInTheFirstHalfSecond() {
        XCTAssertEqual(LivePhotoKeyFrame.earliestFrame(frameCount: 90), 15)
        for length in [1.0, 1.2, 1.5, 2, 3] {
            let clip = LivePhotoClip(length: length)
            XCTAssertGreaterThanOrEqual(clip.keyFrameSeconds, LivePhotoKeyFrame.earliestSeconds - 1e-9, "\(length) s")
            let band = LivePhotoKeyFrame.candidates(frameCount: clip.frameCount)
            XCTAssertGreaterThanOrEqual(band.lowerBound, 15, "\(length) s")
            XCTAssertLessThan(band.upperBound, clip.frameCount)
            XCTAssertTrue(band.contains(clip.keyFrameIndex))
        }
        // A sharper early frame of a 1 s clip isn't taken.
        var sharpness: [Int: Double] = [:]
        for index in 0..<30 { sharpness[index] = 1 }
        sharpness[9] = 10
        XCTAssertGreaterThanOrEqual(LivePhotoKeyFrame.choose(sharpness: sharpness, frameCount: 30), 15)
        // A clip shorter than half a second has its last frame as the still.
        XCTAssertEqual(LivePhotoKeyFrame.choose(sharpness: [:], frameCount: 10), 9)
        XCTAssertEqual(LivePhotoKeyFrame.candidates(frameCount: 10), 9...9)
        XCTAssertEqual(LivePhotoKeyFrame.candidates(frameCount: 1), 0...0)
    }

    /// The movie is at most 1920 pixels on its long side, at the device's aspect; the still keeps
    /// the device's pixels.
    func testTheMovieFitsTheLockScreensSize() {
        XCTAssertEqual(LivePhotoMovieEncoder.moviePixels(for: SIMD2(1320, 2868)), SIMD2(884, 1920))
        XCTAssertEqual(LivePhotoMovieEncoder.moviePixels(for: SIMD2(90, 196)), SIMD2(90, 196))
        XCTAssertEqual(LivePhotoMovieEncoder.moviePixels(for: SIMD2(1080, 1920)), SIMD2(1080, 1920))
        for device in DeviceModel.all {
            let movie = LivePhotoMovieEncoder.moviePixels(for: device.pixelSize)
            XCTAssertLessThanOrEqual(max(movie.x, movie.y), LivePhotoMovieEncoder.maximumMovieSide, device.name)
            XCTAssertEqual(movie.x % 2, 0, device.name)
            XCTAssertEqual(movie.y % 2, 0, device.name)
            let aspect = Double(device.pixelSize.x) / Double(device.pixelSize.y)
            XCTAssertEqual(Double(movie.x) / Double(movie.y), aspect, accuracy: 0.005, device.name)
        }
    }

    func testClipLengthIsAtMostThreeSecondsAndBoundsTheStart() {
        let short = LivePhotoClip(start: 100, length: 1)
        XCTAssertEqual(short.frameCount, 30)
        XCTAssertEqual(short.start, LivePhotoClip.timelineLength - 1)
        XCTAssertEqual(LivePhotoClip(length: 10).length, LivePhotoClip.duration)
        // Lengthening a clip at the end of the timeline moves its start back.
        var clip = short
        clip.setLength(3)
        XCTAssertEqual(clip.length, 3)
        XCTAssertEqual(clip.end, LivePhotoClip.timelineLength)
    }

    func testLandscapeWindowIsTheMiddleBandOfThePortraitCrop() {
        let crop = LivePhotoCrop(sceneSize: landscape, outputPixels: SIMD2(2064, 2752))
        let portrait = crop.cropRect
        let band = crop.landscapeRect
        let bandWidth: Double = band.width
        let bandHeight: Double = band.height
        XCTAssertEqual(bandWidth, portrait.width, accuracy: 1e-9)
        XCTAssertEqual(bandWidth / bandHeight, 2752.0 / 2064.0, accuracy: 1e-9)
        XCTAssertEqual(band.midY, portrait.midY, accuracy: 1e-9)
    }

    // MARK: Preview sound

    @MainActor func testPreviewFirstThenDesktopMakesTheInstanceAudible() {
        let preview = "iphone-preview"
        var users = [preview]
        XCTAssertTrue(SceneWallpaperInstance.isPreviewOnly(screenIDs: users))
        users.append("display-1")
        XCTAssertFalse(SceneWallpaperInstance.isPreviewOnly(screenIDs: users))
        users.removeAll { $0 == "display-1" }
        XCTAssertTrue(SceneWallpaperInstance.isPreviewOnly(screenIDs: users))
    }

    @MainActor func testDesktopFirstThenPreviewStaysAudible() {
        let preview = "iphone-preview"
        var users = ["display-1"]
        XCTAssertFalse(SceneWallpaperInstance.isPreviewOnly(screenIDs: users))
        users.append(preview)
        XCTAssertFalse(SceneWallpaperInstance.isPreviewOnly(screenIDs: users))
        users.removeAll { $0 == preview }
        XCTAssertFalse(SceneWallpaperInstance.isPreviewOnly(screenIDs: users))
        XCTAssertFalse(SceneWallpaperInstance.isPreviewOnly(screenIDs: []))
    }

    // MARK: Helper job

    func testJobRoundTripsTheCropClipAndProperties() throws {
        let crop = LivePhotoCrop(sceneSize: landscape, outputPixels: pro.pixelSize, zoom: 2,
                                 center: SIMD2(300, 400))
        let clip = LivePhotoClip(start: 4.5)
        let job = LivePhotoJob(wallpaperDirectory: URL(filePath: "/tmp/w", directoryHint: .isDirectory),
                               properties: ["schemecolor": "1 0 0"], crop: crop, clip: clip, quality: .high,
                               still: URL(filePath: "/tmp/a.HEIC"), movie: URL(filePath: "/tmp/a.MOV"), identifier: "id")
        let decoded = try JSONDecoder().decode(LivePhotoJob.self, from: JSONEncoder().encode(job))
        XCTAssertEqual(decoded, job)
        XCTAssertEqual(decoded.crop, crop)
        XCTAssertEqual(decoded.clip, clip)
        XCTAssertEqual(decoded.properties["schemecolor"], "1 0 0")
        XCTAssertEqual(decoded.qualityLevel, .high)
        XCTAssertNil(LivePhotoJob(wallpaperDirectory: URL(filePath: "/tmp/w"), properties: [:], crop: crop, clip: clip,
                                  still: nil, movie: URL(filePath: "/tmp/p.MOV"), identifier: "p").still)
    }

    func testProgressLinesParse() {
        let line = LivePhotoJob.progressLine(0.25)
        XCTAssertEqual(LivePhotoJob.progress(fromLine: Substring(line.dropLast())), 0.25)
        XCTAssertNil(LivePhotoJob.progress(fromLine: "something else"))
        XCTAssertEqual(LivePhotoJob.progress(fromLine: Substring(LivePhotoJob.progressLine(7).dropLast())), 1)
    }

    // MARK: Render policy

    func testExportHidesClockLayersIsMutedAndRendersAtFullDetail() {
        XCTAssertTrue(LivePhotoRenderer.Policy.hidesClockLayers)
        XCTAssertTrue(LivePhotoRenderer.Policy.muted)
        var settings = GlobalSettings()
        settings.sceneDetail = .matchDisplay
        settings.upscaling = GSUpscaling.allCases.last ?? .off
        settings.renderResolution = .uhd4K
        let render = LivePhotoRenderer.renderSettings(from: settings)
        XCTAssertEqual(render.sceneDetail, .full)
        XCTAssertEqual(render.renderResolution, .yourDisplay, "sized for the export's own drawable")
        XCTAssertTrue(render.floorsAtAuthoredSize, "never below the scene's authored size")
        XCTAssertEqual(render.upscaling, .off)
        XCTAssertEqual(render.textureReduction, 1)
        XCTAssertEqual(render.drawnScale, 1)
    }

    func testClockTextLayersAreFound() throws {
        let json = """
        {"objects":[{"id":3,"text":{"script":"export function update(){ return new Date().getHours(); }"}},
                    {"id":4,"text":{"script":"export function update(){ return 'hi'; }"}}]}
        """
        let document = try JSONDecoder().decode(SceneJSON.self, from: Data(json.utf8))
        XCTAssertEqual(SceneClockLayers.ids(in: document), ["3"])
    }

    // MARK: Pairing metadata

    func testStillAndMovieArePairedWithAStillImageTime() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "livephoto-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let identifier = UUID().uuidString
        let size = SIMD2(64, 128)
        let image = try Self.solidImage(size)

        let still = directory.appending(path: "test.HEIC")
        try LivePhotoMetadata.writeStill(image, to: still, identifier: identifier)
        XCTAssertEqual(LivePhotoMetadata.stillIdentifier(at: still), identifier)

        let movie = directory.appending(path: "test.MOV")
        var tracks: LivePhotoMetadata.Tracks?
        let writer = try XCTUnwrap(HEVCWriter(url: movie, pixelSize: size, frameRate: 30) { writer in
            writer.metadata = [LivePhotoMetadata.contentIdentifierItem(identifier)]
            tracks = try LivePhotoMetadata.addTracks(to: writer)
        })
        let metadata = try XCTUnwrap(tracks)
        let stillTime = LivePhotoMetadata.time(ofFrame: 4, frameRate: 30)
        XCTAssertEqual(stillTime.timescale, 600)
        XCTAssertTrue(metadata.still.append(try LivePhotoMetadata.stillSample(format: metadata.stillFormat, at: stillTime)))
        metadata.still.markAsFinished()
        for frame in 0..<9 {
            XCTAssertTrue(writer.append(image, overlay: nil, weight: 0, frame: frame))
            let info = try LivePhotoMetadata.infoSample(format: metadata.infoFormat,
                                                        at: LivePhotoMetadata.time(ofFrame: frame, frameRate: 30),
                                                        duration: LivePhotoMetadata.time(ofFrame: 1, frameRate: 30))
            XCTAssertTrue(writer.waitUntilReady(metadata.info))
            XCTAssertTrue(metadata.info.append(info))
        }
        metadata.info.markAsFinished()
        XCTAssertTrue(writer.finish())

        let movieIdentifier = try await LivePhotoMetadata.movieIdentifier(at: movie)
        XCTAssertEqual(movieIdentifier, identifier)
        let time = try await LivePhotoMetadata.movieStillImageTime(at: movie)
        XCTAssertEqual(time.map(CMTimeGetSeconds) ?? -1, CMTimeGetSeconds(stillTime), accuracy: 1e-6)
    }

    private static func solidImage(_ size: SIMD2<Int>) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: size.x, height: size.y, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                                  | CGBitmapInfo.byteOrder32Little.rawValue))
        context.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: size.x, height: size.y))
        return try XCTUnwrap(context.makeImage())
    }
}
