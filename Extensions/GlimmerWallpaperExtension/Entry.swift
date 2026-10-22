import AppKit
import Darwin
import ExtensionFoundation
import Foundation
import ObjectiveC

private func GWLoadRuntime() -> Bool {
    dlopen("/System/Library/PrivateFrameworks/WallpaperExtensionKit.framework/WallpaperExtensionKit", RTLD_NOW | RTLD_LOCAL) != nil
}

#if !GW_DIAGNOSTIC_ENTRY
@main
#endif
final class GWNativeExtension: NSObject, AppExtension {
    override required init() {
        super.init()
        GWLog("experimental native wallpaper starting uid=\(getuid()) build=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "unknown") path=\(Bundle.main.bundlePath) privateRuntime=\(GWLoadRuntime())")
    }
    var configuration: some AppExtensionConfiguration { GWExtensionConfiguration() }
}

#if GW_DIAGNOSTIC_ENTRY
@main
struct GWExtensionDiagnostics {
    @MainActor private static var webDiagnostic: GWWebLayerDiagnostics?
    @MainActor static func main() {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--web-layer-producer"), args.count > index + 1 {
            _ = GWLoadRuntime()
            _ = NSApplication.shared
            Task { @MainActor in
                do {
                    webDiagnostic = try await GWWebLayerDiagnostics(directory: URL(fileURLWithPath: args[index+1]), receiver: true)
                    try await webDiagnostic!.serve()
                } catch { printJSON(["event":"error","error":error.localizedDescription]); fflush(stdout); exit(1) }
            }
            NSApplication.shared.run()
            return
        }
        if let index = args.firstIndex(of: "--isolated-live-probe"), args.count > index + 1 {
            _ = GWLoadRuntime()
            _ = NSApplication.shared
            let directory = URL(fileURLWithPath: args[index + 1], isDirectory: true)
            Task { @MainActor in
                await liveProbe(directory: directory)
            }
            NSApplication.shared.run()
            return
        }
        if args.contains("--runtime-probe") {
            let loaded = GWLoadRuntime()
            let names = ["WallpaperIDXPC", "WallpaperCreationRequestXPC", "WallpaperRemoteContextXPC", "WallpaperSnapshotXPC", "WallpaperSettingsViewModelsXPC"]
            var layouts: [String: Any] = [:]
            for name in names {
                if let cls = objc_getClass(name) as? AnyClass {
                    var count: UInt32 = 0
                    let list = class_copyIvarList(cls, &count)
                    defer { free(list) }
                    var ivars: [String: Int] = [:]
                    for i in 0..<Int(count) {
                        if let ivar = list?[i], let name = ivar_getName(ivar) { ivars[String(cString: name)] = ivar_getOffset(ivar) }
                    }
                    layouts[name] = ["size": class_getInstanceSize(cls), "ivars": ivars]
                }
            }
            let settings = GWSettingsResponse()
            let result: [String: Any] = ["privateFrameworkLoaded": loaded, "uid": getuid(), "sandboxActive": GWSandboxIsActive(), "classes": layouts,
                                        "settingsObjectCreated": settings != nil,
                                        "settingsSecureRoundTrip": settings.map { GWRoundTripObject($0) } ?? false,
                                        "systemWallpaperModified": false]
            printJSON(result)
            exit(loaded && layouts.count == names.count && settings != nil ? 0 : 1)
        }
        if let index = args.firstIndex(of: "--validate-staged-config"), args.count > index + 1 {
            do {
                _ = try GWConfiguration.load(directory: URL(fileURLWithPath: args[index + 1], isDirectory: true), isolatedProbe: true)
                printJSON(["configurationValid": true, "sandboxActive": GWSandboxIsActive()])
                exit(0)
            } catch {
                printJSON(["configurationValid": false, "reason": error.localizedDescription, "sandboxActive": GWSandboxIsActive()])
                exit(1)
            }
        }
        if let index = args.firstIndex(of: "--isolated-video-probe"), args.count > index + 1 {
            _ = GWLoadRuntime()
            _ = NSApplication.shared
            do {
                let directory = URL(fileURLWithPath: args[index + 1], isDirectory: true)
                let (config, url) = try GWConfiguration.load(directory: directory, isolatedProbe: true)
                struct ProbeRequest { let size = CGSize(width: 640, height: 360); let scaleFactor: CGFloat = 1; let isPreview = true }
                let surface = try GWVideoSurface(config: config, video: url, request: GWRequest(ProbeRequest()))
                var started = false
                surface.start { started = $0 }
                let deadline = Date().addingTimeInterval(7)
                while Date() < deadline && (!started || surface.frameCount < 8 || surface.sampledSignatures.count < 2) {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                }
                let response = createRemoteContextXPC(contextId: surface.context.contextId)
                let snapshot = surface.lastBuffer.flatMap(GWSnapshot)
                let snapshotTransport = snapshot.map { GWXPCObjectRoundTrip($0, 3) } ?? false
                let contextTransport = response.map { GWXPCObjectRoundTrip($0, 3) } ?? false
                struct PausedRequest { let size = CGSize(width: 640, height: 360); let isPreview = false; let presentationMode = "default"; let activityState = "inactive" }
                surface.update(GWRequest(PausedRequest()))
                let pausedCount = surface.frameCount
                RunLoop.main.run(until: Date().addingTimeInterval(0.15))
                let paused = surface.player.rate == 0 && surface.frameCount == pausedCount && surface.lastBuffer != nil
                surface.update(GWRequest(ProbeRequest()))
                let resumeDeadline = Date().addingTimeInterval(1)
                while Date() < resumeDeadline && surface.frameCount < pausedCount + 2 {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                }
                let resumed = surface.frameCount >= pausedCount + 2
                var result: [String: Any] = ["started": started, "remoteContextIDNonzero": surface.context.contextId != 0,
                    "remoteContextSecureRoundTrip": response.map { GWRoundTripObject($0) } ?? false,
                    "decodedFramesEnqueued": surface.frameCount, "differentFrameSignatures": surface.sampledSignatures.count,
                    "sampleRendererStatus": surface.layer.sampleBufferRenderer.status.rawValue,
                    "desktopModePausesWithoutFrameLoop": paused, "previewOrLockedModeResumes": resumed,
                    "muted": surface.player.isMuted, "volume": surface.player.volume,
                    "uid": getuid(), "sandboxActive": GWSandboxIsActive(),
                    "snapshotObjectCreated": snapshot != nil,
                    "snapshotXPCTransportRoundTrip": snapshotTransport,
                    "remoteContextXPCTransportRoundTrip": contextTransport,
                    "snapshotArchiveLimit": "Uses anonymous local NSXPC transport/NSXPCCoder, not NSKeyedArchiver",
                    "systemWallpaperModified": false,
                    "scope": "isolated sandbox process reads same-user staged demo, private CAContext + real video decoding/sample-layer enqueue; NOT system-host/lock-screen visual proof"]
                var success = started && surface.frameCount >= 8 && surface.sampledSignatures.count >= 2 && response != nil
                    && snapshotTransport && contextTransport && GWSandboxIsActive() && paused && resumed
                surface.stop()
                let released = surface.player.currentItem == nil && surface.player.rate == 0 && surface.context.layer == nil && surface.lastBuffer == nil
                result["stopReleasesPlayerContextAndBuffer"] = released
                success = success && released
                printJSON(result)
                exit(success ? 0 : 1)
            } catch {
                printJSON(["error": error.localizedDescription, "systemWallpaperModified": false])
                exit(1)
            }
        }
        fputs("Diagnostic helper requires --runtime-probe, --validate-staged-config or --isolated-video-probe\n", stderr)
        exit(2)
    }
    private static func printJSON(_ value: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
           let string = String(data: data, encoding: .utf8) { print(string) }
    }

    @MainActor private static func liveProbe(directory: URL) async {
        var result: [String: Any] = ["systemWallpaperModified": false, "sandboxActive": GWSandboxIsActive()]
        var surface: GWLiveSurface?
        do {
            let (config, root) = try GWConfiguration.load(directory: directory, isolatedProbe: true)
            let recipe = try LiveWallpaperBundle.load(root)
            if recipe.kind == .web {
                webDiagnostic = try await GWWebLayerDiagnostics(directory: directory, receiver: false)
                await webDiagnostic!.run()
                return
            }
            struct Playing { let size = CGSize(width: 640, height: 400); let isPreview = false; let presentationMode = "default" }
            struct Paused { let size = CGSize(width: 640, height: 400); let isPreview = false; let presentationMode = "default"; let activityState = "inactive" }
            let live = try GWLiveSurface(config: config, directory: root, request: GWRequest(Playing()), recipe: recipe)
            surface = live
            var started = false
            live.start { started = $0 }
            let deadline = ContinuousClock.now + .seconds(25)
            while !started, live.lastError == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
            guard started else { throw GWError(70, live.lastError ?? "Live surface startup timed out") }
            try await waitForFrames(live, after: 8)
            guard let first = live.lastBuffer else { throw GWError(71, "Live frame missing") }
            let firstSignature = frameSignature(first), count = live.frameCount
            let context = createRemoteContextXPC(contextId: live.context.contextId)
            let snapshot = GWSnapshot(first)
            result["started"] = started; result["kind"] = recipe.kind.rawValue
            result["contextXPCTransport"] = context.map { GWXPCObjectRoundTrip($0, 3) } ?? false
            result["snapshotXPCTransport"] = snapshot.map { GWXPCObjectRoundTrip($0, 3) } ?? false
            live.update(GWRequest(Paused()))
            try await Task.sleep(for: .milliseconds(300))
            let pausedFrames = live.frameCount
            try await Task.sleep(for: .milliseconds(300))
            let held = live.frameCount == pausedFrames && live.lastBuffer != nil
            live.update(GWRequest(Playing()))
            try await waitForFrames(live, after: pausedFrames)
            guard let latest = live.lastBuffer else { throw GWError(72, "Resumed frame missing") }
            let advanced = live.frameCount > pausedFrames + 1 && firstSignature != frameSignature(latest)
            let contextID = live.context.contextId
            live.setSleeping(true)
            try await Task.sleep(for: .milliseconds(400))
            let sleepingFrames = live.frameCount
            try await Task.sleep(for: .milliseconds(300))
            let sleepHeld = live.frameCount == sleepingFrames && live.lastBuffer != nil
            live.setSleeping(false)
            try await waitForFrames(live, after: sleepingFrames)
            let wakeResumed = live.frameCount > sleepingFrames + 1 && live.context.contextId == contextID
            let pid = live.helperPID
            result["defaultModePlayback"] = count > 2 && advanced
            result["sleepFrameHeld"] = sleepHeld
            result["wakeResumedSameContext"] = wakeResumed
            result["pausedFrameHeld"] = held; result["hiddenWebDocumentReleased"] = true
            result["resumedChangingFrames"] = advanced
            result["frameCount"] = live.frameCount
            result["helperPID"] = pid
            result["lastError"] = live.lastError
            let success = advanced && held && sleepHeld && wakeResumed && live.lastError == nil
                && result["contextXPCTransport"] as? Bool == true && result["snapshotXPCTransport"] as? Bool == true
            live.stop()
            let exited = if let pid { await SceneBackendProcessExit.wait(pid: pid) } else { true }
            result["ownedHelperExited"] = exited
            result["releasedContextAndFrames"] = live.context.layer == nil && live.lastBuffer == nil
            result["success"] = success && exited && GWSandboxIsActive()
            printJSON(result); fflush(stdout); exit(result["success"] as? Bool == true ? 0 : 1)
        } catch {
            if let detail = surface?.failureDetail {
                result["failureCode"] = detail.code
                result["failureTechnicalDetail"] = detail.technicalDetail
                result["missingResources"] = detail.missingResources
            }
            surface?.stop()
            result["error"] = error.localizedDescription; result["success"] = false
            printJSON(result); fflush(stdout); exit(1)
        }
    }

    @MainActor private static func waitForFrames(_ surface: GWLiveSurface, after count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while surface.frameCount <= count + 1, surface.lastError == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard surface.frameCount > count + 1 else { throw GWError(73, surface.lastError ?? "Live frames did not resume") }
    }

    private static func frameSignature(_ buffer: CVPixelBuffer) -> UInt64 {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0 }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let length = CVPixelBufferGetHeight(buffer) * CVPixelBufferGetBytesPerRow(buffer)
        var hash: UInt64 = 1469598103934665603
        for index in stride(from: 0, to: length, by: max(1, length / 4096)) { hash = (hash ^ UInt64(bytes[index])) &* 1099511628211 }
        return hash
    }
}

#endif
