import Foundation

/// Fraction uses verified logical bytes; speed uses observed response-body bytes.
/// Compressed wire sizes and retries never become the fraction's denominator.
struct SteamContentTransferPresentation {
    private var baseline: (bytes: UInt64, time: TimeInterval)?
    private var speed: Double?
    private var lastMeasurement: TimeInterval?
    private let startedAt: TimeInterval

    init(now: TimeInterval = ProcessInfo.processInfo.systemUptime) { startedAt = now }

    mutating func state(for progress: SteamContentProgress,
                        now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> WorkshopDownloadState {
        if let baseline, progress.receivedPayloadBytes >= baseline.bytes {
            let elapsed = now - baseline.time
            if elapsed >= 0.5 {
                speed = Double(progress.receivedPayloadBytes - baseline.bytes) / elapsed
                self.baseline = (progress.receivedPayloadBytes, now)
                lastMeasurement = now
            }
        } else {
            speed = nil
            baseline = (progress.receivedPayloadBytes, now)
        }
        var parts: [String] = []
        if progress.logicalTotalBytes > 0 {
            parts.append("\(Self.bytes(progress.verifiedBytes)) / \(Self.bytes(progress.logicalTotalBytes))")
        } else {
            parts.append("正在获取文件清单")
        }
        if let speed, speed.isFinite, speed >= 0,
           let lastMeasurement, now - lastMeasurement <= 3 {
            parts.append(Self.bytes(UInt64(min(speed, Double(Int64.max / 2)))) + "/s")
        }
        let elapsed = max(0, Int(now - startedAt))
        if elapsed >= 1 { parts.append(elapsed < 60 ? "已用时 \(elapsed) 秒" : "已用时 \(elapsed / 60) 分 \(elapsed % 60) 秒") }
        return .downloading(fraction: progress.fraction, text: parts.joined(separator: " · "))
    }

    private static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(min(value, UInt64(Int64.max))), countStyle: .file)
    }
}
