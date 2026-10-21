import AppKit
import AVFoundation
import CoreVideo
import WebKit

struct WebWallpaperLockScreenExportFailure: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

private final class WebExportOneShot<Value: Sendable>: @unchecked Sendable {
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
        if let continuation { self.continuation = nil; lock.unlock(); timeoutTask?.cancel(); continuation.resume(with: result) }
        else { pending = result; lock.unlock(); timeoutTask?.cancel() }
    }

    func setTimeoutTask(_ task: Task<Void, Never>) {
        lock.lock()
        if completed { lock.unlock(); task.cancel() }
        else { timeoutTask = task; lock.unlock() }
    }
}

/// Records a local, sandboxed Web wallpaper into a finite video for the existing
/// lock-screen transaction. It never loads a file URL or grants network access.
@MainActor
final class WebWallpaperLockScreenExporter {
    struct Settings: Codable, Hashable, Sendable {
        var duration: TimeInterval = 10
        var framesPerSecond = 30
        var width = 1920
        var height = 1080
        var cacheSignature: String { "web-h264-v2:\(duration):\(framesPerSecond):\(width)x\(height)" }
    }

    private let settings: Settings
    init(settings: Settings = Settings()) { self.settings = settings }

    func export(item: WallpaperItem, storage: AppStorage, directory: URL,
                progress: @escaping @Sendable (String) async -> Void = { _ in }) async throws -> URL {
        guard item.isWebWallpaper else {
            throw WebWallpaperLockScreenExportFailure(message: "该素材不是 Web 壁纸。")
        }
        guard settings.duration.isFinite, (1...30).contains(settings.duration),
              (1...240).contains(settings.framesPerSecond),
              LockScreenExportSpecification.validDimensions(width: settings.width, height: settings.height) else {
            throw WebWallpaperLockScreenExportFailure(message: "网页动画录制参数无效。")
        }
        try Task.checkCancellation()
        let authorPayload = try await WebWallpaperLockScreenConfiguration.payload(item: item, storage: storage)
        return try await export(item: item, authorPayload: authorPayload, directory: directory, progress: progress)
    }

