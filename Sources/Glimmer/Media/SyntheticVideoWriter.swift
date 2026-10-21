import AVFoundation
import Foundation

/// 生成小型测试视频（不依赖任何外部素材）。
///
/// 设计约束（对应 R09）：
/// - **视频轨 only**：自检只需要验证解码与播放，真实 H.264/AAC 文件已在图形界面中验证过，
///   因此这里不再写音频轨，避免音视频交织等待导致的无限阻塞。
/// - **每个等待都有截止时间**：`isReadyForMoreMediaData`、`finishWriting` 等都可能长时间
///   不返回；任何一步超过截止时间都会取消写入并抛错，绝不留下「零字节文件 + 挂起进程」。
/// - 失败时清理半成品文件，避免污染测试目录。
struct SyntheticVideoWriter {
    struct Options: Sendable {
        var width: Int = 320
        var height: Int = 180
        var frameRate: Int = 20
        var frameCount: Int = 40

        static let `default` = Options()

        var durationSeconds: Double { Double(frameCount) / Double(frameRate) }
    }

    enum WriteError: LocalizedError {
        case timeout(String)
        case writerFailed(String)

        var errorDescription: String? {
            switch self {
            case .timeout(let stage): return "生成测试视频超时（\(stage)）"
            case .writerFailed(let detail): return "生成测试视频失败：\(detail)"
            }
        }
    }

    /// 生成视频。`deadlineSeconds` 是整体预算，超时即失败（不会无限等待）。
    static func write(to url: URL, options: Options = .default, deadlineSeconds: Double = 20) async throws {
        try? FileManager.default.removeItem(at: url)
        let deadline = Date().addingTimeInterval(deadlineSeconds)
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        } catch {
            throw WriteError.writerFailed(error.localizedDescription)
        }

        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: options.width,
                AVVideoHeightKey: options.height
            ]
        )
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: options.width,
                kCVPixelBufferHeightKey as String: options.height
            ]
        )
        guard writer.canAdd(videoInput) else {
            throw WriteError.writerFailed("视频轨无法加入写入器")
        }
        writer.add(videoInput)

        guard writer.startWriting() else {
            throw WriteError.writerFailed(writer.error?.localizedDescription ?? "startWriting 返回 false")
        }
        writer.startSession(atSourceTime: .zero)

        do {
            for frame in 0..<options.frameCount {
                try await waitUntilReady(videoInput, writer: writer, deadline: deadline, stage: "第 \(frame) 帧")
                guard let pool = adaptor.pixelBufferPool else {
                    throw WriteError.writerFailed("像素缓冲池不可用")
                }
                var pixelBufferOut: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBufferOut)
                guard let pixelBuffer = pixelBufferOut else {
                    throw WriteError.writerFailed("像素缓冲创建失败")
                }
                try draw(frame: frame, of: options.frameCount, into: pixelBuffer, options: options)

                let frameValue = CMTimeValue(frame * 600 / max(1, options.frameRate))
                let time = CMTime(value: frameValue, timescale: 600)
                guard adaptor.append(pixelBuffer, withPresentationTime: time) else {
                    throw WriteError.writerFailed(writer.error?.localizedDescription ?? "帧写入失败")
                }
            }
            videoInput.markAsFinished()
            try await finishWriting(writer, deadline: deadline)
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    // MARK: - 有截止时间的等待

    /// 等待写入器就绪：检查取消、失败状态与截止时间，绝不无限等待。
    private static func waitUntilReady(
        _ input: AVAssetWriterInput,
        writer: AVAssetWriter,
        deadline: Date,
        stage: String
    ) async throws {
        while !input.isReadyForMoreMediaData {
            if Task.isCancelled {
                throw CancellationError()
            }
            if writer.status == .failed {
                throw WriteError.writerFailed(writer.error?.localizedDescription ?? "写入器失败")
            }
            if writer.status != .writing {
                throw WriteError.writerFailed("写入器状态异常（\(writer.status.rawValue)）")
            }
            if Date() >= deadline {
                throw WriteError.timeout(stage)
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// 完成写入：轮询状态并受截止时间约束，超时取消写入。
    private static func finishWriting(_ writer: AVAssetWriter, deadline: Date) async throws {
        writer.finishWriting { }
        while writer.status == .writing {
            if Date() >= deadline {
                throw WriteError.timeout("等待写入完成")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard writer.status == .completed else {
            throw WriteError.writerFailed(writer.error?.localizedDescription ?? "写入未完成（status=\(writer.status.rawValue)）")
        }
    }

    /// 在像素缓冲里画一帧：背景颜色随时间渐变，另有一个随时间移动的方块与进度条，
    /// 因此「两帧是否不同」可以直接反映播放是否在推进。
    private static func draw(frame: Int, of total: Int, into pixelBuffer: CVPixelBuffer, options: Options) throws {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw WriteError.writerFailed("像素缓冲地址不可用")
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(
            data: base,
            width: options.width,
            height: options.height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else {
            throw WriteError.writerFailed("绘制上下文创建失败")
        }

        let progress = Double(frame) / Double(max(1, total - 1))
        let width = CGFloat(options.width)
        let height = CGFloat(options.height)

        context.setFillColor(CGColor(red: 0.05 + 0.55 * progress, green: 0.12, blue: 0.65 - 0.5 * progress, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.92))
        let squareSize = height * 0.22
        context.fill(CGRect(
            x: width * CGFloat(progress) - squareSize / 2,
            y: height / 2 - squareSize / 2,
            width: squareSize,
            height: squareSize
        ))

        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.35))
        context.fill(CGRect(x: 0, y: 0, width: width * CGFloat(progress), height: 12))
    }
}
