import AVFoundation
import Foundation

enum LockScreenVideoTranscoder {
    static func export(source: URL, to output: URL, specification: LockScreenExportSpecification) async throws {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first,
              let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw LockScreenExportConfigurationFailure(message: "系统无法创建锁屏视频转码任务。")
        }
        let naturalSize = try await track.load(.naturalSize)
        let preferredTransform = try await track.load(.preferredTransform)
        let bounds = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        guard bounds.width > 0, bounds.height > 0 else {
            throw LockScreenExportConfigurationFailure(message: "视频原始画面尺寸无效。")
        }
        let transform = preferredTransform
            .concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
            .concatenating(CGAffineTransform(scaleX: Double(specification.width) / bounds.width,
                                             y: Double(specification.height) / bounds.height))
        var layer = AVVideoCompositionLayerInstruction.Configuration(assetTrack: track)
        layer.setTransform(transform, at: .zero)
        let instruction = AVVideoCompositionInstruction(configuration: .init(
            layerInstructions: [AVVideoCompositionLayerInstruction(configuration: layer)],
            timeRange: CMTimeRange(start: .zero, duration: try await asset.load(.duration))))
        // Round the duration upward, so fractional source rates are never increased.
        exporter.videoComposition = AVVideoComposition(configuration: .init(
            frameDuration: CMTime(value: Int64(ceil(600_000 / specification.framesPerSecond)), timescale: 600_000),
            instructions: [instruction], renderSize: CGSize(width: specification.width, height: specification.height),
            sourceTrackIDForFrameTiming: kCMPersistentTrackID_Invalid))
        exporter.shouldOptimizeForNetworkUse = true
        let session = LockScreenVideoExportSession(exporter)
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await session.export(to: output)
            try Task.checkCancellation()
        } onCancel: { session.cancel() }
    }
}

/// AVFoundation supports cancelExport from a concurrent cancellation handler.
/// Configuration is finished before publication; only export and cancellation
/// access the session afterward. Older SDKs do not annotate it as Sendable.
private final class LockScreenVideoExportSession: @unchecked Sendable {
    private let exporter: AVAssetExportSession
    init(_ exporter: AVAssetExportSession) { self.exporter = exporter }
    func export(to output: URL) async throws { try await exporter.export(to: output, as: .mp4) }
    func cancel() { exporter.cancelExport() }
}
