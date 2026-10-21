#if GW_UNIVERSAL_SCENE_BACKEND
import AppKit
import AVFoundation
import CoreVideo
import Foundation

struct SceneLockScreenExportFailure: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

struct SceneLockScreenExportReport: Sendable {
    let videoURL: URL
    let renderedFrameCount: Int
    let distinctFrameCount: Int
    let visibleFrameCount: Int
    let maximumFrameDifference: Double
    let firstElapsedSeconds: Double
    let helperPID: Int32?
}

private final class SceneExportOneShot<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var pending: Result<Value, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var completed = false

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let pending { lock.unlock(); continuation.resume(with: pending); return }
        self.continuation = continuation
        lock.unlock()
    }

    func resolve(_ result: Result<Value, Error>) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        let timeoutTask = self.timeoutTask
        self.timeoutTask = nil
        if let continuation {
            self.continuation = nil; lock.unlock(); timeoutTask?.cancel(); continuation.resume(with: result)
        } else {
            pending = result; lock.unlock(); timeoutTask?.cancel()
        }
    }

    func setTimeoutTask(_ task: Task<Void, Never>) {
        lock.lock()
        if completed { lock.unlock(); task.cancel() }
        else { timeoutTask = task; lock.unlock() }
    }
}

/// Records one independent Scene render session into a finite H.264 video for
/// the existing lock-screen transaction. It never pauses, mutates or reuses the
/// desktop/preview runtime, never writes settings and never records audio.
@MainActor
final class SceneWallpaperLockScreenExporter {
    typealias Settings = RenderedLockScreenVideoCache.Settings

    private let settings: Settings
    init(settings: Settings = .init(signature: "scene-h264-v2")) { self.settings = settings }

    func export(item: WallpaperItem, storage: AppStorage, directory: URL,
                progress: @escaping @Sendable (String) async -> Void = { _ in })
        async throws -> SceneLockScreenExportReport {
        guard item.isSceneWallpaper else {
            throw SceneLockScreenExportFailure(message: "该素材不是 Scene 壁纸。")
        }
        let payload = try await SceneWallpaperLockScreenConfiguration.payload(item: item, storage: storage)
        return try await export(projectURL: item.fileURL, authorPayload: payload,
                                directory: directory, progress: progress)
    }

    func export(item: WallpaperItem, authorPayload: Data, directory: URL,
                progress: @escaping @Sendable (String) async -> Void = { _ in })
        async throws -> SceneLockScreenExportReport {
        guard item.isSceneWallpaper else {
            throw SceneLockScreenExportFailure(message: "该素材不是 Scene 壁纸。")
        }
        return try await export(projectURL: item.fileURL, authorPayload: authorPayload,
                                directory: directory, progress: progress)
    }

