import Foundation

/// Counters explicitly reported by SteamCMD, never inferred from file lengths or metadata.
struct WorkshopDownloadByteCount: Sendable, Equatable {
    let received: Int64
    let total: Int64
    var fraction: Double { Double(received) / Double(total) }
    init?(received: Int64, total: Int64) {
        guard received >= 0, total > 0, received <= total else { return nil }
        self.received = received
        self.total = total
    }
    var text: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "\(formatter.string(fromByteCount: received)) / \(formatter.string(fromByteCount: total))"
    }
}

/// Monotonic measured-counter deltas; no percentage-to-bytes or elapsed-time estimates.
struct WorkshopDownloadMetrics: Sendable {
    private(set) var fraction: Double?
    private(set) var bytes: WorkshopDownloadByteCount?
    private(set) var bytesPerSecond: Double?
    private var baseline: (bytes: Int64, time: TimeInterval)?
    private var lastCounterTime: TimeInterval?
    private(set) var startedAt: TimeInterval?
    private var lastEmission: TimeInterval = -.infinity

    mutating func start(now: TimeInterval) { if startedAt == nil { startedAt = now } }

    mutating func consume(fraction: Double?, bytes: WorkshopDownloadByteCount?, now: TimeInterval) {
        guard startedAt != nil else { return }
        let validatedFraction = fraction.flatMap { value in
            value.isFinite && (0...1).contains(value) ? value : nil
        }
        if let fraction = validatedFraction {
            if fraction < (self.fraction ?? 0) { baseline = nil; bytesPerSecond = nil }
            self.fraction = fraction
        }
        if let bytes {
            if self.bytes?.total != bytes.total || bytes.received < (self.bytes?.received ?? 0) {
                baseline = nil
                bytesPerSecond = nil
            }
            if let baseline, now - baseline.time >= 0.25 {
                bytesPerSecond = Double(bytes.received - baseline.bytes) / (now - baseline.time)
                self.baseline = (bytes.received, now)
            } else if baseline == nil { baseline = (bytes.received, now) }
            self.bytes = bytes
            self.fraction = validatedFraction ?? bytes.fraction
            lastCounterTime = now
        }
    }

    mutating func presentation(now: TimeInterval, force: Bool = false) -> (Double?, String)? {
        guard let startedAt, force || now - lastEmission >= 1 else { return nil }
        lastEmission = now
        let elapsed = max(0, Int(now - startedAt))
        let elapsedText = elapsed < 60 ? "已用时 \(elapsed) 秒" : "已用时 \(elapsed / 60) 分 \(elapsed % 60) 秒"
        var parts: [String] = []
        if let bytes { parts.append(bytes.text) }
        if let bytesPerSecond, let lastCounterTime, now - lastCounterTime <= 3, bytesPerSecond.isFinite {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            parts.append(formatter.string(fromByteCount: Int64(min(bytesPerSecond, Double(Int64.max / 2)))) + "/s")
        }
        if fraction == nil { parts.append("SteamCMD 未提供具体进度") }
        parts.append(elapsedText)
        return (fraction, parts.joined(separator: " · "))
    }
}
