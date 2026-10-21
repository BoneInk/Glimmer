import AppKit
import AVFoundation
import Foundation

@main @MainActor
enum LockScreenExportSettingsTests {
    struct Failure: Error { let message: String }
    static var checks = 0
    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(message: message) }
        checks += 1; print("PASS \(message)"); fflush(stdout)
    }

    static func main() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("GW-Lock-Export-Settings-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = try JSONDecoder().decode(GWPreferencesSettings.self, from: Data("{}".utf8))
        try check(legacy.lockScreenExport.projectPlayback == .live && !legacy.lockScreenExport.allowWebHTTPS, "older profiles default to live rendering with network disabled")
        try check(legacy.lockScreenExport.syncWallpaperSettings, "older profiles acquire wallpaper synchronization")
        let manual = GWLockScreenExportSettings(syncWallpaperSettings: false, resolution: .qhd1440, framesPerSecond: 60, projectPlayback: .recorded, allowWebHTTPS: true)
        let coordinator = GWSettingsCoordinator(paths: .init(root: root))
        coordinator.updatePreferences { $0.lockScreenExport = manual }
        let reload = GWSettingsCoordinator(paths: .init(root: root))
        try check(reload.preferences.lockScreenExport == manual, "export configuration survives restarting settings")
        let envelope = try GWJSONFileStore.makeEncoder().encode(reload.makeExportEnvelope())
        let imported = GWSettingsCoordinator(paths: .init(root: root.appendingPathComponent("Imported")))
        _ = try imported.commitImport(imported.validateImport(data: envelope))
        try check(imported.preferences.lockScreenExport == manual, "configuration import/export includes lock-screen preferences")
        imported.updatePreferences { $0.lockScreenExport.syncWallpaperSettings = true }
        imported.updatePreferences { $0.lockScreenExport.syncWallpaperSettings = false }
        try check(imported.preferences.lockScreenExport == manual, "synchronization preserves manual choices")
        imported.resetPreferences()
        try check(imported.preferences.lockScreenExport == .init(), "reset restores export defaults")
        let invalid = try JSONDecoder().decode(GWLockScreenExportSettings.self,
            from: Data(#"{"resolution":"future","framesPerSecond":999}"#.utf8))
        try check(invalid.resolution == .fullHD1080 && invalid.framesPerSecond == 240, "invalid saved choices normalize safely")

        let fullHD = LockScreenExportSpecification(width: 1920, height: 1080, framesPerSecond: 24)
        let tooHigh = LockScreenExportConfiguration(settings: .init(syncWallpaperSettings: false,
            resolution: .uhd2160, framesPerSecond: 120))
        try check(try tooHigh.resolve(source: fullHD) == fullHD, "4K/120 selection cannot upscale a 1080p/24 source")
        let fractional = LockScreenExportSpecification(width: 2560, height: 1440, framesPerSecond: 24_000 / 1001)
        let low = LockScreenExportConfiguration(settings: .init(syncWallpaperSettings: false,
            resolution: .hd720, framesPerSecond: 60))
        let fractionalOutput = try low.resolve(source: fractional)
        try check(fractionalOutput.width == 1280 && fractionalOutput.height == 720
            && fractionalOutput.framesPerSecond == fractional.framesPerSecond, "fractional source FPS is preserved without rounding up")
        let portrait = try low.resolve(source: .init(width: 1080, height: 1920, framesPerSecond: 30))
        try check(portrait.width == 720 && portrait.height == 1280, "portrait export preserves orientation and aspect ratio")
        let wide = try low.resolve(source: .init(width: 3440, height: 1440, framesPerSecond: 30))
        try check(wide.width <= 1280 && wide.height < 720 && wide.width % 2 == 0 && wide.height % 2 == 0,
                  "ultrawide export fits the selected bounds with even dimensions")
        let sync = LockScreenExportConfiguration(settings: .init(), wallpaperWidth: 2560, wallpaperHeight: 1440, wallpaperFPS: 25)
        let synchronized = try sync.resolve(source: .init(width: 3840, height: 2160, framesPerSecond: 60))
        try check(synchronized == .init(width: 2560, height: 1440, framesPerSecond: 25), "synchronization uses current desktop dimensions and FPS")
        try check(try sync.resolve(source: fullHD) == fullHD, "synchronization is also bounded by the source")
        let huge = try LockScreenExportConfiguration(settings: .original).resolve(
            source: .init(width: 16_384, height: 8192, framesPerSecond: 120))
        try check(huge.width * huge.height <= 16_777_216 && huge.width <= 8192, "original resolution respects the renderer pixel budget")

        let webRoot = root.appendingPathComponent("Web")
        try FileManager.default.createDirectory(at: webRoot, withIntermediateDirectories: true)
        let projectURL = webRoot.appendingPathComponent("project.json")
        try Data(#"{"type":"web","file":"index.html","general":{"orthogonalprojection":{"width":576,"height":324}}}"#.utf8).write(to: projectURL)
        try Data("<canvas></canvas>".utf8).write(to: webRoot.appendingPathComponent("index.html"))
        let web = WallpaperItem(title: "Web", filePath: projectURL.path, contentKind: .web)
        let webContext = LockScreenExportConfiguration(settings: tooHigh.settings, wallpaperWidth: 3840, wallpaperHeight: 2160, wallpaperFPS: 30)
        let webSource = try LockScreenExportSourceResolver.renderedSource(item: web, configuration: webContext)
        try check(try webContext.resolve(source: webSource) == .init(width: 576, height: 324, framesPerSecond: 30),
                  "declared Web canvas and current runtime FPS cap bound export")

        let source = root.appendingPathComponent("source.mp4")
        try await SyntheticVideoWriter.write(to: source, options: .init(width: 1920, height: 1080, frameRate: 24, frameCount: 24))
        let item = WallpaperItem(title: "Actual video", filePath: source.path)
        let preparer = ExperimentalLockScreenAssetPreparer()
        let copied = try await preparer.prepare(item: item, root: root.appendingPathComponent("Copy"), configuration: tooHigh)
        let sourceData = try Data(contentsOf: source)
        try check(try Data(contentsOf: copied.videoURL) == sourceData, "compatible source below selected limits is copied byte for byte")
        let reduced = try await preparer.prepare(item: item, root: root.appendingPathComponent("Reduced"),
            configuration: .init(settings: .init(syncWallpaperSettings: false, resolution: .hd720, framesPerSecond: 12)))
        let reducedProbe = try await VideoProbe.probe(url: reduced.videoURL)
        try check(reducedProbe.pixelWidth == 1280 && reducedProbe.pixelHeight == 720
            && abs((reducedProbe.frameRate ?? 0) - 12) < 0.01, "real transcode produces 1280x720 at 12 FPS")
        let replaced = try await preparer.prepare(item: item, root: root.appendingPathComponent("Reduced"), configuration: tooHigh)
        try check(replaced.videoURL == reduced.videoURL && replaced.posterURL == reduced.posterURL && replaced.id != reduced.id,
                  "changed export configuration replaces the same video and poster with a new revision")
        try check(try Data(contentsOf: replaced.videoURL) == sourceData, "replacement publishes the new validated video")
        do {
            _ = try await preparer.prepare(item: item, sourceURL: root.appendingPathComponent("missing.mp4"),
                root: root.appendingPathComponent("Reduced"), configuration: tooHigh)
            throw Failure(message: "missing source unexpectedly exported")
        } catch is Failure { throw Failure(message: "missing source unexpectedly exported") }
        catch { }
        try check(try Data(contentsOf: replaced.videoURL) == sourceData, "failed replacement preserves the previous video")
        let syncVideo = try await preparer.prepare(item: item, root: root.appendingPathComponent("Synced"),
            configuration: .init(settings: .init(), wallpaperWidth: 960, wallpaperHeight: 540))
        let syncProbe = try await VideoProbe.probe(url: syncVideo.videoURL)
        try check(syncProbe.pixelWidth == 960 && syncProbe.pixelHeight == 540
            && abs((syncProbe.frameRate ?? 0) - 24) < 0.01, "video synchronization resizes to desktop but retains native timing")
        let rotatedSource = root.appendingPathComponent("rotated.mov")
        let originalAsset = AVURLAsset(url: source)
        let rotatedAsset = AVMutableComposition()
        let originalTrack = try await originalAsset.loadTracks(withMediaType: .video).first!
        let rotatedTrack = rotatedAsset.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        try rotatedTrack.insertTimeRange(CMTimeRange(start: .zero, duration: try await originalAsset.load(.duration)),
                                        of: originalTrack, at: .zero)
        rotatedTrack.preferredTransform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)
        let rotationExporter = AVAssetExportSession(asset: rotatedAsset, presetName: AVAssetExportPresetPassthrough)!
        try await rotationExporter.export(to: rotatedSource, as: .mov)
        let rotated = try await preparer.prepare(item: WallpaperItem(title: "Rotated", filePath: rotatedSource.path),
            root: root.appendingPathComponent("Rotated"), configuration: .init(settings:
                .init(syncWallpaperSettings: false, resolution: .hd720, framesPerSecond: 12)))
        let portraitProbe = try await VideoProbe.probe(url: rotated.videoURL)
        try check(portraitProbe.pixelWidth == 720 && portraitProbe.pixelHeight == 1280
            && abs((portraitProbe.frameRate ?? 0) - 12) < 0.01, "real transcode respects a rotated track's portrait dimensions")
        let fourK = root.appendingPathComponent("four-k.mov")
        try await SyntheticVideoWriter.write(to: fourK, options: .init(width: 3840, height: 2160, frameRate: 12, frameCount: 12))
        let converted = try await preparer.prepare(item: WallpaperItem(title: "4K container", filePath: fourK.path),
            root: root.appendingPathComponent("Native"), configuration: .init(settings: .original))
        let nativeProbe = try await VideoProbe.probe(url: converted.videoURL)
        try check(nativeProbe.pixelWidth == 3840 && nativeProbe.pixelHeight == 2160
            && abs((nativeProbe.frameRate ?? 0) - 12) < 0.01, "container conversion preserves actual 4K source resolution")
        try check(try Data(contentsOf: source) == sourceData, "export leaves the original video untouched")
        print("RESULT \(checks) export settings and real-video checks passed; temporary files only")
    }
}
