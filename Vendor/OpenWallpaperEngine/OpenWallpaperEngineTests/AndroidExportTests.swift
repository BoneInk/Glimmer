import AVFoundation
import Foundation
import XCTest
@testable import OpenWallpaperEngine

/// Android export: WE's dialog's options and what they map to, the pre-rendered crop, the
/// batch queue (order, skips, names, cancellation) and a short real pre-render.
@MainActor
final class AndroidExportTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "owe-android-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory) // scratch cleanup
    }

    private func wallpaper(_ name: String, type: String, title: String? = nil) throws -> WEWallpaper {
        let folder = directory.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = type == "video" ? "clip.mp4" : type == "web" ? "index.html" : "scene.json"
        try Data(#"{"file": "\#(file)", "title": "\#(title ?? name)", "type": "\#(type)", "preview": "preview.jpg"}"#.utf8)
            .write(to: folder.appending(path: "project.json"))
        try Data([0]).write(to: folder.appending(path: file))
        return try XCTUnwrap(InstalledLibrary.wallpaper(at: folder, hiding: []))
    }

    // MARK: Options

    func testQualityButtonsPresetTheTextureReduction() {
        XCTAssertEqual(AndroidExportOptions(mode: .highQuality).textureReduction, .original)
        XCTAssertEqual(AndroidExportOptions(mode: .balanced).textureReduction, .half)
        XCTAssertEqual(AndroidExportOptions(mode: .balanced).sceneTextureReduction, 2, "WE's Balanced scene.json")
        XCTAssertEqual(AndroidExportOptions(mode: .preRendered).sceneTextureReduction, 4, "WE's Pre-Rendered scene.json")
        var pixelArt = AndroidExportOptions(mode: .balanced)
        pixelArt.pixelArt = true
        XCTAssertEqual(pixelArt.effectiveTextureReduction, .original, "pixel art keeps every pixel")
        XCTAssertEqual(pixelArt.sceneTextureReduction, 1)
        var advanced = AndroidExportOptions(mode: .highQuality)
        advanced.textureReduction = .quarter
        XCTAssertEqual(advanced.sceneTextureReduction, 4, "the advanced setting overrides the preset")
    }

    func testVideoSizesAndBitRateAreWEs() {
        let landscape = SIMD2<Double>(1920, 1080)
        var options = AndroidExportOptions(mode: .preRendered)
        XCTAssertEqual(options.videoPixelSize(sceneSize: landscape), SIMD2(1080, 1920), "Full HD, fit to phone screen")
        XCTAssertEqual(options.videoBitRate(pixelSize: SIMD2(1080, 1920)), 8_000_000)
        options.videoPreset = .uhd4K
        XCTAssertEqual(options.videoPixelSize(sceneSize: landscape), SIMD2(2160, 3840))
        options.videoPreset = .original
        XCTAssertEqual(options.videoPixelSize(sceneSize: landscape), SIMD2(608, 1080))
        options.cropping = .original
        options.videoPreset = .fullHD
        XCTAssertEqual(options.videoPixelSize(sceneSize: landscape), SIMD2(1920, 1080), "the scene's own shape")
        options.frameRate = 60
        XCTAssertEqual(options.videoBitRate(pixelSize: SIMD2(1920, 1080)), 16_000_000)
    }

    func testAlignmentMovesThePortraitCropAcrossTheScene() {
        var options = AndroidExportOptions(mode: .preRendered)
        let scene = SIMD2<Double>(1920, 1080)
        options.alignment = 0
        XCTAssertEqual(options.crop(sceneSize: scene).cropRect.minX, 0, accuracy: 0.001)
        options.alignment = 1
        XCTAssertEqual(options.crop(sceneSize: scene).cropRect.maxX, 1920, accuracy: 0.001)
        options.alignment = 0.5
        let centred = options.crop(sceneSize: scene)
        XCTAssertEqual(centred.cropRect.midX, 960, accuracy: 0.001)
        XCTAssertEqual(centred.cropRect.height, 1080, accuracy: 0.001)
        XCTAssertEqual(centred.cropRect.width, 607.5, accuracy: 0.001, "9:16 at the scene's height")
        XCTAssertEqual(centred.outputPixels, SIMD2(1080, 1920))
    }

    // MARK: Plan and names

    func testWebAndApplicationWallpapersAreSkippedWithWEsReason() throws {
        let scene = try wallpaper("scene", type: "scene"), web = try wallpaper("web", type: "web"),
            video = try wallpaper("video", type: "video"), app = try wallpaper("app", type: "application")
        let plan = AndroidExportPlan.make([scene, web, video, app, scene], options: { _ in AndroidExportOptions() })
        XCTAssertEqual(plan.items.map(\.wallpaper.project.title), ["scene", "video"], "in order, once each")
        XCTAssertEqual(plan.skipped.map(\.title), ["web", "app"])
        XCTAssertEqual(Set(plan.skipped.map(\.reason)), [String(localized: "Wallpaper type not supported on Android devices")])
    }

    func testMissingVideoIsSkipped() throws {
        let video = try wallpaper("gone", type: "video")
        try FileManager.default.removeItem(at: video.wallpaperDirectory.appending(path: "clip.mp4"))
        XCTAssertEqual(AndroidExportPlan.make([video], options: { _ in AndroidExportOptions() }).skipped.count, 1)
    }

    func testNamesAreUniqueInTheBatchAndTheFolder() {
        XCTAssertEqual(AndroidExportNaming.uniqueNames(["Rain", "rain", "Rain", "A/B: C", "", "Snow"], taken: ["Snow.mpkg"]),
                       ["Rain.mpkg", "rain 2.mpkg", "Rain 3.mpkg", "A-B- C.mpkg", "Wallpaper.mpkg", "Snow 2.mpkg"])
    }

    // MARK: Queue

    /// A worker that finishes items in a given order and records how many pre-renders overlap.
    @MainActor
    final class FakeWorker: AndroidExportWorking {
        var delays: [String: UInt64] = [:]
        var running = 0, runningGPU = 0, maxGPU = 0, maxRunning = 0
        var started: [String] = []
        var fails: Set<String> = []

        func export(_ item: AndroidExportItem, to url: URL, progress: @escaping @MainActor (Double) -> Void) async throws {
            started.append(item.wallpaper.project.title)
            running += 1
            if item.usesGPU { runningGPU += 1 }
            maxGPU = max(maxGPU, runningGPU)
            maxRunning = max(maxRunning, running)
            defer {
                running -= 1
                if item.usesGPU { runningGPU -= 1 }
            }
            progress(0.5)
            try await Task.sleep(nanoseconds: delays[item.wallpaper.project.title] ?? 1_000_000)
            if fails.contains(item.wallpaper.project.title) { throw AndroidPackageBuilder.Failure.missingFile("x") }
            try Data([1]).write(to: url)
        }
    }

    private func item(_ title: String, _ mode: AndroidExportOptions.Mode, type: String = "scene") throws -> AndroidExportItem {
        AndroidExportItem(wallpaper: try wallpaper(title, type: type), options: AndroidExportOptions(mode: mode))
    }

    func testBatchKeepsTheSelectionsOrderAndPreRendersOneAtATime() async throws {
        let worker = FakeWorker()
        worker.delays = ["A": 60_000_000, "B": 1_000_000, "C": 30_000_000, "D": 1_000_000]
        let items = [try item("A", .preRendered), try item("B", .balanced), try item("C", .preRendered),
                     try item("D", .highQuality, type: "video"), try item("E", .balanced)]
        worker.fails = ["E"]
        let output = directory.appending(path: "out", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let queue = AndroidExportQueue(items: items, skipped: [.init(wallpaperID: "w", title: "Web", reason: "no")], folder: output,
                                       worker: worker)
        let batch = await queue.run()
        XCTAssertEqual(batch.outputs.map(\.title), ["A", "B", "C", "D"], "the selection's order, whatever finished first")
        XCTAssertEqual(batch.outputs.map(\.url.lastPathComponent), ["A.mpkg", "B.mpkg", "C.mpkg", "D.mpkg"])
        XCTAssertEqual(batch.outputs.map(\.type), ["scene", "scene", "scene", "video"])
        XCTAssertEqual(batch.outputs[3].mode, nil)
        XCTAssertEqual(batch.failed.map(\.title), ["E"])
        XCTAssertEqual(batch.skipped.map(\.title), ["Web"])
        XCTAssertEqual(worker.maxGPU, 1, "pre-renders take the GPU one at a time")
        XCTAssertGreaterThan(worker.maxRunning, 1, "file work runs beside them")
        XCTAssertEqual(queue.progress, 1)
        XCTAssertFalse(batch.wasCancelled)
    }

    func testCancellingStopsWhatRunsAndLeavesTheRest() async throws {
        let worker = FakeWorker()
        worker.delays = ["A": 5_000_000_000, "B": 5_000_000_000, "C": 5_000_000_000, "D": 5_000_000_000]
        let items = [try item("A", .preRendered), try item("B", .preRendered), try item("C", .balanced),
                     try item("D", .balanced), try item("E", .balanced)]
        let queue = AndroidExportQueue(items: items, folder: directory, taken: [], worker: worker)
        let run = Task { await queue.run() }
        try await Task.sleep(nanoseconds: 50_000_000)
        queue.cancel()
        let batch = await run.value
        XCTAssertTrue(batch.wasCancelled)
        XCTAssertTrue(batch.outputs.isEmpty)
        XCTAssertEqual(queue.entries.map(\.status), Array(repeating: .cancelled, count: 5))
        XCTAssertFalse(worker.started.contains("B"), "a waiting pre-render never starts")
        XCTAssertFalse(worker.started.contains("E"), "a waiting file item never starts")
    }

    // MARK: Pre-render

    /// A short real render: an H.264 Constrained Baseline `.mp4` at the job's size and frame rate,
    /// exactly `seconds × fps` frames long.
    func testPreRenderIsAnH264LoopOfTheRightLength() async throws {
        _ = try Fixtures.assets()
        let fixture = try Fixtures.temporaryCopy(of: "Scenes/layers")
        defer {
            Fixtures.removeStoredSettings(for: fixture)
            try? FileManager.default.removeItem(at: fixture) // scratch cleanup
        }
        let wallpaper = try XCTUnwrap(InstalledLibrary.wallpaper(at: fixture, hiding: []))
        var options = AndroidExportOptions(mode: .preRendered)
        options.videoPreset = .original
        let sceneSize = try AndroidPackageBuilder.sceneSize(wallpaper)
        let crop = LivePhotoCrop(sceneSize: sceneSize, outputPixels: SIMD2(180, 320))
        let output = directory.appending(path: "wallpaper.mp4")
        let job = AndroidVideoJob(wallpaperDirectory: wallpaper.wallpaperDirectory, properties: [:], crop: crop, frameRate: 30,
                                  seconds: 1, bitRate: 1_000_000, output: output)
        try await AndroidVideoRenderer.render(job, wallpaper: wallpaper, crop: crop) { _ in }
        let asset = AVURLAsset(url: output)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let (size, rate, range) = try await track.load(.naturalSize, .nominalFrameRate, .timeRange)
        XCTAssertEqual(size, CGSize(width: 180, height: 320))
        XCTAssertEqual(rate, 30, accuracy: 0.01)
        XCTAssertEqual(range.duration.seconds, 1, accuracy: 0.001)
        let formats = try await track.load(.formatDescriptions)
        let format = try XCTUnwrap(formats.first)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(format), kCMVideoCodecType_H264)
        let profile = (CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms)
            as? [String: Any])?["avcC"] as? Data
        XCTAssertEqual(profile?[1], 66, "Baseline profile")
        XCTAssertEqual(profile.map { $0[2] & 0x40 }, 0x40, "constrained (constraint_set1)")
    }
}
