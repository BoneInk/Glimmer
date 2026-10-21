#if GW_UNIVERSAL_SCENE_BACKEND
import AppKit
import Foundation
import Darwin
import CoreVideo
import IOSurface

/// Exact packaged client with an offscreen host; no library/desktop/credentials.
@MainActor
enum SceneUniversalDiagnostic {
    static func run(arguments: [String]) async -> Int32 {
        func parameter(_ key: String) -> String? {
            guard let i = arguments.firstIndex(of: key), i + 1 < arguments.count else { return nil }
            return arguments[i + 1]
        }
        guard let projectPath = parameter("--project"), projectPath.hasPrefix("/"),
              let evidencePath = parameter("--evidence"), evidencePath.hasPrefix("/"),
              SceneBackendAvailability.isInstalled else { return 2 }
        let output = URL(fileURLWithPath: evidencePath, isDirectory: true)
        if arguments.contains("--preview-load") {
            return await ScenePreviewLoadDiagnostic.run(projectURL: URL(fileURLWithPath: projectPath),
                output: output)
        }
        var report: [String: Any] = ["desktopApplied": false, "lockScreenApplied": false,
            "credentialsRead": false, "originalProjectModified": false]
        var runtime: SceneWallpaperRuntime?
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let descriptor = try SceneWallpaperProjectDescriptor(projectURL: URL(fileURLWithPath: projectPath))
            let authorProject = try AuthorPropertyProject.load(projectURL: descriptor.projectURL,
                allowedRoot: descriptor.root)
            let usage = await Task.detached(priority: .utility) {
                SceneAuthorPropertyUsageAnalyzer.analyze(project: authorProject)
            }.value
            report["authorUsageAnalysisConclusive"] = usage.isConclusive
            report["authorOptionsWithoutSourceReferences"] = usage.unreferencedScalarKeys.sorted()
            report["structuralDownloadAccepted"] = true
            let target = try SceneWallpaperRuntime(projectURL: descriptor.projectURL,
                screenResolution: .init(x: 1280, y: 720))
            runtime = target
            guard target.usesUniversalBackend else { throw UniversalSceneBackendError.unavailable }
            try target.setFrameRateLimit(30)
            try await target.load(propertiesJSON: Data("{}".utf8))
            report["sceneLoadTimingMilliseconds"] = target.sceneLoadTimingMilliseconds
            try await Task.sleep(for: .milliseconds(500))
            guard target.state == .ready, target.frameCount > 1, let process = target.backendProcessStatus else {
                throw UniversalSceneBackendError.notReady
            }
            report["universalBackend"] = true
            report["helperPID"] = process.helperPID
            report["firstFrames"] = target.frameCount
            // Real helper-side sound state: default muted, and the audited original sound layers.
            report["soundDefaultMuted"] = process.soundEnabled == false
            report["soundPreparedLayers"] = process.soundsPrepared ?? 0
            report["auditedSoundObjectIDs"] = target.readiness?.auditedSoundObjectIDs ?? []
            let beforeFPS = target.activeRuntime
            try target.setFrameRateLimit(60)
            try await Task.sleep(for: .milliseconds(400))
            report["fpsUpdateKeepsProcess"] = target.backendProcessStatus?.helperPID == process.helperPID
            report["fpsUpdateKeepsClock"] = target.activeRuntime >= beforeFPS
            target.setPaused(true)
            try await Task.sleep(for: .milliseconds(150))
            let pausedTime = target.activeRuntime, pausedFrames = target.frameCount
            try await Task.sleep(for: .milliseconds(300))
            report["pauseHoldsClock"] = target.activeRuntime == pausedTime
            report["pauseHoldsFrameRequests"] = target.frameCount == pausedFrames
            target.setPaused(false)
            try await Task.sleep(for: .milliseconds(350))
            report["resumeAdvances"] = target.activeRuntime > pausedTime && target.frameCount > pausedFrames
            if arguments.contains("--exercise-sound") {
                target.setSceneSound(enabled: true, volume: 0.5)
                try await Task.sleep(for: .milliseconds(500))
                guard let sound = target.backendProcessStatus, sound.soundEnabled == true,
                      sound.soundVolume == 0.5 else { throw UniversalSceneBackendError.notReady }
                report["soundEnabledApplied"] = true
                report["soundPreparedLayers"] = sound.soundsPrepared ?? 0
                report["soundPlayingVoices"] = sound.soundPlaying ?? 0
                target.setSceneSound(enabled: false, volume: 0.5)
                try await Task.sleep(for: .milliseconds(400))
                guard target.backendProcessStatus?.soundEnabled == false else {
                    throw UniversalSceneBackendError.notReady
                }
                report["soundMutedAfterExercise"] = true
            }
            if let propertiesPath = parameter("--properties"), propertiesPath.hasPrefix("/") {
                let payload = try Data(contentsOf: URL(fileURLWithPath: propertiesPath))
                try await target.applyPropertiesAndWait(payload)
                try await Task.sleep(for: .milliseconds(200))
                guard let status = target.backendProcessStatus, let revision = status.propertyRevision,
                      revision > 0 else { throw UniversalSceneBackendError.notReady }
                report["propertiesAppliedRevision"] = revision
            }
            let checks = ["fpsUpdateKeepsProcess", "fpsUpdateKeepsClock", "pauseHoldsClock", "pauseHoldsFrameRequests", "resumeAdvances"]
            guard checks.allSatisfy({ report[$0] as? Bool == true }), target.lastError == nil else {
                throw UniversalSceneBackendError.notReady
            }
            if arguments.contains("--exercise-interruption") {
                // Only terminate the helper owned by this offscreen diagnostic.
                // No GUI, user assignment or unrelated helper is involved.
                guard let owned = target.backendProcessStatus, owned.ownsSession,
                      owned.helperPID > 1, owned.helperPID != getpid(),
                      kill(owned.helperPID, SIGKILL) == 0 else {
                    throw UniversalSceneBackendError.interrupted
                }
                for _ in 0..<40 where target.state != .failed {
                    try await Task.sleep(for: .milliseconds(50))
                }
                report["stateAfterForcedHelperExit"] = target.state.rawValue
                guard target.state == .failed else { throw UniversalSceneBackendError.notReady }
                report["helperInterruptionHandledWithoutMainCrash"] = true
                // Leave time for the authenticated, terminated process to be
                // retired, then exercise fresh sessions through the real XPC.
                try await Task.sleep(for: .milliseconds(200))
                var reopenedPIDs = [Int32]()
                for _ in 0..<4 {
                    try await target.load(propertiesJSON: Data("{}".utf8))
                    try await Task.sleep(for: .milliseconds(250))
                    guard target.state == .ready, target.frameCount > 1,
                          let reopened = target.backendProcessStatus else {
                        throw UniversalSceneBackendError.notReady
                    }
                    reopenedPIDs.append(reopened.helperPID)
                }
                report["repeatedFreshSessions"] = reopenedPIDs.count
                report["freshHelperPIDs"] = Set(reopenedPIDs).count == reopenedPIDs.count
                guard Set(reopenedPIDs).count == reopenedPIDs.count else {
                    throw UniversalSceneBackendError.interrupted
                }
            }
            if arguments.contains("--lock-screen-export") {
                guard let exportPath = parameter("--output"), exportPath.hasPrefix("/") else {
                    throw UniversalSceneBackendError.invalidProject
                }
                let outputDirectory = URL(fileURLWithPath: exportPath, isDirectory: true)
                try FileManager.default.createDirectory(at: outputDirectory,
                    withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let payload = try parameter("--properties").map {
                    try Data(contentsOf: URL(fileURLWithPath: $0))
                } ?? Data("{}".utf8)
                let exporter = SceneWallpaperLockScreenExporter()
                let recorded = try await exporter.export(projectURL: URL(fileURLWithPath: projectPath),
                    authorPayload: payload, directory: outputDirectory)
                let probe = try await VideoProbe.probe(url: recorded.videoURL)
                let codec = (probe.videoCodec ?? "").lowercased()
                let videoFormatValid = probe.isPlayable && !probe.hasAudioTrack
                    && abs(probe.durationSeconds - 10) <= 0.2
                    && probe.pixelWidth == 1920 && probe.pixelHeight == 1080
                    && (codec.contains("avc") || codec.contains("h264"))
                    && recorded.renderedFrameCount == 300 && recorded.visibleFrameCount > 0
                guard videoFormatValid else { throw UniversalSceneBackendError.invalidFrame }
                let animated = recorded.distinctFrameCount > 1 && recorded.maximumFrameDifference >= 0.35
                if !arguments.contains("--allow-static") {
                    guard animated else { throw UniversalSceneBackendError.invalidFrame }
                }
                let orientationPassed = try await exportOrientationProbe()
                guard orientationPassed else { throw UniversalSceneBackendError.invalidFrame }
                let targetPID = target.backendProcessStatus?.helperPID
                let lockScreenReport: [String: Any] = [
                    "videoPath": recorded.videoURL.path,
                    "durationSeconds": probe.durationSeconds,
                    "width": probe.pixelWidth, "height": probe.pixelHeight,
                    "codec": probe.videoCodec ?? "unknown",
                    "hasAudioTrack": probe.hasAudioTrack,
                    "renderedFrames": recorded.renderedFrameCount,
                    "distinctFrames": recorded.distinctFrameCount,
                    "visibleFrames": recorded.visibleFrameCount,
                    "maximumFrameDifference": recorded.maximumFrameDifference,
                    "firstElapsedSeconds": recorded.firstElapsedSeconds,
                    "orientationPassed": orientationPassed,
                    "usedIndependentHelper": recorded.helperPID != nil
                        && recorded.helperPID != targetPID,
                    "systemLockScreenTouched": false,
                    "userLibraryTouched": false
                ]
                report["lockScreenExport"] = lockScreenReport
            }
            if arguments.contains("--verify-lock-cache") {
                report["lockScreenCache"] = try await verifyLockCache(projectURL: descriptor.projectURL,
                    output: output)
            }
            target.dispose()
            report["success"] = true
            report["disposed"] = target.state == .disposed
        } catch {
            if let runtime {
                report["sceneLoadTimingMilliseconds"] = runtime.sceneLoadTimingMilliseconds
            }
            runtime?.dispose()
            report["success"] = false
            report["error"] = error.localizedDescription
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: output.appendingPathComponent("report.json"), options: .atomic)
        } catch { return 1 }
        print(report["success"] as? Bool == true ? "通用 Scene 应用管线验收通过。" : "通用 Scene 应用管线验收未通过。")
        return report["success"] as? Bool == true ? 0 : 1
    }

    private final class CacheProbeState { var exports = 0 }

    /// Uses the production material provider and exporter, without the system
    /// lock-screen coordinator. All writable state stays in this diagnostic root.
    private static func verifyLockCache(projectURL: URL, output: URL) async throws -> [String: Any] {
        let storage = AppStorage(root: output.appendingPathComponent("IsolatedStorage", isDirectory: true))
        let item = WallpaperItem(title: "Cache diagnostic", filePath: projectURL.path, contentKind: .scene)
        let settings = RenderedLockScreenVideoCache.Settings(signature: "scene-h264-v1")
        let state = CacheProbeState()
        let root = storage.root.appendingPathComponent("SceneVideoCache", isDirectory: true)
        let material = try await SceneWallpaperLockScreenConfiguration.material(item: item, storage: storage)
        let repeated = try await SceneWallpaperLockScreenConfiguration.material(item: item, storage: storage)
        guard material.identityHash == repeated.identityHash, material.payload == repeated.payload else {
            throw RenderedLockScreenVideoFailure(message: "相同作者参数的缓存标识不稳定。")
        }
        func makeCache() -> RenderedLockScreenVideoCache {
            RenderedLockScreenVideoCache(root: root, settings: settings,
                materialProvider: {
                    try await SceneWallpaperLockScreenConfiguration.material(item: item, storage: storage)
                }, exportOperation: { payload, directory, progress in
                    state.exports += 1
                    return try await SceneWallpaperLockScreenExporter(settings: settings)
                        .export(item: item, authorPayload: payload, directory: directory, progress: progress).videoURL
                })
        }
        let first = try await makeCache().withVideo { $0 }
        let second = try await makeCache().withVideo { $0 }
        let probe = try await VideoProbe.probe(url: second)
        guard first == second, state.exports == 1, probe.isPlayable,
              !probe.hasAudioTrack, probe.pixelWidth == 1920, probe.pixelHeight == 1080 else {
            throw RenderedLockScreenVideoFailure(message: "真实 Scene 锁屏缓存复用检查失败。")
        }
        return ["exports": state.exports, "sameVideoReused": first == second,
            "stableProductionMaterial": true, "videoPath": second.path,
            "durationSeconds": probe.durationSeconds, "width": probe.pixelWidth,
            "height": probe.pixelHeight, "hasAudioTrack": probe.hasAudioTrack,
            "systemLockScreenTouched": false, "userLibraryTouched": false]
    }

    /// Offscreen Metal probe for the export orientation contract: a synthetic
    /// top-red/bottom-blue frame must stay upright in the encoder pixel buffer.
    private static func exportOrientationProbe() async throws -> Bool {
        let width = 64, height = 32, bytesPerRow = width * 4
        let surfaceProperties: [String: Any] = [
            kIOSurfaceWidth as String: width,
            kIOSurfaceHeight as String: height,
            kIOSurfaceBytesPerRow as String: bytesPerRow,
            kIOSurfacePixelFormat as String: 0x4247_5241
        ]
        guard let surface = IOSurfaceCreate(surfaceProperties as CFDictionary) else { return false }
        IOSurfaceLock(surface, [], nil)
        do {
            let base = IOSurfaceGetBaseAddress(surface)
            let pixels = base.assumingMemoryBound(to: UInt8.self)
            let surfaceRow = IOSurfaceGetBytesPerRow(surface)
            for y in 0..<height {
                for x in 0..<width {
                    let offset = y * surfaceRow + x * 4
                    let red = y < height / 2
                    pixels[offset] = red ? 0 : 255
                    pixels[offset + 1] = 0
                    pixels[offset + 2] = red ? 255 : 0
                    pixels[offset + 3] = 255
                }
            }
        }
        IOSurfaceUnlock(surface, [], nil)
        var optional: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                  kCVPixelFormatType_32BGRA, attributes as CFDictionary, &optional) == kCVReturnSuccess,
              let buffer = optional else { return false }
        let token = SceneFrameToken(sessionID: UUID(), generation: 1, sequence: 1,
            slotID: UUID(), width: width, height: height, bytesPerRow: bytesPerRow,
            pixelFormat: "BGRA8Unorm")
        let host = try SceneBackendMetalHostView.make()
        try await host.copyFrame(surface: surface, token: token, into: buffer)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let output = CVPixelBufferGetBaseAddress(buffer) else { return false }
        let out = output.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        func mean(rows: Range<Int>) -> (red: Double, blue: Double) {
            var red = 0.0, blue = 0.0, count = 0.0
            for y in rows {
                for x in stride(from: 0, to: width, by: 4) {
                    let offset = y * row + x * 4
                    blue += Double(out[offset]); red += Double(out[offset + 2]); count += 1
                }
            }
            return (red / count, blue / count)
        }
        let top = mean(rows: 0..<(height / 4)), bottom = mean(rows: (height * 3 / 4)..<height)
        return top.red > 180 && top.blue < 60 && bottom.blue > 180 && bottom.red < 60
    }
}
#endif
