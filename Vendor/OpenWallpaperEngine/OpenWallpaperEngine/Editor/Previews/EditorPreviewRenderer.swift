import CoreGraphics
import Darwin
import Foundation
import ImageIO
import Metal
import OWESceneEditing
import UniformTypeIdentifiers

/// Renders the Wallpaper Editor's previews of effects and particle systems
/// (`EditorPreviewCache`), in the app's helper run (`HelperRunCommand`,
/// `--render-editor-previews`): in its own process, never on the app's main or render thread.
///
/// Each preview's small wallpaper (`EditorPreviewFolder`) is loaded by the real loader and drawn
/// offscreen by its own real renderer, as the screen saver's loop and Live Photos are: muted, a
/// silent spectrum, on a fixed frame step from load. A built-in effect is set as WE's own preview
/// of it sets it (`EditorPreviewScene.authoredPasses`). An effect is drawn for `effectFrames`; when
/// no frame of its first two seconds differs from its first it is a still (HEIC), else a loop. A
/// particle system is always a loop, after a lead-in, both as long as its systems' cycle; a 2D
/// one is framed on where it draws.
/// A loop is HEVC, its last frames crossfaded into its first so it wraps without a jump.
@MainActor
final class EditorPreviewRenderer {
    enum Failure: LocalizedError {
        case noScene, loadTimedOut, readBack, write

        var errorDescription: String? {
            switch self {
            case .noScene: return "the preview's scene has no content or renderer"
            case .loadTimedOut: return "the preview's scene didn't finish loading"
            case .readBack: return "a frame couldn't be read back"
            case .write: return "the preview couldn't be written"
            }
        }
    }

    /// An effect's loop: 24 frames at 12 per second, its last 4 crossfaded into its first.
    static let effectFrames = 24
    static let effectFrameRate = 12
    static let effectFade = 4
    /// A particle system's loop, at 24 frames per second; its length and lead-in follow its
    /// systems (`EditorPreviewScene.particleTiming`).
    static let particleFrameRate = 24
    static let particleFade = 6
    /// Every how many frames the zoomed-out probe of a 2D particle system is read back.
    static let probeStride = 4
    /// The frames an effect is compared over to tell a still from a loop: two seconds, a whole
    /// loop.
    static let stillProbeFrames = 24
    /// The HEIC still's quality.
    static let stillQuality = 0.85

    var timeoutSeconds: TimeInterval = 60
    private let scratch: URL

    init(scratch: URL) {
        self.scratch = scratch
    }

    // MARK: Helper run

    /// The helper's work: renders each item of `job`, writing a `done` line for each; 0 when
    /// every preview was written.
    static func run(_ job: EditorPreviewJob) -> Int32 {
        run(items: AsyncStream<EditorPreviewJob.Item?> { continuation in
            for item in job.items { continuation.yield(item) }
            continuation.finish()
        })
    }

