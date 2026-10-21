import AVFoundation
import Foundation
import CoreMedia
import ImageIO
import UniformTypeIdentifiers

/// 单个视频的真实探测结果。所有字段都来自 AVFoundation 实际读取，不做猜测。
struct VideoProbeResult: Sendable {
    var durationSeconds: Double
    var pixelWidth: Int
    var pixelHeight: Int
    var frameRate: Double?
    var videoCodec: String?
    var audioCodec: String?
    var hasAudioTrack: Bool
    var isPlayable: Bool
    /// 供 UI 展示的判定依据（例如「AVFoundation 无法解码此容器中的视频轨」）。
    var diagnostics: [String]
}

/// 用 AVAsset 实际打开文件并验证可播放性。
///
/// 不承诺「支持所有容器」：能否播放以系统解码器为准，探测失败即给出明确原因。
enum VideoProbe {
    static func probe(url: URL, includeFrameRate: Bool = true) async throws -> VideoProbeResult {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])

        var diagnostics: [String] = []

        let isPlayable: Bool
        do {
            isPlayable = try await asset.load(.isPlayable)
        } catch {
            throw AppFileError.unplayable(PathRedaction.short(url), reason: describe(error))
        }

        var duration: Double = 0
        do {
            let cmDuration = try await asset.load(.duration)
            duration = cmDuration.seconds.isFinite ? max(0, cmDuration.seconds) : 0
        } catch {
            diagnostics.append("无法读取时长：\(describe(error))")
        }

        let videoTracks: [AVAssetTrack]
        do {
            videoTracks = try await asset.loadTracks(withMediaType: .video)
        } catch {
            throw AppFileError.unplayable(PathRedaction.short(url), reason: "读取视频轨道失败：\(describe(error))")
        }

        guard let videoTrack = videoTracks.first else {
            throw AppFileError.unplayable(PathRedaction.short(url), reason: "没有视频轨道")
        }

        var width = 0
        var height = 0
        var frameRate: Double?
        do {
            let naturalSize = try await videoTrack.load(.naturalSize)
            let transform = try await videoTrack.load(.preferredTransform)
            // 旋转过的竖屏视频需要按 transform 交换宽高。
            let transformed = naturalSize.applying(transform)
            width = Int(abs(transformed.width).rounded())
            height = Int(abs(transformed.height).rounded())
            if width == 0 || height == 0 {
                width = Int(abs(naturalSize.width).rounded())
                height = Int(abs(naturalSize.height).rounded())
            }
            if includeFrameRate {
                let fps = try await videoTrack.load(.nominalFrameRate)
                if fps > 0 { frameRate = Double(fps) }
            }
        } catch {
            diagnostics.append("无法读取画面尺寸：\(describe(error))")
        }

        let formatDescriptions = (try? await videoTrack.load(.formatDescriptions)) ?? []
        let videoCodec = formatDescriptions.first.map { codecName(for: $0) }
        if videoCodec == nil {
            diagnostics.append("未能读取视频编码类型")
        }

        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        var audioCodec: String?
        if let audioTrack = audioTracks.first,
           let formats = try? await audioTrack.load(.formatDescriptions),
           let first = formats.first {
            audioCodec = codecName(for: first)
        }

        if !isPlayable {
            throw AppFileError.unplayable(
                PathRedaction.short(url),
                reason: diagnostics.first ?? "系统解码器拒绝该文件"
            )
        }
        if videoTracks.count > 1 {
            diagnostics.append("包含 \(videoTracks.count) 条视频轨，将使用第一条")
        }

        return VideoProbeResult(
            durationSeconds: duration,
            pixelWidth: width,
            pixelHeight: height,
            frameRate: frameRate,
            videoCodec: videoCodec,
            audioCodec: audioCodec,
            hasAudioTrack: !audioTracks.isEmpty,
            isPlayable: isPlayable,
            diagnostics: diagnostics
        )
    }

    /// 用 AVAssetImageGenerator 生成真实帧（导入后的缩略图与自检取证共用）。
    static func stillImage(
        url: URL,
        at seconds: Double = 1.0,
        maximumSize: CGSize = CGSize(width: 640, height: 640)
    ) async throws -> CGImage {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maximumSize
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        try Task.checkCancellation()
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        try Task.checkCancellation()
        var target = seconds
        if duration.isFinite, duration > 0, target >= duration {
            target = max(0, duration * 0.5)
        }
        let time = CMTime(seconds: target, preferredTimescale: 600)
        return try await cancellableImage(generator: generator, at: time)
    }

    /// Shared cancellation bridge for AVAssetImageGenerator callers.
    static func cancellableImage(generator: AVAssetImageGenerator,
                                 at time: CMTime) async throws -> CGImage {
        let cancellation = ImageGeneratorCancellation()
        cancellation.install(generator)
        defer { cancellation.finish() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let (image, _) = try await generator.image(at: time)
            try Task.checkCancellation()
            return image
        } onCancel: {
            cancellation.cancel()
        }
    }

    static func writeJPEG(_ image: CGImage, to url: URL, quality: Double = 0.82) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw AppFileError.copyFailed(PathRedaction.short(url), underlying: "无法创建 JPEG 输出")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw AppFileError.copyFailed(PathRedaction.short(url), underlying: "JPEG 写入失败")
        }
    }

    private static func codecName(for description: CMFormatDescription) -> String {
        let subtype = CMFormatDescriptionGetMediaSubType(description)
        let bytes: [UInt8] = [
            UInt8((subtype >> 24) & 0xFF),
            UInt8((subtype >> 16) & 0xFF),
            UInt8((subtype >> 8) & 0xFF),
            UInt8(subtype & 0xFF)
        ]
        if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) {
            let code = String(bytes: bytes, encoding: .ascii) ?? "?"
            // 常见编码给出可读名称，其余保留原始 FourCC。
            switch code {
            case "avc1", "avc3": return "H.264 (\(code))"
            case "hvc1", "hev1": return "HEVC (\(code))"
            case "av01": return "AV1 (\(code))"
            case "vp09": return "VP9 (\(code))"
            case "mp4v": return "MPEG-4 (\(code))"
            case "aac ": return "AAC"
            case "alac": return "ALAC"
            case "ac-3": return "AC-3"
            case "ec-3": return "E-AC-3"
            case "mp3 ": return "MP3"
            case "flac": return "FLAC"
            case "opus": return "Opus"
            default: return code.trimmingCharacters(in: .whitespaces)
            }
        }
        return "未知(\(subtype))"
    }

    static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == AVFoundationErrorDomain || nsError.domain == NSOSStatusErrorDomain {
            var text = nsError.localizedDescription
            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                text += "（\(underlying.localizedDescription)）"
            }
            return text
        }
        return error.localizedDescription
    }
}

/// Bridges structured task cancellation to AVAssetImageGenerator. The
/// generator API is callback based, so cancellation must call it explicitly;
/// otherwise a discarded thumbnail decode can continue for a long time.
private final class ImageGeneratorCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var generator: AVAssetImageGenerator?
    private var finished = false
    private var cancelled = false

    func install(_ generator: AVAssetImageGenerator) {
        lock.lock()
        if finished || cancelled {
            lock.unlock()
            generator.cancelAllCGImageGeneration()
            return
        }
        self.generator = generator
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        cancelled = true
        let generator = self.generator
        self.generator = nil
        lock.unlock()
        generator?.cancelAllCGImageGeneration()
    }

    func finish() {
        lock.lock()
        finished = true
        generator = nil
        lock.unlock()
    }
}
