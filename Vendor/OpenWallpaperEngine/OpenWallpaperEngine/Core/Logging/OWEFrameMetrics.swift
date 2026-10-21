import Foundation
import QuartzCore
import os

/// Diagnostic counters. Increments race benignly across threads by design; these values are
/// indicative, never load-bearing, and cost one predictable branch when reporting is disabled.
enum OWEFrameMetrics {
    static let defaultsEnabled: Bool = {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()

    nonisolated(unsafe) static var isReportingEnabled = defaultsEnabled

    nonisolated(unsafe) private static var frameCount = 0
    nonisolated(unsafe) private static var accumulatedFrameSeconds = 0.0
    nonisolated(unsafe) private static var worstFrameSeconds = 0.0
    nonisolated(unsafe) private static var lastReportTime = CACurrentMediaTime()

    nonisolated(unsafe) private static var lockAcquisitions = 0
    nonisolated(unsafe) private static var sceneReloads = 0
    nonisolated(unsafe) private static var textureDecodes = 0
    nonisolated(unsafe) private static var layersDrawn = 0
    nonisolated(unsafe) private static var particlesUpdated = 0

    static func countLockAcquisition() {
        guard isReportingEnabled else { return }
        lockAcquisitions &+= 1
    }

    static func countSceneReload() {
        guard isReportingEnabled else { return }
        sceneReloads &+= 1
    }

    static func countTextureDecode() {
        guard isReportingEnabled else { return }
        textureDecodes &+= 1
    }

    static func recordFrame(seconds: Double, layers: Int, particles: Int) {
        guard isReportingEnabled else { return }
        frameCount &+= 1
        accumulatedFrameSeconds += seconds
        worstFrameSeconds = max(worstFrameSeconds, seconds)
        layersDrawn &+= layers
        particlesUpdated &+= particles

        let now = CACurrentMediaTime()
        guard now - lastReportTime >= 2 else { return }
        report(elapsed: now - lastReportTime)
        lastReportTime = now
    }

    private static func report(elapsed: Double) {
        guard frameCount > 0 else { return }
        let averageMs = accumulatedFrameSeconds / Double(frameCount) * 1000
        let worstMs = worstFrameSeconds * 1000
        let fps = Double(frameCount) / elapsed
        let perFrame = { (value: Int) in Double(value) / Double(frameCount) }

        OWELog.info(.perf, String(format:
            "fps %.1f | frame avg %.2fms p-worst %.2fms | layers/f %.1f particles/f %.0f | locks/f %.1f | reloads %d texDecodes %d",
            fps, averageMs, worstMs,
            perFrame(layersDrawn), perFrame(particlesUpdated),
            perFrame(lockAcquisitions),
            sceneReloads, textureDecodes))

        frameCount = 0
        accumulatedFrameSeconds = 0
        worstFrameSeconds = 0
        lockAcquisitions = 0
        layersDrawn = 0
        particlesUpdated = 0
        sceneReloads = 0
        textureDecodes = 0
    }
}