    func export(projectURL: URL, authorPayload: Data, directory: URL,
                progress: @escaping @Sendable (String) async -> Void = { _ in })
        async throws -> SceneLockScreenExportReport {
        guard settings.duration.isFinite, (1...30).contains(settings.duration),
              (1...240).contains(settings.framesPerSecond),
              LockScreenExportSpecification.validDimensions(width: settings.width, height: settings.height) else {
            throw SceneLockScreenExportFailure(message: "Scene 录制参数无效。")
        }
        let frameCount = Int((settings.duration * Double(settings.framesPerSecond)).rounded())
        guard frameCount > 0,
              frameCount <= settings.framesPerSecond * 30 else {
            throw SceneLockScreenExportFailure(message: "Scene 录制帧数无效。")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent("scene-lock-screen-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: output)

        await progress("正在载入 Scene 动画")
        let runtime = try SceneWallpaperRuntime(projectURL: projectURL,
            screenResolution: .init(x: Double(settings.width), y: Double(settings.height)),
            manualFrameExport: true)
        defer { runtime.dispose() }
        try runtime.setFrameRateLimit(settings.framesPerSecond)
        guard runtime.supportsManualFrameExport else {
            throw SceneLockScreenExportFailure(
                message: "当前构建没有可用的通用 Scene 渲染后端，无法录制锁屏视频。")
        }
        try await runtime.load(propertiesJSON: authorPayload)
        guard runtime.state == .ready || runtime.state == .paused else {
            throw SceneLockScreenExportFailure(message: runtime.lastError ?? "Scene 载入失败，未生成锁屏视频。")
        }
        let exportPID = runtime.backendProcessStatus?.helperPID
        // Explicit intent: the recording session never plays scene audio.
        runtime.setSceneSound(enabled: false, volume: 1)
        let clockBefore = try await runtime.currentHelperSceneSeconds()
        try Task.checkCancellation()

        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: settings.width,
            AVVideoHeightKey: settings.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: LockScreenExportSpecification.averageBitRate(
                    width: settings.width, height: settings.height, fps: Double(settings.framesPerSecond)),
                AVVideoMaxKeyFrameIntervalKey: settings.framesPerSecond * 2,
                AVVideoExpectedSourceFrameRateKey: settings.framesPerSecond,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ])
        input.mediaTimeScale = CMTimeScale(settings.framesPerSecond * 1000)
        writer.movieTimeScale = input.mediaTimeScale
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: settings.width,
                kCVPixelBufferHeightKey as String: settings.height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                kCVPixelBufferMetalCompatibilityKey as String: true
            ])
        guard writer.canAdd(input) else {
            throw SceneLockScreenExportFailure(message: "系统无法创建 Scene 视频编码器。")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw SceneLockScreenExportFailure(
                message: writer.error?.localizedDescription ?? "Scene 视频编码器启动失败。")
        }
        writer.startSession(atSourceTime: .zero)
        let pool = try makePixelBufferPool()
        do {
            await progress("正在确认 Scene 可见画面")
            let first = try await firstVisibleFrame(runtime: runtime, pool: pool)
            await progress("正在录制 Scene 锁屏视频（无音频）")
            var previous = first.signature
            var distinct = 0
            var visible = 1
            var greatestMotion = 0.0
            var lastElapsed = first.elapsed
            for index in 0..<frameCount {
                try Task.checkCancellation()
                let buffer: CVPixelBuffer
                let signature: [UInt8]
                if index == 0 {
                    buffer = first.buffer; signature = first.signature
                } else {
                    lastElapsed = first.elapsed + Double(index) / Double(settings.framesPerSecond)
                    buffer = try allocate(pool)
                    try await runtime.renderManualFrame(elapsed: lastElapsed, into: buffer)
                    signature = try Self.signature(of: buffer)
                }
                if index > 0 {
                    let difference = Self.meanDifference(previous, signature)
                    if difference >= 0.35 { distinct += 1 }
                    greatestMotion = max(greatestMotion, difference)
                    if Self.hasVisibleDetail(signature) { visible += 1 }
                }
                previous = signature
                try await append(buffer, index: index, adaptor: adaptor, input: input, writer: writer)
            }
            guard visible > 0 else {
                throw SceneLockScreenExportFailure(message: "Scene 画面为空白或全黑，未生成锁屏视频。")
            }
            // Real helper evidence that the per-frame timestamps advanced the
            // Scene clock instead of repeating a frozen/duplicated frame.
            guard let clockBefore, let clockAfter = try await runtime.currentHelperSceneSeconds() else {
                throw SceneLockScreenExportFailure(
                    message: "无法读取 Scene 渲染时钟，未生成锁屏视频。")
            }
            let advanced = lastElapsed - first.elapsed
            guard clockAfter >= clockBefore + advanced - 0.25 else {
                throw SceneLockScreenExportFailure(
                    message: "Scene 渲染时钟未按录制帧推进，未生成重复画面视频。")
            }
            writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frameCount), timescale: CMTimeScale(settings.framesPerSecond)))
            input.markAsFinished()
            try await finish(writer, timeout: 30)
            guard writer.status == .completed else {
                throw SceneLockScreenExportFailure(
                    message: writer.error?.localizedDescription ?? "Scene 视频未能完成编码。")
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
            return .init(videoURL: output, renderedFrameCount: frameCount,
                         distinctFrameCount: distinct, visibleFrameCount: visible,
                         maximumFrameDifference: greatestMotion,
                         firstElapsedSeconds: first.elapsed, helperPID: exportPID)
        } catch {
            input.markAsFinished()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    private func firstVisibleFrame(runtime: SceneWallpaperRuntime, pool: CVPixelBufferPool)
        async throws -> (buffer: CVPixelBuffer, signature: [UInt8], elapsed: Double) {
        let maximum = settings.framesPerSecond * 5
        for index in 0..<maximum {
            try Task.checkCancellation()
            let buffer = try allocate(pool)
            let elapsed = Double(index) / Double(settings.framesPerSecond)
            try await runtime.renderManualFrame(elapsed: elapsed, into: buffer)
            let signature = try Self.signature(of: buffer)
            if Self.hasVisibleDetail(signature) { return (buffer, signature, elapsed) }
        }
        throw SceneLockScreenExportFailure(message: "Scene 画面为空白或全黑，未生成锁屏视频。")
    }

    private func makePixelBufferPool() throws -> CVPixelBufferPool {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: settings.width,
            kCVPixelBufferHeightKey as String: settings.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        var optional: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &optional) == kCVReturnSuccess,
              let pool = optional else {
            throw SceneLockScreenExportFailure(message: "系统无法创建 Scene 视频画面池。")
        }
        return pool
    }

    private func allocate(_ pool: CVPixelBufferPool) throws -> CVPixelBuffer {
        var optional: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &optional) == kCVReturnSuccess,
              let buffer = optional, CVPixelBufferGetIOSurface(buffer) != nil else {
            throw SceneLockScreenExportFailure(message: "系统无法分配可直写 GPU 的 Scene 视频画面。")
        }
        return buffer
    }

    private func append(_ buffer: CVPixelBuffer, index: Int,
                        adaptor: AVAssetWriterInputPixelBufferAdaptor,
                        input: AVAssetWriterInput, writer: AVAssetWriter) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            guard writer.status == .writing else {
                throw SceneLockScreenExportFailure(
                    message: writer.error?.localizedDescription ?? "Scene 视频编码已停止。")
            }
            guard ContinuousClock.now < deadline else {
                throw SceneLockScreenExportFailure(message: "Scene 视频编码等待超时，已停止准备。")
            }
            try await Task.sleep(for: .milliseconds(4))
        }
        let time = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(settings.framesPerSecond))
        guard adaptor.append(buffer, withPresentationTime: time) else {
            throw SceneLockScreenExportFailure(
                message: writer.error?.localizedDescription ?? "写入 Scene 视频失败。")
        }
    }

    private func finish(_ writer: AVAssetWriter, timeout: TimeInterval) async throws {
        let waiter = SceneExportOneShot<Void>()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiter.install(continuation)
                writer.finishWriting { waiter.resolve(.success(())) }
                waiter.setTimeoutTask(Task { @MainActor in
                    do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                    waiter.resolve(.failure(SceneLockScreenExportFailure(
                        message: "完成 Scene 视频编码超时，已停止准备。")))
                })
            }
        } onCancel: { waiter.resolve(.failure(CancellationError())) }
    }

    /// Export-only sampling guards against publishing a black recording. Normal
    /// preview frames never call this path.
    private static func signature(of buffer: CVPixelBuffer) throws -> [UInt8] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw SceneLockScreenExportFailure(message: "无法读取 Scene 视频画面。")
        }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 0, height > 0, row >= width * 4 else {
            throw SceneLockScreenExportFailure(message: "Scene 视频画面尺寸无效。")
        }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var signature: [UInt8] = []
        signature.reserveCapacity(64 * 36)
        for y in 0..<36 {
            for x in 0..<64 {
                let offset = (y * height / 36) * row + (x * width / 64) * 4
                let b = Int(bytes[offset]), g = Int(bytes[offset + 1]), r = Int(bytes[offset + 2])
                signature.append(UInt8((r * 54 + g * 183 + b * 19) >> 8))
            }
        }
        return signature
    }

    private static func hasVisibleDetail(_ values: [UInt8]) -> Bool {
        guard let low = values.min(), let high = values.max() else { return false }
        return Int(high) - Int(low) >= 8
    }

    private static func meanDifference(_ lhs: [UInt8], _ rhs: [UInt8]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        return zip(lhs, rhs).reduce(0.0) { $0 + Double(abs(Int($1.0) - Int($1.1))) } / Double(lhs.count)
    }
}
#endif
