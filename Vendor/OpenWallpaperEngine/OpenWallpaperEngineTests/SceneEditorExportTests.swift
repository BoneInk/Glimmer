import AVFoundation
import CoreImage
import ImageIO
import OWESceneEditing
import XCTest
@testable import OpenWallpaperEngine

/// Exporting in Scene Edit / Export: the library has no export entry points, a video opens
/// the editor with the modes that apply to it, its Android package is the video byte for byte,
/// its Live Photo is a paired still and movie, and "Export More with These Settings…" runs its
/// queue in order, cancels, applies the edits only to the edited wallpaper and hands AirDrop
/// every Live Photo paired.
@MainActor
final class SceneEditorExportTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUpWithError() throws {
        suite = "owe-editor-export-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        directory = FileManager.default.temporaryDirectory.appending(path: suite, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory) // scratch cleanup
    }

    // MARK: Fixtures

    /// A wallpaper folder of `type` with `file` (bytes, or a real movie for `movie`).
    private func wallpaper(_ name: String, type: String, file: String, title: String? = nil,
                           movie: Bool = false) throws -> WEWallpaper {
        let folder = directory.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = #"{"file": "\#(file)", "title": "\#(title ?? name)", "type": "\#(type)", "preview": "preview.gif", "workshopid": "424242"}"#
        try Data(project.utf8).write(to: folder.appending(path: "project.json"))
        try Data("GIF89a-preview".utf8).write(to: folder.appending(path: "preview.gif"))
        if movie {
            try Self.writeMovie(to: folder.appending(path: file))
        } else {
            try Data([0, 1, 2]).write(to: folder.appending(path: file))
        }
        return try XCTUnwrap(InstalledLibrary.wallpaper(at: folder, hiding: []))
    }

    private func scene(_ name: String) throws -> WEWallpaper {
        let wallpaper = try wallpaper(name, type: "scene", file: "scene.json")
        try Data(#"{"camera": {}, "general": {"orthogonalprojection": {"width": 1600, "height": 900}}, "objects": []}"#.utf8)
            .write(to: wallpaper.wallpaperDirectory.appending(path: "scene.json"))
        return wallpaper
    }

    /// A short H.264 movie (2 s at 30 fps, 320 × 180) whose bar moves across a gradient.
    static func writeMovie(to url: URL, size: SIMD2<Int> = SIMD2(320, 180), frames: Int = 60) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: url.pathExtension.lowercased() == "mov" ? .mov : .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: size.x, AVVideoHeightKey: size.y,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size.x, kCVPixelBufferHeightKey as String: size.y,
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for index in 0..<frames {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &buffer)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
            let row = CVPixelBufferGetBytesPerRow(pixels)
            let bar = index * size.x / frames
            for y in 0..<size.y {
                for x in 0..<size.x {
                    let pixel = base + y * row + x * 4
                    let lit = abs(x - bar) < 12
                    pixel[0] = UInt8(truncatingIfNeeded: y)
                    pixel[1] = lit ? 255 : UInt8(truncatingIfNeeded: x)
                    pixel[2] = lit ? 255 : 40
                    pixel[3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            XCTAssertTrue(adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: 30)))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        XCTAssertEqual(writer.status, .completed, writer.error.map { "\($0)" } ?? "")
    }

    private func session(_ wallpaper: WEWallpaper) -> IsolatedSceneEditSession {
        let session = IsolatedSceneEditSession(wallpaper: wallpaper, purpose: "editor-export-test-\(UUID().uuidString)",
                                               seededFrom: [.shared], defaults: defaults)
        addTeardownBlock { @MainActor in session.end() }
        return session
    }

    // MARK: Scene size

    /// The exports frame the scene as the renderer draws it (WE's canvas, 0x14018b2c0), not the
    /// extent of its objects: a perspective scene is 1920×1080 whatever its objects' world units,
    /// `auto` takes its first image's size.
    func testExportsMeasureTheDrawnCanvas() throws {
        let perspective = try wallpaper("perspective", type: "scene", file: "scene.json")
        try Data(#"{"camera": {}, "general": {}, "objects": [{"origin": "4000 3000 0", "size": "200 100", "image": "models/a.json"}]}"#.utf8)
            .write(to: perspective.wallpaperDirectory.appending(path: "scene.json"))
        XCTAssertEqual(try AndroidPackageBuilder.sceneSize(perspective), SIMD2(1920, 1080))

        let auto = Data(#"{"camera": {}, "general": {"orthogonalprojection": {"auto": true}}, "objects": [{"origin": "0 0 0", "size": "800 600", "image": "models/a.json"}, {"origin": "5000 5000 0", "size": "10 10", "image": "models/b.json"}]}"#.utf8)
        XCTAssertEqual(try SceneDrawnSize.of(sceneData: auto, overlay: nil), SIMD2(800, 600))
        XCTAssertEqual(try AndroidPackageBuilder.sceneSize(try scene("ortho")), SIMD2(1600, 900))
    }

    /// The editor's overlay changes what the renderer draws, so the size is read with it applied.
    func testDrawnSizeAppliesTheEditOverlay() throws {
        let authored = Data(#"{"camera": {}, "general": {"orthogonalprojection": {"width": 1600, "height": 900}}, "objects": []}"#.utf8)
        var overlay = SceneEditOverlay()
        overlay.general = ["orthogonalprojection": .object(["width": .number(1280), "height": .number(1280)])]
        XCTAssertEqual(try SceneDrawnSize.of(sceneData: authored, overlay: overlay), SIMD2(1280, 1280))
        XCTAssertEqual(try SceneDrawnSize.of(sceneData: authored, overlay: nil), SIMD2(1600, 900))
    }

    // MARK: Library entry points

    /// The library, its menus and the Details panel no longer export: every export is in the
    /// Scene Edit / Export. The sheet that did is gone. The Installed tab only shows the Android
    /// Export mode's batch picker (`AndroidBatchPicker`); it never starts one itself.
    func testTheLibraryHasNoExportEntryPoints() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "OpenWallpaperEngine", directoryHint: .isDirectory)
        let banned = ["AndroidExportSheet", "AndroidExportModel(", "AndroidExportSelection", "Export for Android",
                      "LivePhotoExportModel(", "mode: .deviceExport", "mode: .androidExport", "androidExport =",
                      "AndroidBatchPicker(model", "beginAndroidBatchPicking(", "chooseMoreWallpapers(", "exportMore("]
        var found: [String] = []
        for folder in ["UI", "Library", "App/Menus"] {
            let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: source.appending(path: folder), includingPropertiesForKeys: nil))
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let text = try String(contentsOf: url, encoding: .utf8)
                for term in banned where text.contains(term) { found.append("\(folder)/\(url.lastPathComponent): \(term)") }
            }
        }
        XCTAssertEqual(found, [], "export entry points left in the library")
        for removed in ["AndroidExport/AndroidExportSheet.swift", "AndroidExport/AndroidExportModel.swift",
                        "AndroidExport/Editor/AndroidBatchExportSheet.swift"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: source.appending(path: removed).path(percentEncoded: false)), removed)
        }
    }

    // MARK: Modes

    func testAVideoShowsItsScreenSaverAndExportsButNoWallpaperMode() throws {
        let video = try wallpaper("video", type: "video", file: "clip.mp4")
        let entries = SceneEditorModes.entries(for: video)
        XCTAssertEqual(entries.map(\.mode), [.screenSaver, .deviceExport, .androidExport])
        XCTAssertTrue(entries.allSatisfy(\.availability.isAvailable))
        XCTAssertEqual(SceneEditorModes.initialMode(.wallpaper, for: video), .screenSaver, "the hidden Wallpaper mode opens the first")
        XCTAssertEqual(SceneEditorModes.initialMode(.androidExport, for: video), .androidExport)
    }

    func testAWebMVideoKeepsAndroidAndShowsWhyTheOthersCantBeUsed() throws {
        let webm = try wallpaper("webm", type: "video", file: "clip.webm")
        let entries = SceneEditorModes.entries(for: webm)
        XCTAssertEqual(entries.map(\.mode), [.screenSaver, .deviceExport, .androidExport])
        XCTAssertEqual(entries[0].availability, .unavailable(String(
            localized: "A WebM video is drawn live through the Chromium engine. Set it with Set as Screen Saver in the library.",
            comment: "Scene Edit / Export: why a WebM video's Screen Saver tab can't be used")), "it is set from the library")
        XCTAssertFalse(entries[1].availability.isAvailable)
        XCTAssertEqual(entries[2].availability, .available, "WE packs any local video")
    }

    func testAWebWallpaperShowsAndroidUnavailableWithWEsMessage() throws {
        let web = try wallpaper("web", type: "web", file: "index.html")
        let entries = SceneEditorModes.entries(for: web)
        XCTAssertEqual(entries.map(\.mode), [.wallpaper, .androidExport])
        XCTAssertEqual(entries[1].availability, .unavailable(String(localized: "Wallpaper type not supported on Android devices")))
        XCTAssertEqual(SceneEditorModes.initialMode(.deviceExport, for: web), .wallpaper)
    }

    func testASceneShowsEveryMode() throws {
        let entries = SceneEditorModes.entries(for: try scene("scene"))
        XCTAssertEqual(entries.map(\.mode), SceneInspectorMode.allCases)
        XCTAssertTrue(entries.allSatisfy(\.availability.isAvailable))
    }

    // MARK: Video exports

    /// The video's own file: a Workshop video in `OWE_LIBRARY` (WE's sample) when there is one,
    /// else a movie written here.
    private func sampleVideo() throws -> WEWallpaper {
        for root in (ProcessInfo.processInfo.environment["OWE_LIBRARY"] ?? "").split(separator: ":") where !root.isEmpty {
            let folder = URL(filePath: String(root), directoryHint: .isDirectory)
            let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] // Optional: no library, no sample.
            for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                if let wallpaper = InstalledLibrary.wallpaper(at: item, hiding: []), ScreenSaverVideoSource.isEligible(wallpaper),
                   wallpaper.previewURL != nil {
                    return wallpaper
                }
            }
        }
        return try wallpaper("sample", type: "video", file: "Floating In Space.mp4", title: "Floating In Space", movie: true)
    }

    /// The Android Export mode's package of a video is WE's: the original video byte for byte, the
    /// preview and the minimal project.json.
    func testTheVideoPackageHoldsTheOriginalVideoByteForByte() async throws {
        let video = try sampleVideo()
        let model = AndroidExportEditorModel(session: session(video), sceneSize: SIMD2(1920, 1080), defaults: defaults)
        XCTAssertTrue(model.isVideo)
        let item = model.item
        XCTAssertNil(item.bakedValues)
        XCTAssertFalse(item.usesGPU)
        let output = directory.appending(path: "video.mpkg")
        try await AndroidExporter().export(item, to: output) { _ in }

        let parser = try PKGParser(data: Data(contentsOf: output), magic: "PKGM")
        let file = video.project.file
        let preview = try XCTUnwrap(video.project.preview)
        XCTAssertEqual(Set(parser.fileList), [file, preview, "project.json"])
        XCTAssertEqual(parser.extractFile(named: file), try Data(contentsOf: video.mediaURL), "the video is the original, byte for byte")
        XCTAssertEqual(parser.extractFile(named: preview), try Data(contentsOf: try XCTUnwrap(video.previewURL)))
        let project = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(parser.extractFile(named: "project.json"))) as? [String: String])
        XCTAssertEqual(project, ["file": file, "preview": preview, "title": video.project.title, "type": "video"])
    }

    /// A Live Photo from a video goes through the same writer as a scene's: a HEIC and a movie
    /// carrying one content identifier, the movie marking the still's moment, at the device's pixels.
    func testALivePhotoFromAVideoIsAPairedStillAndMovie() async throws {
        let video = try wallpaper("live", type: "video", file: "clip.mov", movie: true)
        let size = try await XCTUnwrapAsync(await SceneEditorModes.videoSize(of: video.mediaURL))
        XCTAssertEqual(size, SIMD2(320, 180))
        let crop = LivePhotoCrop(sceneSize: size, outputPixels: SIMD2(90, 196))
        let clip = LivePhotoClip(start: 1.5, length: 1)
        let out = directory.appending(path: "out", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let still = out.appending(path: "live.HEIC"), movie = out.appending(path: "live.MOV")
        let identifier = UUID().uuidString // as every export names it
        let job = LivePhotoJob(wallpaperDirectory: video.wallpaperDirectory, properties: [:], crop: crop, clip: clip,
                               quality: .smaller, still: still, movie: movie, identifier: identifier)
        try await LivePhotoRenderer(wallpaper: video, defaults: defaults).write(job, crop: crop) { _ in }

        XCTAssertEqual(LivePhotoMetadata.stillIdentifier(at: still), identifier)
        let movieIdentifier = try await LivePhotoMetadata.movieIdentifier(at: movie)
        XCTAssertEqual(movieIdentifier, identifier)
        let stillTime = try await XCTUnwrapAsync(try await LivePhotoMetadata.movieStillImageTime(at: movie))
        XCTAssertGreaterThanOrEqual(CMTimeGetSeconds(stillTime), LivePhotoKeyFrame.earliestSeconds - 1e-6)
        XCTAssertLessThan(CMTimeGetSeconds(stillTime), clip.length)
        let track = try await XCTUnwrapAsync(try await AVURLAsset(url: movie).loadTracks(withMediaType: .video).first)
        let natural = try await track.load(.naturalSize)
        XCTAssertEqual(natural, CGSize(width: 90, height: 196))
        let frames = try await track.load(.timeRange).duration
        XCTAssertEqual(CMTimeGetSeconds(frames), clip.length, accuracy: 0.05)
    }

    /// An export for a device taller than the Lock Screen's movies (an iPhone 17 Pro Max) keeps the
    /// device's pixels in the still and writes the movie at 1920 pixels high, with the metadata
    /// tracks the Lock Screen wants for motion.
    func testALivePhotoForALargeDeviceIsWallpaperReady() async throws {
        let video = try wallpaper("large", type: "video", file: "clip.mov", movie: true)
        let device = DeviceModel.model(id: "iPhone 17 Pro Max")
        XCTAssertEqual(device.pixelSize, SIMD2(1320, 2868))
        let crop = LivePhotoCrop(sceneSize: SIMD2(320, 180), outputPixels: device.pixelSize)
        let clip = LivePhotoClip(start: 0, length: 1)
        let out = directory.appending(path: "large-out", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let still = out.appending(path: "live.HEIC"), movie = out.appending(path: "live.MOV")
        let job = LivePhotoJob(wallpaperDirectory: video.wallpaperDirectory, properties: [:], crop: crop, clip: clip,
                               quality: .smaller, still: still, movie: movie, identifier: UUID().uuidString)
        try await LivePhotoRenderer(wallpaper: video, defaults: defaults).write(job, crop: crop) { _ in }

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(still as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 1320)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 2868)
        let asset = AVURLAsset(url: movie)
        let track = try await XCTUnwrapAsync(try await asset.loadTracks(withMediaType: .video).first)
        let natural = try await track.load(.naturalSize)
        XCTAssertEqual(natural, CGSize(width: 884, height: 1920))
        var identifiers: Set<String> = []
        for metadata in try await asset.loadTracks(withMediaType: .metadata) {
            for format in try await metadata.load(.formatDescriptions) {
                identifiers.formUnion(LivePhotoMetadata.identifiers(of: format))
            }
        }
        XCTAssertEqual(identifiers, ["mdta/com.apple.quicktime.live-photo-info", "mdta/com.apple.quicktime.still-image-time",
                                     "mdta/com.apple.quicktime.live-photo-still-image-transform"])
        let stillTime = try await XCTUnwrapAsync(try await LivePhotoMetadata.movieStillImageTime(at: movie))
        XCTAssertGreaterThanOrEqual(CMTimeGetSeconds(stillTime), 0.5 - 1e-6)
    }

    /// The video's frames are its own at the clip's times: the motion analysis sees the bar move.
    func testTheVideosMotionIsMeasuredFromItsFrames() async throws {
        let video = try wallpaper("motion", type: "video", file: "clip.mp4", movie: true)
        let crop = LivePhotoCrop(sceneSize: SIMD2(320, 180), outputPixels: SIMD2(90, 196))
        let url = directory.appending(path: "motion.json")
        try await LivePhotoRenderer(wallpaper: video, defaults: defaults).analyse(crop: crop, seconds: 2, into: url) { _ in }
        let analysis = try JSONDecoder().decode(LivePhotoMotion.Analysis.self, from: Data(contentsOf: url))
        XCTAssertEqual(analysis.differences.count, 60)
        XCTAssertGreaterThan(analysis.differences.dropFirst().reduce(0, +), 0, "the bar moves")
    }

    // MARK: Batch: Android

    func testAndroidBatchAppliesTheEditsOnlyToTheEditedWallpaper() throws {
        let edited = try scene("edited")
        let other = try scene("other")
        let video = try wallpaper("clip", type: "video", file: "clip.mp4")
        let web = try wallpaper("page", type: "web", file: "index.html")
        let session = session(edited)
        session.setValues([sceneObjectVisibilityKey(objectID: 1): "false", "speed": "0.9"])
        let model = AndroidExportEditorModel(session: session, sceneSize: SIMD2(1600, 900), defaults: defaults)
        model.chooseMode(.preRendered)
        model.options.frameRate = 24
        model.setSeconds(10)

        let plan = model.batchPlan([edited, other, video, web, other])
        XCTAssertEqual(plan.items.map(\.wallpaper.project.title), ["edited", "other", "clip"], "the order given, once each")
        XCTAssertEqual(plan.skipped.map(\.reason), [String(localized: "Wallpaper type not supported on Android devices")])
        XCTAssertEqual(plan.items[0], model.item, "the edited wallpaper exports as edited")
        XCTAssertEqual(plan.items[0].properties[sceneObjectVisibilityKey(objectID: 1)], "false")
        XCTAssertNotNil(plan.items[0].framing)
        let others = plan.items[1]
        XCTAssertEqual(others.properties, [:], "the others export as authored")
        XCTAssertNil(others.framing)
        XCTAssertNil(others.bakedValues)
        XCTAssertEqual(others.options.mode, .preRendered)
        XCTAssertEqual(others.options.frameRate, 24, "the mode's frame rate")
        XCTAssertEqual(others.screen, AndroidVideoScreen(pixels: model.outputPixels, seconds: 10), "the mode's screen and length")
        let framing = others.framing(sceneSize: SIMD2(1920, 1080))
        XCTAssertEqual(framing.crop.outputPixels, model.outputPixels)
        XCTAssertEqual(framing.crop.center, SIMD2(960, 540), "centred")
        XCTAssertNil(plan.items[2].screen, "a video is packed as it is")

        model.chooseMode(.balanced)
        let dynamic = model.batchPlan([edited, other])
        XCTAssertNotNil(dynamic.items[0].bakedValues, "the edited scene's edits are baked")
        XCTAssertNil(dynamic.items[1].bakedValues, "the other scene is packed as it is")
    }

    // MARK: Batch: Live Photos

    @MainActor
    final class FakeLivePhotoWorker: LivePhotoBatchWorking {
        var delays: [String: UInt64] = [:]
        var fails: Set<String> = []
        var started: [String] = []
        var runningGPU = 0, maxGPU = 0, running = 0, maxRunning = 0
        let folder: URL

        init(folder: URL) { self.folder = folder }

        func export(_ item: LivePhotoBatchItem, name: String, progress: @escaping @MainActor (Double) -> Void) async throws -> LivePhotoHelper.Files {
            let title = item.wallpaper.project.title
            started.append(title)
            running += 1
            if item.usesGPU { runningGPU += 1 }
            maxGPU = max(maxGPU, runningGPU)
            maxRunning = max(maxRunning, running)
            defer {
                running -= 1
                if item.usesGPU { runningGPU -= 1 }
            }
            progress(0.5)
            try await Task.sleep(nanoseconds: delays[title] ?? 1_000_000)
            if fails.contains(title) { throw LivePhotoVideoFrames.Failure.unreadable }
            let directory = folder.appending(path: name, directoryHint: .isDirectory)
            return LivePhotoHelper.Files(directory: directory, still: directory.appending(path: "\(name).HEIC"),
                                         movie: directory.appending(path: "\(name).MOV"), identifier: title)
        }
    }

    private func liveItem(_ wallpaper: WEWallpaper) -> LivePhotoBatchItem {
        LivePhotoBatchItem(wallpaper: wallpaper, template: LivePhotoBatchTemplate(device: DeviceModel.defaultModel, quality: .high,
                                                                                    clipLength: 2, clipStart: 0, findsMotion: false))
    }

    func testLivePhotoBatchKeepsItsOrderAndRendersScenesOneAtATime() async throws {
        let worker = FakeLivePhotoWorker(folder: directory)
        worker.delays = ["A": 40_000_000, "C": 20_000_000, "B": 5_000_000, "D": 5_000_000]
        worker.fails = ["E"]
        let items = [liveItem(try scene("A")), liveItem(try wallpaper("B", type: "video", file: "b.mp4")), liveItem(try scene("C")),
                     liveItem(try wallpaper("D", type: "video", file: "d.mp4")), liveItem(try scene("E"))]
        let queue = LivePhotoBatchQueue(items: items, skipped: [.init(title: "Web", reason: "no")], worker: worker)
        await queue.run()
        XCTAssertEqual(queue.entries.map(\.status), [.done, .done, .done, .done, .failed(LivePhotoVideoFrames.Failure.unreadable.localizedDescription)])
        XCTAssertEqual(queue.exported.map(\.identifier), ["A", "B", "C", "D"], "the batch's order, whatever finished first")
        XCTAssertEqual(worker.maxGPU, 1, "scenes take the GPU one at a time")
        XCTAssertGreaterThan(worker.maxRunning, 1, "videos are read beside them")
        XCTAssertEqual(queue.progress, 1)
        XCTAssertEqual(queue.skipped.map(\.title), ["Web"])
    }

    func testCancellingTheLivePhotoBatchStopsWhatRunsAndLeavesTheRest() async throws {
        let worker = FakeLivePhotoWorker(folder: directory)
        worker.delays = ["A": 5_000_000_000, "B": 5_000_000_000, "C": 5_000_000_000, "D": 5_000_000_000]
        let items = [liveItem(try scene("A")), liveItem(try scene("B")), liveItem(try wallpaper("C", type: "video", file: "c.mp4")),
                     liveItem(try wallpaper("D", type: "video", file: "d.mp4")), liveItem(try wallpaper("E", type: "video", file: "e.mp4"))]
        let queue = LivePhotoBatchQueue(items: items, worker: worker)
        let run = Task { await queue.run() }
        try await Task.sleep(nanoseconds: 50_000_000)
        queue.cancel()
        await run.value
        XCTAssertTrue(queue.isCancelled)
        XCTAssertEqual(queue.entries.map(\.status), Array(repeating: .cancelled, count: 5))
        XCTAssertTrue(queue.exported.isEmpty)
        XCTAssertFalse(worker.started.contains("B"), "a waiting scene never starts")
        XCTAssertFalse(worker.started.contains("E"), "a waiting video never starts")
    }

    func testLivePhotoBatchAppliesTheEditsOnlyToTheEditedWallpaper() throws {
        let edited = try scene("edited")
        let other = try scene("other")
        let video = try wallpaper("clip", type: "video", file: "clip.mp4")
        let web = try wallpaper("page", type: "web", file: "index.html")
        let session = session(edited)
        session.setValues([sceneObjectVisibilityKey(objectID: 1): "false"])
        let model = LivePhotoExportModel(session: session, sceneSize: SIMD2(1600, 900), defaults: defaults)
        model.device = DeviceModel.model(id: "iPad Air 13-inch (M3)")
        model.quality = .smaller
        model.zoom = 2
        model.clipLength = 2
        model.clipStart = 4

        let plan = model.batchPlan([edited, other, video, web])
        XCTAssertEqual(plan.items.map(\.wallpaper.project.title), ["edited", "other", "clip"])
        XCTAssertEqual(plan.skipped.map(\.title), ["page"])
        XCTAssertEqual(plan.items[0].settings, model.settings, "the edited wallpaper keeps its crop, clip and parallax")
        XCTAssertEqual(plan.items[0].properties[sceneObjectVisibilityKey(objectID: 1)], "false")
        for item in plan.items.dropFirst() {
            XCTAssertNil(item.settings, "framed for its own size")
            XCTAssertEqual(item.properties, [:], "exported as authored")
            XCTAssertEqual(item.template, LivePhotoBatchTemplate(device: model.device, quality: .smaller, clipLength: 2, clipStart: 4,
                                                                 findsMotion: false))
        }
        let derived = plan.items[1].template.settings(sceneSize: SIMD2(1920, 1080))
        XCTAssertEqual(derived.crop.zoom, 1)
        XCTAssertEqual(derived.crop.center, SIMD2(960, 540))
        XCTAssertEqual(derived.crop.outputPixels, model.device.pixelSize)
        XCTAssertEqual(derived.clip, LivePhotoClip(start: 4, length: 2))
    }

    /// AirDrop All shares every finished Live Photo, in the batch's order; a failed one is left
    /// out. These fake exports have no files, so each falls back to its photo and movie.
    func testAirDropAllKeepsEachPhotoWithItsMovie() async throws {
        let worker = FakeLivePhotoWorker(folder: directory)
        worker.fails = ["B"]
        let items = [liveItem(try scene("A")), liveItem(try scene("B")), liveItem(try wallpaper("C", type: "video", file: "c.mp4")),
                     liveItem(try wallpaper("A2", type: "video", file: "a.mp4", title: "A"))]
        let queue = LivePhotoBatchQueue(items: items, worker: worker)
        await queue.run()
        XCTAssertEqual(queue.entries.map(\.name), ["A", "B", "C", "A 2"], "unique names in the batch")
        XCTAssertEqual(queue.airDropItems.map(\.lastPathComponent), ["A.HEIC", "A.MOV", "C.HEIC", "C.MOV", "A 2.HEIC", "A 2.MOV"])
        let files = try XCTUnwrap(queue.entries[2].files)
        XCTAssertEqual(LivePhotoBatchQueue.airDropItems(files), [files.still, files.movie])
        XCTAssertEqual(LivePhotoBatchQueue.uniqueNames(["A", "a"], taken: ["A"]), ["A 2", "a 3"], "names in the folder are taken")
    }

    /// AirDrop sends a Live Photo as Apple's Live Photo bundle, which iPhone imports as one Live
    /// Photo (the two files arrive as a photo and a video): a `.pvt` package in the export's folder
    /// with the photo, the movie and Photos' metadata.plist, made once.
    func testAirDropSendsALivePhotoBundle() throws {
        let folder = directory.appending(path: "export", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let files = LivePhotoHelper.Files(directory: folder, still: folder.appending(path: "Snowy Plains.HEIC"),
                                          movie: folder.appending(path: "Snowy Plains.MOV"), identifier: "id")
        try Data("photo".utf8).write(to: files.still)
        try Data("movie".utf8).write(to: files.movie)

        let items = LivePhotoBatchQueue.airDropItems(files)
        XCTAssertEqual(items.map(\.lastPathComponent), ["Snowy Plains.pvt"])
        let bundle = try XCTUnwrap(items.first)
        XCTAssertEqual(bundle.deletingLastPathComponent().standardizedFileURL, folder.standardizedFileURL, "removed with the export")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: bundle.path(percentEncoded: false)).sorted(),
                       ["Snowy Plains.HEIC", "Snowy Plains.MOV", "metadata.plist"])
        XCTAssertEqual(try Data(contentsOf: bundle.appending(path: "Snowy Plains.MOV")), Data("movie".utf8))
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: bundle.appending(path: "metadata.plist")),
                                                               format: nil) as? [String: String]
        XCTAssertEqual(plist, ["PFVideoComplementMetadataVersionKey": "1"])
        XCTAssertEqual(LivePhotoBatchQueue.airDropItems(files), items, "made once")
    }

    func testTheLibraryPickerFiltersSearchesAndOrdersTheBatch() throws {
        let edited = try scene("Zebra")
        let library = [try scene("apple"), try wallpaper("Movie", type: "video", file: "m.mp4"), try wallpaper("Page", type: "web", file: "i.html")]
        XCTAssertEqual(ExportLibraryPicker.matches(library, query: "", filter: .video).map(\.project.title), ["Movie"])
        XCTAssertEqual(ExportLibraryPicker.matches(library, query: "pa", filter: .all).map(\.project.title), ["Page"])
        let all = ExportLibraryPicker.library(library, with: edited)
        XCTAssertEqual(all.count, 4, "the edited wallpaper is offered even when the library doesn't list it")
        let picked = ExportLibraryPicker.picked(all, selection: Set(all.map(\.identityPath)), edited: edited)
        XCTAssertEqual(picked.map(\.project.title), ["Zebra", "apple", "Movie", "Page"], "the edited wallpaper first, then by title")
    }
}

/// `XCTUnwrap` for a value an `await` gives.
private func XCTUnwrapAsync<T>(_ value: @autoclosure () async throws -> T?, file: StaticString = #filePath,
                               line: UInt = #line) async throws -> T {
    let resolved = try await value()
    return try XCTUnwrap(resolved, file: file, line: line)
}
