#if GW_UNIVERSAL_SCENE_BACKEND
import AppKit
import Foundation
import Darwin

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

}
#endif