    /// The helper's work with `-`: renders each item read from `input` (`EditorPreviewJob.streamLine`)
    /// as it arrives, until `input` is closed, writing a `done` line for each (also for a line that
    /// can't be read); 0 when every preview was written. The process is in the background state
    /// (CPU, I/O and GPU at background priority) except while it renders an item a browser shows
    /// (`isUrgent`), which then renders as fast as a browser's own helper.
    static func runStream(input: FileHandle = .standardInput) -> Int32 {
        let (items, continuation) = AsyncStream<EditorPreviewJob.Item?>.makeStream()
        Thread.detachNewThread {
            var buffer = Data()
            while true {
                let data = input.availableData
                guard !data.isEmpty else { break }
                buffer.append(data)
                while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = Data(buffer[buffer.startIndex..<newline])
                    buffer.removeSubrange(buffer.startIndex...newline)
                    guard !line.isEmpty else { continue }
                    do {
                        continuation.yield(try JSONDecoder().decode(EditorPreviewJob.Item.self, from: line))
                    } catch {
                        OWELog.error(.scene, "Editor previews: unreadable item \(String(decoding: line, as: UTF8.self)): \(error)")
                        continuation.yield(nil)
                    }
                }
            }
            continuation.finish()
        }
        return run(items: items, prioritize: { isUrgent in
            if setpriority(PRIO_DARWIN_PROCESS, 0, isUrgent ? 0 : PRIO_DARWIN_BG) != 0 {
                OWELog.error(.scene, "Editor previews: can't set the helper's priority: \(String(cString: strerror(errno)))")
            }
        })
    }

    private static func run<Items: AsyncSequence & Sendable>(items: Items, prioritize: @escaping (Bool) -> Void = { _ in })
        -> Int32 where Items.Element == EditorPreviewJob.Item? {
        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "owe-editor-previews-\(ProcessInfo.processInfo.processIdentifier)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: scratch) } // Optional: a scratch folder.
        let renderer = EditorPreviewRenderer(scratch: scratch)
        let started = Date()
        var status: Int32?
        Task { @MainActor in
            var failed = 0
            var index = 0
            do {
                for try await item in items {
                    if let item {
                        prioritize(item.isUrgent ?? false)
                        do {
                            let url = try await renderer.render(item.subject, outputBase: URL(filePath: item.outputBase))
                            OWELog.debug(.scene, "Editor preview: wrote \(url.lastPathComponent)")
                        } catch {
                            failed += 1
                            OWELog.error(.scene, "Editor preview of \(item.subject) failed: \(error.localizedDescription)")
                        }
                    } else {
                        failed += 1
                    }
                    FileHandle.standardOutput.write(Data(EditorPreviewJob.doneLine(index).utf8))
                    index += 1
                }
            } catch {
                failed += 1
                OWELog.error(.scene, "Editor previews: reading the items failed: \(error)")
            }
            status = failed == 0 ? 0 : 1
            OWELog.info(.scene, "Editor previews: helper rendered \(index) previews (\(failed) failed) in "
                        + String(format: "%.1f s, CPU %.1f s", Date().timeIntervalSince(started), cpuSeconds()))
        }
        while status == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        return status ?? 1
    }

    /// This process's CPU time, user and system.
    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    // MARK: Rendering

    /// Renders the subject's preview to `outputBase` plus `.heic` or `.mov`, and returns the file.
    func render(_ subject: EditorPreviewSubject, outputBase: URL) async throws -> URL {
        let folder = scratch.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) } // Optional: a scratch folder.
        try FileManager.default.createDirectory(at: outputBase.deletingLastPathComponent(), withIntermediateDirectories: true)
        if subject.isParticle { return try await renderParticles(subject, folder: folder, to: outputBase) }
        let session = try await start(subject, framing: EditorPreviewScene.particleFraming, folder: folder)
        defer { session.end() }
        // A still unless any frame of the probe differs from the first: a small or periodic
        // motion may not show at a single instant.
        var head: [CGImage] = []
        guard let first = await session.capture() else { throw Failure.readBack }
        head.append(first)
        var moves = false
        while !moves, head.count <= Self.stillProbeFrames {
            session.advance(by: Self.effectFrameRate, capture: true)
            guard let image = await session.capture() else { throw Failure.readBack }
            head.append(image)
            moves = EditorPreviewScene.moved(image, from: first)
        }
        guard moves else { return try writeStill(first, to: outputBase) }
        return try await writeLoop(session, frames: Self.effectFrames, frameRate: Self.effectFrameRate, fade: Self.effectFade,
                                   head: head, to: outputBase)
    }

    /// A particle system's loop. Its lead-in and loop each hold a whole cycle of its systems
    /// (`EditorPreviewScene.particleTiming`), so a burst after a launch is seen. A 2D one is first
    /// run zoomed out (`probeFraming`) to find where it draws, then framed on that.
    private func renderParticles(_ subject: EditorPreviewSubject, folder: URL, to outputBase: URL) async throws -> URL {
        let probeFraming = subject.is3D ? EditorPreviewScene.particleFraming : EditorPreviewScene.probeFraming
        var session = try await start(subject, framing: probeFraming, folder: folder)
        let timing = EditorPreviewScene.particleTiming(cycle: EditorPreviewFolder.particleCycleSeconds(in: folder))
        let leadIn = Int((timing.leadIn * Double(Self.particleFrameRate)).rounded())
        let frames = Int((timing.loop * Double(Self.particleFrameRate)).rounded())
        if !subject.is3D {
            var bounds = EditorPreviewScene.ContentBounds(pixelWidth: session.pixelSize.x, pixelHeight: session.pixelSize.y)
            for index in 1...(leadIn + frames) {
                let capture = index % Self.probeStride == 0
                session.advance(by: Self.particleFrameRate, capture: capture)
                guard capture else { continue }
                guard let image = await session.capture() else {
                    session.end()
                    throw Failure.readBack
                }
                bounds.add(image)
            }
            session.end()
            let framing = bounds.rect().map { EditorPreviewScene.fittedFraming(content: $0, probe: probeFraming) }
            session = try await start(subject, framing: framing ?? EditorPreviewScene.particleFraming, folder: folder)
        }
        defer { session.end() }
        for _ in 0..<leadIn { session.advance(by: Self.particleFrameRate, capture: false) }
        return try await writeLoop(session, frames: frames, frameRate: Self.particleFrameRate,
                                   fade: Self.particleFade, head: [], to: outputBase)
    }

    /// Writes the subject's wallpaper into `folder` in `framing` and loads it.
    private func start(_ subject: EditorPreviewSubject, framing: EditorPreviewScene.Framing, folder: URL) async throws -> Session {
        let frame = try EditorPreviewFolder.write(subject, framing: framing, into: folder)
        guard let wallpaper = InstalledLibrary.wallpaper(at: folder, hiding: []) else { throw Failure.noScene }
        return try await Session.start(wallpaper, frame: frame, scratch: folder, timeout: timeoutSeconds)
    }

    /// Writes a loop of `frames` frames: `head` holds the frames already captured, from the
    /// first. The loop starts `fade` frames in and its last `fade` frames fade into those
    /// (`ScreenSaverSeamFinder.crossfadeWeight`).
    private func writeLoop(_ session: Session, frames: Int, frameRate: Int, fade: Int, head: [CGImage],
                           to outputBase: URL) async throws -> URL {
        var captured = head
        if captured.isEmpty {
            guard let first = await session.capture() else { throw Failure.readBack }
            captured.append(first)
        }
        while captured.count < frames + fade {
            session.advance(by: frameRate, capture: true)
            guard let image = await session.capture() else { throw Failure.readBack }
            captured.append(image)
        }
        let url = outputBase.appendingPathExtension(EditorPreviewCache.movieExtension)
        let partial = outputBase.deletingLastPathComponent().appending(path: ".partial-\(url.lastPathComponent)")
        try? FileManager.default.removeItem(at: partial) // Optional: a partial file of an earlier run.
        guard let writer = HEVCWriter(url: partial, pixelSize: session.pixelSize, frameRate: frameRate) else { throw Failure.write }
        for index in 0..<frames {
            let weight = ScreenSaverSeamFinder.crossfadeWeight(index: index, loopFrames: frames, fade: fade)
            let overlay = weight > 0 ? captured[index - (frames - fade)] : nil
            guard writer.append(captured[index + fade], overlay: overlay, weight: weight, frame: index) else {
                writer.cancel()
                throw Failure.write
            }
        }
        guard writer.finish() else { throw Failure.write }
        try replace(url, with: partial)
        return url
    }

    private func writeStill(_ image: CGImage, to outputBase: URL) throws -> URL {
        let url = outputBase.appendingPathExtension(EditorPreviewCache.stillExtension)
        let partial = outputBase.deletingLastPathComponent().appending(path: ".partial-\(url.lastPathComponent)")
        guard let destination = CGImageDestinationCreateWithURL(partial as CFURL, UTType.heic.identifier as CFString, 1, nil)
        else { throw Failure.write }
        let properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: Self.stillQuality]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.write }
        try replace(url, with: partial)
        return url
    }

    private func replace(_ url: URL, with partial: URL) throws {
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) { try FileManager.default.removeItem(at: url) }
        try FileManager.default.moveItem(at: partial, to: url)
    }

    // MARK: Session

    /// One loaded preview scene, held at its start until the first frame is asked for. Drawn and
    /// read back on the helper's main thread, its render thread.
    @MainActor
    final class Session {
        let renderer: SceneMetalRenderer
        let viewport: SceneViewport
        let pixelSize: SIMD2<Int>
        private let startTime: CFTimeInterval
        private var seconds: Double = 0

        private init(renderer: SceneMetalRenderer, viewport: SceneViewport, pixelSize: SIMD2<Int>, startTime: CFTimeInterval) {
            self.renderer = renderer
            self.viewport = viewport
            self.pixelSize = pixelSize
            self.startTime = startTime
        }

        static func start(_ wallpaper: WEWallpaper, frame: EditorPreviewScene.Frame, scratch: URL,
                          timeout: TimeInterval) async throws -> Session {
            let services = SceneScriptServices(prelude: SceneScriptPrelude.load(),
                                               storage: SceneScriptStorage(directory: scratch.appending(path: "storage")),
                                               media: SilentMediaSession(), spectrum: { .silent })
            let model = SceneContentLoader(wallpaper: wallpaper)
            let settings = LivePhotoRenderer.renderSettings(from: OffscreenRendering.globalSettings(from: .app))
            model.setRenderSettings(settings)
            guard let content = model.metalContent(),
                  let renderer = SceneMetalRenderer(pixelFormat: .bgra8Unorm, scriptServices: services,
                                                    screenID: "editor-preview") else { throw Failure.noScene }
            let pixelSize = SIMD2(frame.pixelWidth, frame.pixelHeight)
            let drawable = SIMD2(Float(pixelSize.x), Float(pixelSize.y))
            let startTime: CFTimeInterval = 1000
            renderer.sounds.setTargetGain(0)
            renderer.audioSpectrumFrame = { _ in .silent }
            renderer.renderSettings = settings
            renderer.wallTime = { startTime }
            renderer.holdsClock = true
            renderer.setContent(content)
            let viewport = SceneViewport(drawableSize: drawable, pointSize: drawable, cursor: nil, frameRateLimit: 30)
            let deadline = Date().addingTimeInterval(timeout)
            while !renderer.hasContent, Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            var settled = 0
            while renderer.hasContent, settled < 3, Date() < deadline {
                renderer.renderShared([viewport])
                renderer.lastCommandBuffer?.waitUntilCompleted()
                try await Task.sleep(for: .milliseconds(5))
                // Every pipeline, not only the effects': a particle pipeline still compiling draws
                // nothing, and the probe would frame the preview on what drew without it.
                settled = renderer.pipelinesCompiling ? 0 : settled + 1
            }
            guard renderer.hasContent, settled >= 3 else {
                renderer.releaseContent()
                throw Failure.loadTimedOut
            }
            renderer.holdsClock = false
            let session = Session(renderer: renderer, viewport: viewport, pixelSize: pixelSize, startTime: startTime)
            session.draw()
            return session
        }

        /// Steps the clock one frame at `frameRate` and draws; without `capture` the frame isn't
        /// read back, so it waits for the GPU here.
        func advance(by frameRate: Int, capture: Bool) {
            seconds += 1 / Double(frameRate)
            draw()
            if !capture { renderer.lastCommandBuffer?.waitUntilCompleted() }
        }

        private func draw() {
            let time = startTime + seconds
            renderer.wallTime = { time }
            renderer.renderShared([viewport])
        }

        /// The frame last drawn, read back.
        func capture() async -> CGImage? {
            let capture = FrameCapture()
            guard renderer.captureSharedFrame(pixelSize: pixelSize, pixelsPerPoint: 1, completion: { capture.finish($0) }) else {
                return nil
            }
            let finished = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: capture.done.wait(timeout: .now() + 10) == .success)
                }
            }
            return finished ? capture.image : nil
        }

        func end() { renderer.releaseContent() }
    }
}