    func export(item: WallpaperItem, authorPayload: Data, directory: URL,
                progress: @escaping @Sendable (String) async -> Void = { _ in }) async throws -> URL {
        guard item.isWebWallpaper else { throw WebWallpaperLockScreenExportFailure(message: "该素材不是 Web 壁纸。") }
        guard settings.duration.isFinite, (1...30).contains(settings.duration),
              (1...240).contains(settings.framesPerSecond),
              LockScreenExportSpecification.validDimensions(width: settings.width, height: settings.height) else {
            throw WebWallpaperLockScreenExportFailure(message: "网页动画录制参数无效。")
        }
        let project = try WebWallpaperProjectDescriptor(projectURL: item.fileURL)
        try Task.checkCancellation()
        let runtime = try WebWallpaperRuntime(projectURL: project.projectURL,
                                              entryURL: project.entryURL,
                                              propertiesJSON: Data("{}".utf8), manualFrameExport: true)
        try runtime.applyPropertiesJSON(authorPayload)
        try runtime.setFrameRateLimit(settings.framesPerSecond)
        defer { runtime.dispose() }
        let frame = CGRect(x: 0, y: 0, width: settings.width, height: settings.height)
        runtime.webView.frame = frame
        runtime.webView.setValue(false, forKey: "drawsBackground")
        // An owned host supplies stable layout without activating a window.
        // The export runtime advances RAF explicitly when WebKit hides the page.
        let host = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        host.ignoresMouseEvents = true
        host.setFrameOrigin(.zero)
        host.alphaValue = 0.01
        host.contentView = runtime.webView
        host.orderFrontRegardless()
        defer { host.orderOut(nil); host.contentView = nil }
        runtime.load()
        await progress("正在载入网页动画")
        try await waitUntilReady(runtime)
        try Task.checkCancellation()
        await progress("正在确认网页动画画面")
        let firstFrame = try await waitForVisibleFrame(runtime.webView, rect: frame)

        let output = directory.appendingPathComponent("web-lock-screen-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: output)
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
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ])
        guard writer.canAdd(input) else {
            throw WebWallpaperLockScreenExportFailure(message: "系统无法创建网页动画视频编码器。")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw WebWallpaperLockScreenExportFailure(message: writer.error?.localizedDescription ?? "网页动画视频编码器启动失败。")
        }
        writer.startSession(atSourceTime: .zero)
        let firstSignature: [UInt8]? = firstFrame.1
        var greatestMotion = 0.0
        let frameCount = Int((settings.duration * Double(settings.framesPerSecond)).rounded())
        do {
            await progress("正在将网页动画转为循环视频")
            let clock = ContinuousClock(), start = clock.now
            var nextIndex = 0
            var previous = firstFrame
            while nextIndex < frameCount {
                try Task.checkCancellation()
                if nextIndex > 0 {
                    let target = start + .milliseconds(Int64(nextIndex * 1_000 / settings.framesPerSecond))
                    if clock.now < target { try await clock.sleep(until: target) }
                }
                if nextIndex > 0 { try await advanceFrame(runtime.webView) }
                let captured = nextIndex == 0 ? firstFrame
                    : try makePixelBuffer(await snapshot(runtime.webView, rect: frame, timeout: 5))
                if let firstSignature {
                    greatestMotion = max(greatestMotion, Self.meanDifference(firstSignature, captured.1))
                }
                let elapsed = Self.seconds(start.duration(to: clock.now))
                let reachedIndex = min(frameCount - 1,
                    max(nextIndex, Int(floor(elapsed * Double(settings.framesPerSecond)))))
                while nextIndex < reachedIndex {
                    try await append(previous.0, index: nextIndex, adaptor: adaptor, input: input, writer: writer)
                    nextIndex += 1
                }
                try await append(captured.0, index: nextIndex, adaptor: adaptor, input: input, writer: writer)
                previous = captured
                nextIndex += 1
            }
            guard greatestMotion >= 0.35 else {
                throw WebWallpaperLockScreenExportFailure(message: "未检测到网页动画，无法生成动态锁屏。")
            }
            writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frameCount), timescale: CMTimeScale(settings.framesPerSecond)))
            input.markAsFinished()
            try await finish(writer, timeout: 10)
            guard writer.status == .completed else {
                throw WebWallpaperLockScreenExportFailure(message: writer.error?.localizedDescription ?? "网页动画视频未能完成编码。")
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
            return output
        } catch {
            input.markAsFinished()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    private func waitUntilReady(_ runtime: WebWallpaperRuntime) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while runtime.state != .ready && runtime.state != .paused {
            try Task.checkCancellation()
            if runtime.state == .failed || runtime.state == .disposed {
                throw WebWallpaperLockScreenExportFailure(message: runtime.lastError ?? "网页动画载入失败。")
            }
            guard ContinuousClock.now < deadline else {
                throw WebWallpaperLockScreenExportFailure(message: "网页动画载入超时，未生成锁屏视频。")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func advanceFrame(_ webView: WKWebView) async throws {
        let waiter = WebExportOneShot<Void>()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiter.install(continuation)
                webView.callAsyncJavaScript("window.__gwLockScreenCaptureFrame(); return true;",
                    arguments: [:], in: nil, in: .page) { result in
                        switch result {
                        case .success: waiter.resolve(.success(()))
                        case .failure(let error): waiter.resolve(.failure(error))
                        }
                    }
                waiter.setTimeoutTask(Task { @MainActor in
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    waiter.resolve(.failure(WebWallpaperLockScreenExportFailure(message: "网页动画帧推进超时，已停止准备。")))
                })
            }
        } onCancel: { waiter.resolve(.failure(CancellationError())) }
    }

    private func snapshot(_ webView: WKWebView, rect: CGRect, timeout: TimeInterval) async throws -> NSImage {
        let configuration = WKSnapshotConfiguration()
        configuration.rect = rect
        configuration.snapshotWidth = NSNumber(value: Double(settings.width))
        let waiter = WebExportOneShot<NSImage>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiter.install(continuation)
                webView.takeSnapshot(with: configuration) { image, error in
                    if let image { waiter.resolve(.success(image)) }
                    else { waiter.resolve(.failure(error ?? WebWallpaperLockScreenExportFailure(message: "网页动画截图失败。"))) }
                }
                waiter.setTimeoutTask(Task { @MainActor in
                    do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                    waiter.resolve(.failure(WebWallpaperLockScreenExportFailure(message: "网页动画截图超时，已停止准备。")))
                })
            }
        } onCancel: { waiter.resolve(.failure(CancellationError())) }
    }

    private func waitForVisibleFrame(_ webView: WKWebView, rect: CGRect) async throws -> (CVPixelBuffer, [UInt8]) {
        for _ in 0..<50 {
            try Task.checkCancellation()
            try await advanceFrame(webView)
            let captured = try makePixelBuffer(await snapshot(webView, rect: rect, timeout: 5))
            if Self.hasVisibleDetail(captured.1) { return captured }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw WebWallpaperLockScreenExportFailure(message: "网页动画画面为空白或无可见内容，未生成锁屏视频。")
    }

    private func append(_ buffer: CVPixelBuffer, index: Int,
                        adaptor: AVAssetWriterInputPixelBufferAdaptor,
                        input: AVAssetWriterInput, writer: AVAssetWriter) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            guard writer.status == .writing else {
                throw WebWallpaperLockScreenExportFailure(message: writer.error?.localizedDescription ?? "网页动画视频编码已停止。")
            }
            guard ContinuousClock.now < deadline else {
                throw WebWallpaperLockScreenExportFailure(message: "网页动画视频编码等待超时，已停止准备。")
            }
            try await Task.sleep(for: .milliseconds(4))
        }
        let time = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(settings.framesPerSecond))
        guard adaptor.append(buffer, withPresentationTime: time) else {
            throw WebWallpaperLockScreenExportFailure(message: writer.error?.localizedDescription ?? "写入网页动画视频失败。")
        }
    }

    private func finish(_ writer: AVAssetWriter, timeout: TimeInterval) async throws {
        let waiter = WebExportOneShot<Void>()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiter.install(continuation)
                writer.finishWriting { waiter.resolve(.success(())) }
                waiter.setTimeoutTask(Task { @MainActor in
                    do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                    waiter.resolve(.failure(WebWallpaperLockScreenExportFailure(message: "完成网页动画视频编码超时，已停止准备。")))
                })
            }
        } onCancel: { waiter.resolve(.failure(CancellationError())) }
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1_000_000_000_000_000_000
    }

    private func makePixelBuffer(_ image: NSImage) throws -> (CVPixelBuffer, [UInt8]) {
        guard let poolImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw WebWallpaperLockScreenExportFailure(message: "无法读取网页动画画面。")
        }
        var optional: CVPixelBuffer?
        let result = CVPixelBufferCreate(kCFAllocatorDefault, settings.width, settings.height,
            kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &optional)
        guard result == kCVReturnSuccess, let buffer = optional else {
            throw WebWallpaperLockScreenExportFailure(message: "无法分配网页动画视频画面。")
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let context = CGContext(data: base, width: settings.width, height: settings.height,
                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else {
            throw WebWallpaperLockScreenExportFailure(message: "无法生成网页动画视频画面。")
        }
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: settings.width, height: settings.height))
        context.draw(poolImage, in: CGRect(x: 0, y: 0, width: settings.width, height: settings.height))
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        var signature: [UInt8] = []
        signature.reserveCapacity(64 * 36)
        for y in 0..<36 {
            for x in 0..<64 {
                let offset = (y * settings.height / 36) * row + (x * settings.width / 64) * 4
                let b = Int(bytes[offset]), g = Int(bytes[offset + 1]), r = Int(bytes[offset + 2])
                signature.append(UInt8((r * 54 + g * 183 + b * 19) >> 8))
            }
        }
        return (buffer, signature)
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
