import AppKit
import AVFoundation
import CryptoKit
import Darwin

@MainActor private final class WebExportConfigurationState {
    var value: LockScreenExportConfiguration
    init(_ value: LockScreenExportConfiguration) { self.value = value }
}

@main @MainActor enum WebLockScreenExportTests {
    struct Failure: Error { let message: String }
    static var checks = 0
    static func check(_ value: Bool, _ name: String) throws {
        guard value else { throw Failure(message: name) }
        checks += 1; print("PASS \(name)"); fflush(stdout)
    }
    static func project(at root: URL, body: String) throws -> WallpaperItem {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"type":"web","file":"index.html","title":"Fixture","general":{"properties":{"active":{"type":"bool","value":true,"order":1}}}}"#.utf8)
            .write(to: root.appendingPathComponent("project.json"))
        try Data(body.utf8).write(to: root.appendingPathComponent("index.html"))
        return WallpaperItem(title: "Web Export Fixture", filePath: root.appendingPathComponent("project.json").path,
                             contentKind: .web)
    }
    static func imageDigest(_ image: CGImage) -> Data {
        let width = 64, height = 36
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Data(SHA256.hash(data: bytes))
    }
    static func redCentroid(_ image: CGImage) -> Double? {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var total = 0, count = 0
        for y in stride(from: 0, to: height, by: 4) {
            for x in stride(from: 0, to: width, by: 4) {
                let offset = (y * width + x) * 4
                if bytes[offset] > 200, bytes[offset + 1] < 140, bytes[offset + 2] < 110 {
                    total += x; count += 1
                }
            }
        }
        return count == 0 ? nil : Double(total) / Double(count)
    }
    static func rgba(_ image: CGImage, x: Int, yFromTop: Int) -> (UInt8, UInt8, UInt8) {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let offset = (yFromTop * image.width + x) * 4
        return (bytes[offset], bytes[offset + 1], bytes[offset + 2])
    }
    static func verifyVideo(_ url: URL, expectedDuration: Double, verifiesWallClock: Bool = false) async throws {
        let probe = try await VideoProbe.probe(url: url)
        try check(probe.isPlayable && probe.pixelWidth == 1920 && probe.pixelHeight == 1080,
                  "export is a playable 1080p video")
        try check(abs(probe.durationSeconds - expectedDuration) < 0.15,
                  "export has the requested finite loop duration")
        try check((probe.videoCodec ?? "").lowercased().contains("avc"), "export uses H.264 video")
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        let first = try await generator.image(at: CMTime(seconds: 0.2, preferredTimescale: 600)).image
        let last = try await generator.image(at: CMTime(seconds: expectedDuration - 0.2, preferredTimescale: 600)).image
        try check(imageDigest(first) != imageDigest(last), "encoded frames retain visible animation changes")
        if verifiesWallClock {
            guard let a = redCentroid(first), let b = redCentroid(last) else { throw Failure(message: "timing marker missing") }
            try check((140...280).contains(b - a),
                      "fixed-rate output follows elapsed animation time instead of adding snapshot latency")
            let top = rgba(first, x: 20, yFromTop: 20), bottom = rgba(first, x: 20, yFromTop: first.height - 20)
            try check(top.1 > 180 && top.2 < 100 && bottom.2 > 180 && bottom.1 < 100,
                      "encoded Web frame preserves top-to-bottom orientation (top \(top), bottom \(bottom))")
        }
    }
    static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GW-Web-Lock-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let animated = try project(at: root.appendingPathComponent("Animated"), body: """
        <!doctype html><meta charset="utf-8"><style>html,body,canvas{margin:0;width:100%;height:100%;background:#102030}</style>
        <canvas id="c" width="1920" height="1080"></canvas><script>
        const c=document.getElementById('c'),x=c.getContext('2d');let n=0;
        let active=false,started=performance.now();window.wallpaperPropertyListener={applyUserProperties(p){active=p.active.value}};
        function f(){x.fillStyle='#102030';x.fillRect(0,0,c.width,c.height);x.fillStyle='#00ff00';x.fillRect(0,0,c.width,80);x.fillStyle='#0000ff';x.fillRect(0,c.height-80,c.width,80);x.fillStyle='#ff6040';x.fillRect(100+(active?(performance.now()-started)*0.12:0),300,220,220);requestAnimationFrame(f)}f();
        </script>
        """)
        let propertyStorage = AppStorage(root: root.appendingPathComponent("PropertyStorage"))
        let output = try await WebWallpaperLockScreenExporter(settings: .init(duration: 2, framesPerSecond: 12))
            .export(item: animated, storage: propertyStorage, directory: root)
        try await verifyVideo(output, expectedDuration: 2, verifiesWallClock: true)
        let highFPS = try await WebWallpaperLockScreenExporter(settings: .init(duration: 1, framesPerSecond: 72,
            width: 640, height: 360)).export(item: animated, storage: propertyStorage, directory: root)
        let highFPSProbe = try await VideoProbe.probe(url: highFPS)
        try check(highFPSProbe.pixelWidth == 640 && highFPSProbe.pixelHeight == 360
            && abs((highFPSProbe.frameRate ?? 0) - 72) < 0.01,
            "real Web recording accepts configured dimensions and FPS above 60 (\(highFPSProbe.pixelWidth)x\(highFPSProbe.pixelHeight), \(highFPSProbe.frameRate ?? 0) FPS)")

        // Use the production coordinator entry point with a live preference provider.
        // The review environment keeps all preparation/cache files in this temporary root.
        let configuredStorage = AppStorage(root: root.appendingPathComponent("ConfiguredCoordinator"))
        let exportConfiguration = WebExportConfigurationState(.init(settings: .init(syncWallpaperSettings: false,
            resolution: .hd720, framesPerSecond: 12, projectPlayback: .recorded), wallpaperWidth: 1920, wallpaperHeight: 1080, wallpaperFPS: 24))
        let configuredCoordinator = ExperimentalLockScreenCoordinator(storage: configuredStorage,
            environment: .review(storage: configuredStorage), exportConfiguration: { _ in exportConfiguration.value })
        await configuredCoordinator.prepare(item: animated)
        guard let configured = configuredCoordinator.preparedAsset else {
            throw Failure(message: configuredCoordinator.lastError ?? "configured coordinator did not prepare")
        }
        let configuredProbe = try await VideoProbe.probe(url: configured.videoURL)
        try check(configuredProbe.pixelWidth == 1280 && configuredProbe.pixelHeight == 720
            && abs((configuredProbe.frameRate ?? 0) - 12) < 0.01,
            "coordinator applies saved manual resolution and frame rate to actual Web output")
        exportConfiguration.value.settings.syncWallpaperSettings = true
        exportConfiguration.value.wallpaperWidth = 640; exportConfiguration.value.wallpaperHeight = 360
        await configuredCoordinator.prepare(item: animated)
        guard let synchronized = configuredCoordinator.preparedAsset else {
            throw Failure(message: configuredCoordinator.lastError ?? "synchronized coordinator did not prepare")
        }
        let synchronizedProbe = try await VideoProbe.probe(url: synchronized.videoURL)
        try check(synchronizedProbe.pixelWidth == 640 && synchronizedProbe.pixelHeight == 360
            && abs((synchronizedProbe.frameRate ?? 0) - 24) < 0.01,
            "next export reads changed synchronization settings without restarting")
        try check(configured.videoURL == synchronized.videoURL && configured.id != synchronized.id,
                  "successful re-export atomically replaces the same prepared video path with a new revision")
        let cacheRoot = configuredStorage.root.appendingPathComponent("ExperimentalLockScreen/WebVideoCache")
            .appendingPathComponent(animated.id.uuidString)
        let entries = try FileManager.default.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.count == 64 }
        try check(entries.count == 1, "successful re-export removes the older specification's video cache")
        try check(!FileManager.default.fileExists(atPath: ExperimentalLockScreenEnvironment.review(storage: configuredStorage).storeDirectory.path),
                  "configured exports never submit system lock-screen settings")
        let authorProject = try AuthorPropertyProject.load(projectURL: animated.fileURL,
                                                            allowedRoot: animated.fileURL.deletingLastPathComponent())
        let overrideStore = AuthorPropertyOverrideStore(directory:
            propertyStorage.root.appendingPathComponent("AuthorPropertyOverrides", isDirectory: true))
        try await overrideStore.set(.bool(false), for: "active", itemID: animated.id, project: authorProject)
        do {
            _ = try await WebWallpaperLockScreenExporter(settings: .init(duration: 1, framesPerSecond: 8))
                .export(item: animated, storage: propertyStorage, directory: root)
            throw Failure(message: "saved false override was ignored")
        } catch {
            try check(error.localizedDescription.contains("未检测到网页动画"),
                      "export applies saved author-property overrides instead of project defaults")
        }
        try await overrideStore.reset(itemID: animated.id)

        let blank = try project(at: root.appendingPathComponent("Blank"), body: "<!doctype html><body style='margin:0;background:black'></body>")
        do {
            _ = try await WebWallpaperLockScreenExporter(settings: .init(duration: 1, framesPerSecond: 5))
                .export(item: blank, storage: propertyStorage, directory: root)
            throw Failure(message: "blank Web project was falsely accepted")
        } catch { try check(error.localizedDescription.contains("空白"), "blank snapshots fail closed") }

        let escaping = root.appendingPathComponent("Escaping")
        try FileManager.default.createDirectory(at: escaping, withIntermediateDirectories: false)
        try Data(#"{"type":"web","file":"outside.html"}"#.utf8).write(to: escaping.appendingPathComponent("project.json"))
        try FileManager.default.createSymbolicLink(at: escaping.appendingPathComponent("outside.html"),
                                                   withDestinationURL: animated.fileURL.deletingLastPathComponent().appendingPathComponent("index.html"))
        do {
            _ = try await WebWallpaperLockScreenExporter(settings: .init(duration: 1, framesPerSecond: 5))
                .export(item: WallpaperItem(title: "Escape", filePath: escaping.appendingPathComponent("project.json").path,
                                            contentKind: .web), storage: propertyStorage, directory: root)
            throw Failure(message: "symlink escape was accepted")
        } catch { try check(!error.localizedDescription.isEmpty, "entry symlink and path escape fail closed") }

        let existingMP4s = Set((try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))
            .filter { $0.pathExtension == "mp4" })
        let cancellation = Task { @MainActor in
            try await WebWallpaperLockScreenExporter(settings: .init(duration: 5, framesPerSecond: 12))
                .export(item: animated, storage: propertyStorage, directory: root)
        }
        try await Task.sleep(for: .milliseconds(250)); cancellation.cancel()
        do { _ = try await cancellation.value; throw Failure(message: "cancelled export completed") }
        catch is CancellationError {}
        let remainingMP4s = Set((try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))
            .filter { $0.pathExtension == "mp4" })
        try check(existingMP4s == remainingMP4s, "cancellation removes the partial Web recording")

        let failedStorage = AppStorage(root: root.appendingPathComponent("FailedCoordinator"))
        let failedCoordinator = ExperimentalLockScreenCoordinator(storage: failedStorage, environment: .review(storage: failedStorage),
            exportConfiguration: { _ in LockScreenExportSourceResolver.desktopConfiguration(settings: .init(projectPlayback: .recorded)) })
        await failedCoordinator.prepare(item: blank)
        try check(failedCoordinator.state == .failed && failedCoordinator.preparedAsset == nil,
                  "blank Web preparation cannot replace or publish a prepared asset")
        try check(!FileManager.default.fileExists(atPath: ExperimentalLockScreenEnvironment.review(storage: failedStorage).storeDirectory.path),
                  "failed Web preparation never starts a lock-screen transaction")

        let cancelledStorage = AppStorage(root: root.appendingPathComponent("CancelledCoordinator"))
        let cancelledCoordinator = ExperimentalLockScreenCoordinator(storage: cancelledStorage, environment: .review(storage: cancelledStorage),
            exportConfiguration: { _ in LockScreenExportSourceResolver.desktopConfiguration(settings: .init(projectPlayback: .recorded)) })
        let coordinatorTask = Task { @MainActor in await cancelledCoordinator.prepare(item: animated) }
        try await Task.sleep(for: .milliseconds(250)); cancelledCoordinator.cancelPreparation()
        await coordinatorTask.value
        try check(cancelledCoordinator.state == .idle && cancelledCoordinator.preparedAsset == nil,
                  "coordinator cancellation clears Web preparation without publishing an asset")
        try check(!FileManager.default.fileExists(atPath: ExperimentalLockScreenEnvironment.review(storage: cancelledStorage).storeDirectory.path),
                  "cancelled Web preparation never starts a lock-screen transaction")

        if let real = ProcessInfo.processInfo.environment["GW_WEB_LOCKSCREEN_REAL_PROJECT"], !real.isEmpty {
            let id = UUID(uuidString: ProcessInfo.processInfo.environment["GW_WEB_LOCKSCREEN_REAL_ITEM_ID"] ?? "") ?? UUID()
            let title = ProcessInfo.processInfo.environment["GW_WEB_LOCKSCREEN_REAL_TITLE"] ?? "Web Wallpaper"
            let item = WallpaperItem(id: id, title: title, filePath: real, source: .steamWorkshop, contentKind: .web)
            let actualStorage = AppStorage()
            let cacheRoot = root.appendingPathComponent("RealTargetCache")
            let firstCache = WebWallpaperLockScreenVideoCache(root: cacheRoot)
            let cachedVideo = try await firstCache.video(item: item, storage: actualStorage)
            let videoDate = try cachedVideo.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            let hitStarted = Date()
            let secondCache = WebWallpaperLockScreenVideoCache(root: cacheRoot)
            let reusedVideo = try await secondCache.video(item: item, storage: actualStorage)
            let hitSeconds = Date().timeIntervalSince(hitStarted)
            let reusedDate = try reusedVideo.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            try check(reusedVideo == cachedVideo && reusedDate == videoDate && hitSeconds < 5,
                      "real Web target reuses its validated persistent cache without recording again")
            let asset = try await ExperimentalLockScreenAssetPreparer().prepare(item: item, sourceURL: reusedVideo,
                root: root.appendingPathComponent("RealPreparedAssets"))
            try await verifyVideo(asset.videoURL, expectedDuration: 10)
            if let destination = ProcessInfo.processInfo.environment["GW_WEB_LOCKSCREEN_FRAME_OUTPUT"] {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: asset.videoURL))
                generator.appliesPreferredTrackTransform = true
                let image = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
                guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                    throw Failure(message: "could not encode evidence frame")
                }
                try png.write(to: URL(fileURLWithPath: destination), options: .atomic)
            }
            try check(asset.itemID == id && asset.title == title,
                      "real Web preparation retains originating item identity and title")
            try check(asset.videoURL != reusedVideo && FileManager.default.fileExists(atPath: reusedVideo.path),
                      "real prepared asset is independent from its reusable cache entry")
            let store = root.appendingPathComponent("RealCoordinator/LockScreenReview/Store")
            try check(!FileManager.default.fileExists(atPath: store.path),
                      "real Web preparation does not submit a lock-screen transaction")
        }
        print("RESULT \(checks) Web lock-screen export checks passed; isolated local WKWebView and temporary MP4 only, no system lock-screen transaction")
    }
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do { try await run(); fflush(stdout); Darwin.exit(0) }
            catch { fputs("FAIL \(error)\n", stderr); fflush(stderr); Darwin.exit(1) }
        }
        NSApplication.shared.run()
    }
}
