import AVFoundation
import CoreGraphics
import Foundation

/// The app's side of a Live Photo render: it writes the job, runs this app's executable with
/// `--render-live-photo` in this process's isolated state (`LivePhotoRenderer` renders and encodes
/// there), reads its progress from the pipe, and terminates it on cancel. The helper exits with
/// the app (`HelperRunCommand.exitWithParent`).
enum LivePhotoHelper {
    struct Files {
        let directory: URL
        let still: URL
        let movie: URL
        let identifier: String
    }

    enum Failure: LocalizedError {
        case noExecutable, failed(Int32)

        var errorDescription: String? {
            String(localized: "The Live Photo couldn't be rendered.")
        }
    }

    /// The app's cache folder for exports; each export gets its own folder in it.
    static var cacheDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appending(path: Bundle.main.bundleIdentifier ?? "OpenWallpaperEngine", directoryHint: .isDirectory)
            .appending(path: "LivePhoto", directoryHint: .isDirectory)
    }

    static func remove(_ files: Files) {
        try? FileManager.default.removeItem(at: files.directory) // Optional: a temporary folder.
    }

    /// Removes earlier exports' folders (a crash or quit left them).
    static func removeStaleExports() {
        try? FileManager.default.removeItem(at: cacheDirectory) // Optional: temporary folders.
    }

    /// Renders the Live Photo of `wallpaper` with `properties` (the isolated store's values,
    /// `IsolatedSceneEditSession.values`) as `settings` say, into a new folder under `cacheDirectory`.
    /// The files are named `name` (the wallpaper's title by default). `progress` gets 0…1 on the
    /// main actor.
    @MainActor
    static func export(_ wallpaper: WEWallpaper, properties: [String: String], settings: LivePhotoExportSettings,
                       name: String? = nil, progress: @escaping @MainActor (Double) -> Void) async throws -> Files {
        let identifier = UUID().uuidString
        let directory = cacheDirectory.appending(path: identifier, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = name ?? LivePhotoRenderer.fileName(wallpaper.project.displayTitle)
        let files = Files(directory: directory, still: directory.appending(path: base + ".HEIC"),
                          movie: directory.appending(path: base + ".MOV"), identifier: identifier)
        let job = exportJob(wallpaper, properties: properties, settings: settings, files: files)
        do {
            try await run(job, in: directory, progress: progress)
            return files
        } catch {
            remove(files)
            throw error
        }
    }

    /// The helper's job for an export: `settings` and `properties` as they are, into `files`.
    static func exportJob(_ wallpaper: WEWallpaper, properties: [String: String], settings: LivePhotoExportSettings,
                          files: Files) -> LivePhotoJob {
        LivePhotoJob(wallpaperDirectory: wallpaper.wallpaperDirectory, properties: properties, crop: settings.crop,
                     clip: settings.clip, quality: settings.quality, parallaxPosition: settings.parallaxPosition,
                     still: files.still, movie: files.movie, identifier: files.identifier)
    }

    /// The clip's frames at `settings`' crop (a small output size), for previewing the loop.
    @MainActor
    static func previewFrames(_ wallpaper: WEWallpaper, properties: [String: String], settings: LivePhotoExportSettings,
                              progress: @escaping @MainActor (Double) -> Void) async throws -> [CGImage] {
        let directory = cacheDirectory.appending(path: "preview-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) } // Optional: a temporary folder.
        let movie = directory.appending(path: "preview.MOV")
        let job = LivePhotoJob(wallpaperDirectory: wallpaper.wallpaperDirectory, properties: properties, crop: settings.crop,
                               clip: settings.clip, quality: settings.quality, parallaxPosition: settings.parallaxPosition,
                               still: nil, movie: movie, identifier: UUID().uuidString)
        try await run(job, in: directory, progress: progress)
        return try await frames(of: movie, count: settings.clip.frameCount)
    }

    /// The motion of the scene's first `LivePhotoMotion.analysisSeconds` through `settings`' crop,
    /// rendered small (`LivePhotoRenderer.analyse`).
    @MainActor
    static func analyseMotion(_ wallpaper: WEWallpaper, properties: [String: String], settings: LivePhotoExportSettings,
                              progress: @escaping @MainActor (Double) -> Void) async throws -> LivePhotoMotion.Analysis {
        let directory = cacheDirectory.appending(path: "motion-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) } // Optional: a temporary folder.
        let output = directory.appending(path: "motion.json")
        var job = LivePhotoJob(wallpaperDirectory: wallpaper.wallpaperDirectory, properties: properties, crop: settings.crop,
                               clip: settings.clip, quality: settings.quality, parallaxPosition: settings.parallaxPosition,
                               still: nil, movie: directory.appending(path: "unused.MOV"), identifier: UUID().uuidString)
        job.analysisPath = output.path(percentEncoded: false)
        job.analysisSeconds = LivePhotoMotion.analysisSeconds
        try await run(job, in: directory, progress: progress)
        return try JSONDecoder().decode(LivePhotoMotion.Analysis.self, from: Data(contentsOf: output))
    }

    /// Every frame of `movie`, in order.
    private static func frames(of movie: URL, count: Int) async throws -> [CGImage] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: movie))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        var images: [CGImage] = []
        for index in 0..<count {
            try Task.checkCancellation()
            let time = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(LivePhotoClip.frameRate))
            images.append(try await generator.image(at: time).image)
        }
        return images
    }

    /// Runs the helper on `job` and waits for it; cancelling the task terminates it.
    @MainActor
    private static func run(_ job: LivePhotoJob, in directory: URL, progress: @escaping @MainActor (Double) -> Void) async throws {
        let jobFile = directory.appending(path: "job.json")
        try JSONEncoder().encode(job).write(to: jobFile)
        defer { try? FileManager.default.removeItem(at: jobFile) } // Optional: the job is read at start.
        try await runHelper(argument: HelperRunCommand.livePhotoArgument, jobFile: jobFile, progress: progress)
    }

    /// Runs this app's executable with `argument` and `jobFile` in this process's isolated state,
    /// reporting the progress lines it writes (`LivePhotoJob.progressLine`), and waits for it;
    /// cancelling the task terminates it. A render job of another kind (the Android export's
    /// video, `AndroidVideoJob`) runs through it too.
    @MainActor
    static func runHelper(argument: String, jobFile: URL, progress: @escaping @MainActor (Double) -> Void) async throws {
        guard let process = HelperProcess.make([argument, jobFile.path(percentEncoded: false)], qos: .userInitiated) else {
            throw Failure.noExecutable
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        let lines = ProgressLines { value in
            DispatchQueue.main.async { MainActor.assumeIsolated { progress(value) } }
        }
        pipe.fileHandleForReading.readabilityHandler = { handle in lines.append(handle.availableData) }

        let status: Int32 = try await HelperProcess.run(process) { pipe.fileHandleForReading.readabilityHandler = nil }
        try Task.checkCancellation()
        guard status == 0 else {
            OWELog.error(.app, "\(argument): the render helper failed (\(status))")
            throw Failure.failed(status)
        }
    }
}

/// Splits the helper's output into lines and reports each progress line. Reading thread only.
private final class ProgressLines: @unchecked Sendable {
    private var buffer = Data()
    private let report: (Double) -> Void

    init(_ report: @escaping (Double) -> Void) { self.report = report }

    func append(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...newline)
            if let value = LivePhotoJob.progress(fromLine: Substring(line)) { report(value) }
        }
    }
}
