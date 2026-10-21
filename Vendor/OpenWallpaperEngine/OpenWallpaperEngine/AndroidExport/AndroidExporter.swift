import Foundation

/// Does one item of an Android export (`AndroidExportQueue`): a protocol so the queue's tests use
/// a fake.
@MainActor
protocol AndroidExportWorking: AnyObject {
    /// Writes `item`'s package to `url`, reporting 0…1; throws `CancellationError` when cancelled.
    func export(_ item: AndroidExportItem, to url: URL, progress: @escaping @MainActor (Double) -> Void) async throws
}

/// The app's exporter: packages videos and Dynamic scenes off the main thread, and renders a
/// pre-rendered scene's video in the helper (`AndroidVideoRenderer`, `--render-android-video`)
/// before packaging it.
@MainActor
final class AndroidExporter: AndroidExportWorking {
    /// The cache folder for the pre-rendered videos while they are packaged.
    static var cacheDirectory: URL {
        AppStorageLocation.current.cachesDirectory.appending(path: "AndroidExport", directoryHint: .isDirectory)
    }

    func export(_ item: AndroidExportItem, to url: URL, progress: @escaping @MainActor (Double) -> Void) async throws {
        let wallpaper = item.wallpaper
        let name = wallpaper.wallpaperDirectory.lastPathComponent
        OWELog.info(.app, "Android export: \(name) (\(item.usesGPU ? "pre-rendered" : item.kind == .video ? "video" : "dynamic")) → \(url.lastPathComponent)")
        switch item.kind {
        case .video:
            try await Self.package(to: url, progress: progress) { _ in try AndroidPackageBuilder.videoEntries(wallpaper) }
        case .scene where !item.usesGPU:
            let options = item.options
            let baked = item.bakedValues
            try await Self.package(to: url, progress: progress) { report in
                try AndroidPackageBuilder.dynamicEntries(wallpaper, options: options, baking: baked, progress: { report($0 * 0.85) })
            }
        case .scene:
            let options = item.options
            let directory = Self.cacheDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) } // Optional: a temporary folder.
            let video = directory.appending(path: AndroidPackageBuilder.videoFileName)
            let framing: AndroidVideoFraming
            if let given = item.framing {
                framing = given
            } else {
                let sceneSize = try await Task.detached(priority: .userInitiated) { try AndroidPackageBuilder.sceneSize(wallpaper) }.value
                framing = item.framing(sceneSize: sceneSize)
            }
            let job = Self.videoJob(item, framing: framing, output: video)
            let jobFile = directory.appending(path: "job.json")
            try JSONEncoder().encode(job).write(to: jobFile)
            try await LivePhotoHelper.runHelper(argument: HelperRunCommand.androidVideoArgument, jobFile: jobFile) { progress($0 * 0.9) }
            try await Self.package(to: url, progress: { progress(0.9 + $0 * 0.1) }) { _ in
                try AndroidPackageBuilder.preRenderedEntries(wallpaper, video: video, options: options)
            }
        case nil:
            throw AndroidPackageBuilder.Failure.unsupported
        }
        OWELog.info(.app, "Android export: wrote \(url.lastPathComponent)")
    }

    /// The helper's job for `item`'s pre-render framed by `framing`.
    static func videoJob(_ item: AndroidExportItem, framing: AndroidVideoFraming, output: URL) -> AndroidVideoJob {
        AndroidVideoJob(wallpaperDirectory: item.wallpaper.wallpaperDirectory, properties: item.properties, crop: framing.crop,
                        frameRate: item.options.frameRate, seconds: framing.seconds,
                        bitRate: item.options.videoBitRate(pixelSize: framing.crop.outputPixels), output: output,
                        pointer: framing.pointer)
    }

    /// Builds the entries and writes the package off the main thread; cancelling stops it.
    private static func package(to url: URL, progress: @escaping @MainActor (Double) -> Void,
                                entries: @escaping @Sendable (@escaping (Double) -> Void) throws -> [MobilePackageWriter.Entry]) async throws {
        let report: @Sendable (Double) -> Void = { value in Task { @MainActor in progress(value) } }
        let work = Task.detached(priority: .userInitiated) {
            let built = try entries(report)
            try MobilePackageWriter.write(built, to: url) { report(0.85 + $0 * 0.15) }
        }
        try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
        progress(1)
    }
}
