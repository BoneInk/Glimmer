#if GW_UNIVERSAL_SCENE_BACKEND
import AppKit
import Foundation
import SwiftUI

/// Exercises the detail's actual click-time preparation and borrowed preview
/// model. No library assignment, native wallpaper selection or credentials.
@MainActor
enum ScenePreviewLoadDiagnostic {
    static func run(projectURL: URL, output: URL) async -> Int32 {
        var report: [String: Any] = ["desktopApplied": false, "lockScreenApplied": false]
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let storage = AppStorage(root: output.appendingPathComponent("IsolatedStorage"))
            let item = WallpaperItem(title: "Scene preview diagnostic", filePath: projectURL.path, contentKind: .scene)
            let screen = NSScreen.main
            let display = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            let resolution = display.flatMap { SceneWallpaperRuntime.physicalScreenResolution(displayID: $0) }
            let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1233, height: 738),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.alphaValue = 0.01
            defer { window.close() }
            var runs = [[String: Any]]()
            for _ in 0..<3 {
                let start = ContinuousClock.now
                let preparation = SceneWallpaperPreviewPreparation(item: item, storage: storage,
                    wallpaperFPS: 30, screenResolution: resolution)
                defer { preparation.cancel() }
                var maximumMainActorGap = 0.0
                var samples = 0
                var readyNotification: ContinuousClock.Instant?
                let monitor = Task { @MainActor in
                    var previous = ContinuousClock.now
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(10))
                        let now = ContinuousClock.now
                        maximumMainActorGap = max(maximumMainActorGap, milliseconds(previous.duration(to: now)))
                        samples += 1
                        previous = now
                    }
                }
                defer { monitor.cancel() }
                // The detail mounts while the cover animation is running and
                // requests pause until its first frame can replace the cover.
                try await Task.sleep(for: .milliseconds(80))
                window.contentView = NSHostingView(rootView: SceneWallpaperPreviewView(item: item,
                    isPaused: true, storage: storage, previewModel: preparation.model,
                    onReady: { if readyNotification == nil { readyNotification = .now } }))
                window.orderFront(nil)
                await preparation.model.update(item: item, paused: true, storage: storage, wallpaperFPS: 30)
                guard let runtime = preparation.model.runtime,
                      runtime.state == .paused, preparation.model.error == nil else {
                    throw UniversalSceneBackendError.notReady
                }
                let firstFrame = ContinuousClock.now
                for _ in 0..<100 where readyNotification == nil {
                    try await Task.sleep(for: .milliseconds(10))
                }
                guard let readyNotification else { throw UniversalSceneBackendError.notReady }
                runs.append(["clickToFirstFrameMilliseconds": milliseconds(start.duration(to: firstFrame)),
                    "clickToSwiftUIReadyMilliseconds": milliseconds(start.duration(to: readyNotification)),
                    "previewLoadTimingMilliseconds": preparation.model.loadTimingMilliseconds,
                    "backendLoadTimingMilliseconds": runtime.sceneLoadTimingMilliseconds,
                    "shaderCacheRestoredFiles": runtime.shaderCacheRestoredFiles,
                    "maximumMainActorGapMilliseconds": maximumMainActorGap,
                    "mainActorSamples": samples,
                    "width": resolution?.x ?? 0, "height": resolution?.y ?? 0])
                preparation.cancel()
                window.contentView = nil
                monitor.cancel()
                try await Task.sleep(for: .milliseconds(400))
            }
            report["runs"] = runs
            report["success"] = true
        } catch {
            report["success"] = false
            report["error"] = String(describing: error)
        }
        do {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("preview-load-report.json"), options: .atomic)
        } catch { return 1 }
        print("Scene preview load diagnostic: \(report["success"] as? Bool == true ? "passed" : "failed")")
        return report["success"] as? Bool == true ? 0 : 1
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let value = duration.components
        return Double(value.seconds) * 1_000 + Double(value.attoseconds) / 1e15
    }
}
#endif
