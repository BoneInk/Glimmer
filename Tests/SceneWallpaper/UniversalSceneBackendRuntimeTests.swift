import AppKit
import CryptoKit
import Foundation
import IOSurface

private struct BackendRuntimeTestFailure: Error { let message: String }

@MainActor
private final class FakeSceneBackendTransport: SceneBackendSessionTransport {
    static let helperPID: Int32 = 2_000_000_000
    var invalidationHandler: (@MainActor () -> Void)?
    var configuration: SceneBackendConfiguration?
    var renders = [SceneFrameInput]()
    var acknowledged = [SceneFrameToken]()
    var updates = [[String: String]]()
    var propertyRevision: UInt64 = 0
    var pauses = [Bool]()
    var sounds = [(enabled: Bool, volume: Double)]()
    var closed = false
    var invalidated = false
    var invalidToken = false
    var fps = 30
    var fill = true
    var fpsCalls = [Int]()
    var holdNextRender = false
    var heldRender: CheckedContinuation<Void, Never>?
    var renderDelay: Duration = .zero
    var renderStarts = [ContinuousClock.Instant]()
    var inFlightFrames = 0
    var maximumInFlightFrames = 0
    let instanceID = UUID()
    var statusValue: SceneBackendProcessStatus {
        .init(helperPID: Self.helperPID, instanceID: instanceID,
              sessionID: configuration?.sessionID, generation: configuration?.generation, ownsSession: true,
              frameRateLimit: fps, aspectFill: fill, sceneSeconds: renders.last?.elapsedSeconds ?? 0,
              paused: pauses.last ?? false,
              soundEnabled: sounds.last?.enabled ?? false,
              soundVolume: sounds.last?.volume ?? 1,
              soundsPrepared: 0, soundPlaying: 0,
              propertyRevision: propertyRevision)
    }

    func status() async throws -> SceneBackendProcessStatus { statusValue }
    func prepare(_ configuration: SceneBackendConfiguration) async throws -> SceneBackendReadiness {
        self.configuration = configuration
        return .init(sessionID: configuration.sessionID, generation: configuration.generation,
            projectDigest: configuration.roots.projectDigest,
            assetsManifestDigest: configuration.roots.assetsManifestDigest,
            authoredDrawableIDs: ["fixture"], accountedDrawableIDs: ["fixture"], fallbackDrawableIDs: [],
            unresolvedResources: [], scriptErrors: [], pipelineFailureCount: 0, exactFontsResolved: true,
            requiredVideoStreamsReady: true, auditedSoundObjectIDs: [],
            gpuFrameCompleted: true, capabilityAuditCompleted: true,
            diagnostics: [])
    }
    func render(_ input: SceneFrameInput) async throws -> (SceneFrameToken, IOSurface) {
        guard let configuration else { throw UniversalSceneBackendError.notReady }
        renders.append(input)
        renderStarts.append(.now)
        inFlightFrames += 1
        maximumInFlightFrames = max(maximumInFlightFrames, inFlightFrames)
        if renderDelay > .zero { try? await Task.sleep(for: renderDelay) }
        if holdNextRender {
            holdNextRender = false
            await withCheckedContinuation { heldRender = $0 }
        }
        let bytesPerRow = (configuration.width * 4 + 255) & ~255
        guard let surface = IOSurface(properties: [
            .width: configuration.width, .height: configuration.height, .bytesPerElement: 4,
            .bytesPerRow: bytesPerRow, .allocSize: bytesPerRow * configuration.height,
            .pixelFormat: UInt32(0x4247_5241)
        ]) else { throw UniversalSceneBackendError.invalidFrame }
        return (.init(sessionID: input.sessionID, generation: input.generation + (invalidToken ? 1 : 0), sequence: input.sequence,
                      slotID: UUID(), width: configuration.width, height: configuration.height,
                      bytesPerRow: bytesPerRow, pixelFormat: "BGRA8Unorm"), surface)
    }
    func acknowledge(_ token: SceneFrameToken) async throws {
        acknowledged.append(token)
        inFlightFrames -= 1
    }
    func updateProperties(_ properties: [String: String], revision: UInt64) async throws {
        guard revision > propertyRevision else { throw UniversalSceneBackendError.invalidProperties }
        updates.append(properties)
        propertyRevision = revision
    }
    func setFrameRateLimit(_ fps: Int) async throws { self.fps = fps; fpsCalls.append(fps) }
    func setAspectFill(_ fill: Bool) async throws { self.fill = fill }
    func setPaused(_ paused: Bool) async throws { pauses.append(paused) }
    func setSceneSound(enabled: Bool, volume: Double) async throws { sounds.append((enabled, volume)) }
    func close(sessionID: UUID, generation: UInt64) async { closed = true }
    func invalidate() { invalidated = true }
    func invalidateAndWait() async { invalidated = true }
}

@main @MainActor enum UniversalSceneBackendRuntimeTests {
    static func main() async throws {
        let manager = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp/gw-universal-scene-\(UUID())", isDirectory: true)
        defer { try? manager.removeItem(at: root) }
        var checks = [String]()
        func check(_ condition: Bool, _ name: String) throws {
            guard condition else { throw BackendRuntimeTestFailure(message: name) }
            checks.append(name); print("PASS \(name)")
        }
        func rejects(_ name: String, _ operation: () throws -> Void) throws {
            do { try operation(); throw BackendRuntimeTestFailure(message: name) }
            catch is BackendRuntimeTestFailure { throw BackendRuntimeTestFailure(message: name) }
            catch { checks.append(name); print("PASS \(name)") }
        }
        // Use real NSXPC error delivery on a background queue: mocked transports
        // cannot catch an accidentally MainActor-isolated error callback.
        for attempt in 0..<3 {
            let unavailable = SceneBackendXPCClient(serviceName: "com.boneink.Glimmer.MissingRegression.\(UUID())")
            do {
                _ = try await unavailable.status()
                throw BackendRuntimeTestFailure(message: "missing XPC service unexpectedly replied")
            } catch UniversalSceneBackendError.interrupted {
                try check(true, "real background XPC error returns without actor trap \(attempt + 1)")
            }
            await unavailable.invalidateAndWait()
        }
        func mkdir(_ url: URL) throws {
            try manager.createDirectory(at: url, withIntermediateDirectories: true)
            var current = url
            while current.path.hasPrefix(root.path) {
                try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: current.path)
                current.deleteLastPathComponent()
            }
        }
        func write(_ data: Data, _ url: URL) throws {
            try mkdir(url.deletingLastPathComponent()); try data.write(to: url)
            guard chmod(url.path, 0o600) == 0 else { throw BackendRuntimeTestFailure(message: "chmod") }
        }
        func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

        let appRoot = root.appendingPathComponent("Application Support/Glimmer", isDirectory: true)
        let workspace = appRoot.appendingPathComponent("Workshop/SteamContent", isDirectory: true)
        let registryURL = appRoot.appendingPathComponent("SceneBackend", isDirectory: true)
        try mkdir(workspace)
        let fingerprint = String(repeating: "b", count: 64)
        let content = workspace.appendingPathComponent("scene-runtime-assets/\(fingerprint)/content", isDirectory: true)
        let assetData = Data("fixture-engine-asset".utf8), logical = "shaders/fixture.vert"
        try write(assetData, content.appendingPathComponent("assets/" + logical))
        let registry = SceneRuntimeAssetRegistry(contentWorkspaceURL: workspace, registryURL: registryURL)
        try registry.registerVerifiedSteamBundle(.init(cacheRoot: content,
            manifestIdentity: .init(sha256: fingerprint, depotID: 431961, manifestID: 3687007859740550172),
            files: [.init(logicalPath: logical, relativePath: "assets/" + logical,
                          sha256: sha(assetData), sizeBytes: UInt64(assetData.count))]))

        let projectRoot = root.appendingPathComponent("project", isDirectory: true)
        let projectURL = projectRoot.appendingPathComponent("project.json")
        let project: [String: Any] = ["type": "scene", "file": "scene.json", "general": [
            "properties": [
                "enabled": ["type": "bool", "value": false],
                "amount": ["type": "slider", "value": 1, "min": 0, "max": 10],
                "tint": ["type": "color", "value": "1 1 1"],
                "mode": ["type": "combo", "value": true, "options": [["label": "on", "value": true], ["label": "off", "value": false]]],
                "caption": ["type": "textinput", "value": "default"],
                "picture": ["type": "file", "value": ""],
                "shortcut": ["type": "usershortcut", "value": ""]
            ]
        ]]
        try write(try JSONSerialization.data(withJSONObject: project), projectURL)
        try write(Data("{}".utf8), projectRoot.appendingPathComponent("scene.json"))
        let payload = try JSONSerialization.data(withJSONObject: [
            "enabled": ["type": "bool", "value": true], "amount": ["type": "slider", "value": 2],
            "tint": ["type": "color", "value": "0.1 0.2 0.3"],
            "mode": ["type": "combo", "value": false], "caption": ["type": "textinput", "value": "hello"],
            "picture": ["type": "file", "value": "/must/not/cross"]
        ])
        let fairPool = SceneBackendServicePool()
        let initialLease = try fairPool.acquire()
        fairPool.release(initialLease.0)
        let nextJob = try fairPool.acquire()
        try check(nextJob.0 != initialLease.0, "immediate reopen selects another independent XPC job")
        fairPool.release(nextJob.0)
        let pool = SceneBackendServicePool(), fake = FakeSceneBackendTransport()
        var serviceNames = [String]()
        let runtime = try UniversalSceneBackendRuntime(projectURL: projectURL,
            screenResolution: .init(x: 4, y: 4), followsHostScreen: false,
            registry: registry, pool: pool, transportFactory: { serviceNames.append($0); return fake })
        try runtime.setFrameRateLimit(60)
        try await runtime.load(propertiesJSON: payload)
        try check(runtime.state == .ready && runtime.frameCount >= 1 && fake.acknowledged.count >= 1,
                  "strict readiness publishes only after GPU consumption and frame acknowledgement")
        try check(runtime.processStatus?.soundEnabled == false && fake.sounds.last?.enabled == false,
                  "scene sound stays muted by default and the muted intent reaches the helper")
        try check(runtime.hostView.window == nil,
                  "headless prepare consumes and acknowledges a GPU frame without a drawable or presentation callback")
        try check(runtime.processStatus?.helperPID == FakeSceneBackendTransport.helperPID &&
                  runtime.processStatus?.instanceID == fake.statusValue.instanceID,
                  "runtime exposes the verified helper process lifecycle identity")
        try check(fake.configuration?.properties == ["enabled": "true", "amount": "2", "tint": "0.1 0.2 0.3", "mode": "false", "caption": "hello"],
                  "scalar author values use Wallpaper Engine strings while file and shortcut values stay unavailable")
        try check(runtime.editablePropertyKeys == ["enabled", "amount", "tint", "mode", "caption"],
                  "editable keys expose only supported scalar properties")
        try check(fake.configuration?.roots.assetsRoot.path.hasSuffix("/content/assets") == true &&
                  fake.configuration?.roots.assetsManifestDigest == fingerprint &&
                  fake.configuration?.roots.cacheRoot.path.contains("/SceneBackend/Sessions/") == true,
                  "configuration binds the verified asset root and a private per-session cache")
        let cachePath = fake.configuration!.roots.cacheRoot.path
        var cacheInfo = stat(); guard lstat(cachePath, &cacheInfo) == 0 else { throw BackendRuntimeTestFailure(message: "cache stat") }
        try check(cacheInfo.st_mode & S_IFMT == S_IFDIR && cacheInfo.st_mode & 0o077 == 0,
                  "session cache is an owned private directory")
        let peer = FakeSceneBackendTransport()
        let peerRuntime = try UniversalSceneBackendRuntime(projectURL: projectURL,
            screenResolution: .init(x: 4, y: 4), followsHostScreen: false,
            registry: registry, pool: pool, transportFactory: { serviceNames.append($0); return peer })
        try await peerRuntime.load(propertiesJSON: payload)
        try check(Set(serviceNames).count == 2 && pool.activeLeaseCount == 2 &&
                  fake.instanceID != peer.instanceID,
                  "two active runtimes own different service catalog slots and process instances")
        peerRuntime.dispose()
        for _ in 0..<100 where pool.activeLeaseCount != 1 { try await Task.sleep(for: .milliseconds(5)) }
        let beforePause = runtime.frameCount
        runtime.setPaused(true)
        try await Task.sleep(for: .milliseconds(120))
        try check(runtime.state == .paused && runtime.frameCount <= beforePause + 1,
                  "paused runtime stops scheduling new steps")
        let pausedTime = runtime.activeRuntime
        try await Task.sleep(for: .milliseconds(80))
        try check(runtime.activeRuntime == pausedTime, "paused wall time does not accumulate")
        let pausedFrameCount = fake.renders.count
        let pausedSequence = fake.renders.last!.sequence
        let update = try JSONSerialization.data(withJSONObject: ["enabled": ["value": false], "amount": ["value": 3],
            "tint": ["value": "1 0 0"], "mode": ["value": true], "caption": ["value": "updated"]])
        try await runtime.applyPropertiesAndWait(update)
        try check(runtime.state == .paused && fake.pauses.last == true &&
                  fake.renders.count == pausedFrameCount + 1 &&
                  fake.renders.last!.sequence == pausedSequence + 1 &&
                  fake.renders.last!.elapsedSeconds == pausedTime && runtime.activeRuntime == pausedTime &&
                  fake.updates.last?["enabled"] == "false" && fake.updates.last?["amount"] == "3",
                  "paused property update renders exactly one frame at frozen scene time without resuming")
        let aspectSequence = fake.renders.last!.sequence
        let aspectElapsed = fake.renders.last!.elapsedSeconds
        runtime.setAspectFill(false)
        // The fake records render entry before GPU completion and the status ACK.
        for _ in 0..<100 where fake.fill || fake.renders.last!.sequence == aspectSequence
            || runtime.processStatus?.aspectFill != false {
            try await Task.sleep(for: .milliseconds(5))
        }
        try check(!fake.fill && runtime.processStatus?.aspectFill == false &&
                  fake.renders.last!.elapsedSeconds == aspectElapsed && runtime.activeRuntime == pausedTime &&
                  runtime.state == .paused,
                  "fit mode updates helper and paused pixels at the same elapsed time without stepping the scene")
        runtime.setPaused(false)
        try await Task.sleep(for: .milliseconds(100))
        try check(runtime.activeRuntime > pausedTime && runtime.activeRuntime < pausedTime + 0.25 &&
                  runtime.frameCount > beforePause,
                  "resume continues from active time without adding paused duration")
        fake.holdNextRender = true
        for _ in 0..<100 where fake.heldRender == nil { try await Task.sleep(for: .milliseconds(5)) }
        try check(fake.heldRender != nil, "pause/resume regression holds a real in-flight frame request")
        runtime.setPaused(true)
        runtime.setPaused(false)
        for _ in 0..<100 where runtime.state != .ready || fake.pauses.last != false { try await Task.sleep(for: .milliseconds(5)) }
        let rapidResumeCount = runtime.frameCount
        let pendingFrame = fake.heldRender; fake.heldRender = nil; pendingFrame?.resume()
        try await Task.sleep(for: .milliseconds(180))
        try check(runtime.state == .ready && runtime.frameCount > rapidResumeCount + 1,
                  "resume while a cancelled frame is still draining restarts the continuous Scene loop")
        runtime.setSceneSound(enabled: true, volume: 0.5)
        for _ in 0..<100 where fake.sounds.last?.enabled != true { try await Task.sleep(for: .milliseconds(5)) }
        for _ in 0..<100 where runtime.processStatus?.soundEnabled != true { try await Task.sleep(for: .milliseconds(5)) }
        try check(fake.sounds.last?.enabled == true && fake.sounds.last?.volume == 0.5 &&
                  runtime.processStatus?.soundEnabled == true && runtime.processStatus?.soundVolume == 0.5,
                  "scene sound intent reaches the helper and is verified by the helper's real state")
        runtime.setSceneSound(enabled: false, volume: 0.5)
        try check(zip(fake.renders, fake.renders.dropFirst()).allSatisfy { $0.sequence < $1.sequence } &&
                  fake.acknowledged.map(\.sequence) == fake.renders.prefix(fake.acknowledged.count).map(\.sequence),
                  "frame requests are serialized and acknowledged in strict sequence order")
        let configuredSession = fake.configuration!.sessionID
        let configuredGeneration = fake.configuration!.generation
        let helperInstance = runtime.processStatus!.instanceID
        let runtimeBeforeFPS = runtime.activeRuntime
        for fps in 1...240 { try runtime.setFrameRateLimit(fps) }
        for _ in 0..<100 where fake.fps != 240 { try await Task.sleep(for: .milliseconds(5)) }
        try check(fake.fps == 240 && fake.fpsCalls.count <= 3 &&
                  fake.configuration?.sessionID == configuredSession && fake.configuration?.generation == configuredGeneration &&
                  runtime.processStatus?.instanceID == helperInstance && runtime.processStatus?.frameRateLimit == 240 &&
                  runtime.activeRuntime >= runtimeBeforeFPS,
                  "FPS slider burst coalesces on the same helper session without resetting active time")
        // A slow helper must consume the frame budget rather than add its work
        // to a full 1/FPS sleep. At 20 FPS and 25 ms work the old loop took 75 ms.
        runtime.setPaused(true)
        for _ in 0..<100 where fake.inFlightFrames != 0 { try await Task.sleep(for: .milliseconds(5)) }
        try runtime.setFrameRateLimit(20)
        fake.renderDelay = .milliseconds(25)
        let cadenceStart = fake.renderStarts.count
        runtime.setPaused(false)
        for _ in 0..<300 where fake.renderStarts.count < cadenceStart + 13 {
            try await Task.sleep(for: .milliseconds(5))
        }
        runtime.setPaused(true)
        for _ in 0..<100 where fake.inFlightFrames != 0 { try await Task.sleep(for: .milliseconds(5)) }
        let cadence = Array(fake.renderStarts.dropFirst(cadenceStart).prefix(13))
        try check(cadence.count == 13, "delayed transport produces the cadence measurement frames")
        let intervals = zip(cadence, cadence.dropFirst()).map { first, second -> Double in
            let duration = first.duration(to: second).components
            return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        }
        let cadenceMean = intervals.reduce(0, +) / Double(intervals.count)
        try check(cadenceMean > 0.04 && cadenceMean < 0.065,
                  "25ms transport work at 20 FPS retains about 50ms frame starts instead of 75ms")
        try check(fake.maximumInFlightFrames == 1 && fake.inFlightFrames == 0 &&
                  fake.acknowledged.count == fake.renders.count,
                  "deadline scheduling keeps at most one frame in flight through GPU consumption and ACK")

        // A 1 FPS sleep must wake promptly when the limit rises. Keep the same
        // helper session and real active time through the edit.
        fake.renderDelay = .zero
        try runtime.setFrameRateLimit(1)
        runtime.setPaused(false)
        try await Task.sleep(for: .milliseconds(80))
        let framesBeforeWake = runtime.frameCount
        let wakeStart = ContinuousClock.now
        try runtime.setFrameRateLimit(60)
        for _ in 0..<80 where runtime.frameCount == framesBeforeWake {
            try await Task.sleep(for: .milliseconds(5))
        }
        try check(runtime.frameCount > framesBeforeWake && wakeStart.duration(to: .now) < .milliseconds(300),
                  "FPS increase interrupts a pending one-second sleep without waiting for its old deadline")
        runtime.setPaused(true)
        for _ in 0..<100 where fake.inFlightFrames != 0 { try await Task.sleep(for: .milliseconds(5)) }
        let inputWindow = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 200, height: 200),
            styleMask: [.borderless], backing: .buffered, defer: false)
        inputWindow.isReleasedWhenClosed = false
        runtime.hostView.frame = NSRect(x: 0, y: 0, width: 200, height: 200)
        inputWindow.contentView = runtime.hostView
        let inputPoint = inputWindow.convertPoint(toScreen: NSPoint(x: 100, y: 100))
        runtime.setPaused(false)
        for _ in 0..<100 where runtime.state != .ready { try await Task.sleep(for: .milliseconds(5)) }
        let inputStart = fake.renders.count
        runtime.setPointerButton(down: true, screenPoint: inputPoint)
        runtime.setPointerButton(down: false, screenPoint: inputPoint)
        for _ in 0..<100 where !fake.renders.dropFirst(inputStart).contains(where: \.leftMouseDown) {
            try await Task.sleep(for: .milliseconds(5))
        }
        try check(fake.renders.dropFirst(inputStart).contains { $0.leftMouseDown && $0.cursorX != nil && $0.cursorY != nil },
                  "a desktop press released between frames reaches the helper with mapped host coordinates")
        runtime.setPaused(true)
        runtime.setPointerButton(down: true, screenPoint: inputPoint)
        runtime.setPaused(false)
        let resetStart = fake.renders.count
        try await Task.sleep(for: .milliseconds(70))
        try check(fake.renders.dropFirst(resetStart).allSatisfy { !$0.leftMouseDown },
                  "pause resets pending button input and paused clicks never reappear on resume")
        runtime.setPaused(true)
        inputWindow.contentView = nil
        inputWindow.close()
        try rejects("frame rate outside 1 through 240 rejects") { try runtime.setFrameRateLimit(0) }
        runtime.dispose()
        for _ in 0..<100 where pool.activeLeaseCount != 0 { try await Task.sleep(for: .milliseconds(5)) }
        try check(fake.closed && fake.invalidated && pool.activeLeaseCount == 0,
                  "dispose waits for close and invalidation before returning the service slot")

        let invalidPool = SceneBackendServicePool(), invalid = FakeSceneBackendTransport(); invalid.invalidToken = true
        let invalidRuntime = try UniversalSceneBackendRuntime(projectURL: projectURL,
            screenResolution: .init(x: 4, y: 4), followsHostScreen: false,
            registry: registry, pool: invalidPool, transportFactory: { _ in invalid })
        do { try await invalidRuntime.load(propertiesJSON: payload); throw BackendRuntimeTestFailure(message: "invalid token accepted") }
        catch is BackendRuntimeTestFailure { throw BackendRuntimeTestFailure(message: "invalid token accepted") }
        catch { }
        try check(invalidRuntime.state == .failed && invalid.closed && invalid.invalidated && invalidPool.activeLeaseCount == 0,
                  "generation-mismatched frame fails closed and releases its isolated service")

        let resizePool = SceneBackendServicePool()
        var resizeClients = [FakeSceneBackendTransport]()
        let resizeRuntime = try UniversalSceneBackendRuntime(projectURL: projectURL,
            screenResolution: .init(x: 4, y: 4), followsHostScreen: false,
            registry: registry, pool: resizePool, transportFactory: { _ in
                let value = FakeSceneBackendTransport(); resizeClients.append(value); return value
            })
        try await resizeRuntime.load(propertiesJSON: payload)
        try await resizeRuntime.updateScreenResolutionAndWait(.init(x: 6, y: 5))
        try check(resizeRuntime.screenResolution == .init(x: 6, y: 5) && resizeRuntime.state == .ready &&
                  resizeClients.count == 2 && resizeClients[0].closed && resizeClients[0].invalidated &&
                  resizeClients[1].configuration?.width == 6 && resizeClients[1].configuration?.height == 5 &&
                  resizeClients[1].configuration!.generation > resizeClients[0].configuration!.generation,
                  "screen resolution update serially retires the old generation and prepares the requested size")
        resizeRuntime.dispose()
        for _ in 0..<100 where resizePool.activeLeaseCount != 0 { try await Task.sleep(for: .milliseconds(5)) }

        let unattachedPool = SceneBackendServicePool(), unattached = FakeSceneBackendTransport()
        let unattachedRuntime = try UniversalSceneBackendRuntime(projectURL: projectURL,
            screenResolution: nil, followsHostScreen: true,
            registry: registry, pool: unattachedPool, transportFactory: { _ in unattached })
        try await unattachedRuntime.load(propertiesJSON: payload)
        try check(unattachedRuntime.state == .ready && unattachedRuntime.hostView.window == nil &&
                  unattached.configuration?.width == 1920 && unattached.configuration?.height == 1080,
                  "a follows-host preview prepares offscreen before SwiftUI attaches its host view")
        try await unattachedRuntime.updateScreenResolutionAndWait(.init(x: 6, y: 5))
        try check(unattachedRuntime.state == .ready && unattachedRuntime.screenResolution == .init(x: 6, y: 5),
                  "a later host-screen resolution rebuilds the prepared preview instead of leaving fallback pixels")
        unattachedRuntime.dispose()
        for _ in 0..<100 where unattachedPool.activeLeaseCount != 0 { try await Task.sleep(for: .milliseconds(5)) }

        let capacity = SceneBackendServicePool()
        let leases = try (0..<8).map { _ in try capacity.acquire() }
        try rejects("ninth active runtime is rejected instead of sharing a service process") { _ = try capacity.acquire() }
        leases.forEach { capacity.release($0.0) }
        let retired = try capacity.acquire()
        capacity.release(retired.0, reusable: false)
        let replacement = try capacity.acquire()
        try check(replacement.0 != retired.0,
                  "a service whose process exit was not confirmed is quarantined instead of reused")
        capacity.release(replacement.0)
        let start = ContinuousClock.now
        do {
            let _: Bool = try await SceneBackendTimeout.run(seconds: 0.02) {
                try await Task.sleep(for: .seconds(2)); return true
            }
            throw BackendRuntimeTestFailure(message: "timeout")
        } catch is UniversalSceneBackendError { }
        let elapsed = start.duration(to: .now).components
        try check(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18 < 0.5,
                  "deadline returns without waiting for a noncooperative operation")

        // Real swap-chain regression: headless frame ACKs do not prove that
        // MTKView retires its drawable and presents later scene frames.
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.finishLaunching()
        let presentationView = try SceneBackendMetalHostView.make()
        let presentationWindow = NSWindow(contentRect: .init(x: 80, y: 80, width: 64, height: 64),
            styleMask: .borderless, backing: .buffered, defer: false)
        presentationWindow.isReleasedWhenClosed = false
        presentationWindow.ignoresMouseEvents = true
        presentationWindow.contentView = presentationView
        presentationWindow.orderFrontRegardless()
        var drawables = [ObjectIdentifier]()
        var previousDrawable: AnyObject?
        presentationView.onDrawableForTesting = { identity in
            // Keep the last object alive until the next acquisition. Otherwise
            // the allocator can reuse its address and make fresh drawables look
            // like one cached object even though all frames were presented.
            withExtendedLifetime(previousDrawable) { drawables.append(identity) }
            previousDrawable = presentationView.currentDrawable as AnyObject?
        }
        let presentationSession = UUID()
        for sequence in 1...12 {
            let bytesPerRow = 256
            let io = IOSurface(properties: [.width: 64, .height: 64, .bytesPerElement: 4,
                .bytesPerRow: bytesPerRow, .allocSize: bytesPerRow * 64, .pixelFormat: UInt32(0x4247_5241)])!
            io.lock(options: [], seed: nil)
            let pixels = io.baseAddress.bindMemory(to: UInt32.self, capacity: 64 * 64)
            pixels.update(repeating: sequence.isMultiple(of: 2) ? 0xff00ff00 : 0xffff0000, count: 64 * 64)
            io.unlock(options: [], seed: nil)
            let frame = SceneFrameToken(sessionID: presentationSession, generation: 1, sequence: UInt64(sequence),
                slotID: UUID(), width: 64, height: 64, bytesPerRow: bytesPerRow, pixelFormat: "BGRA8Unorm")
            try await presentationView.consume(surface: io, token: frame)
            try await Task.sleep(for: .milliseconds(40))
        }
        presentationView.onDrawableForTesting = nil
        previousDrawable = nil
        presentationWindow.orderOut(nil); presentationWindow.close()
        try check(drawables.count >= 10 && Set(drawables).count >= 2,
                  "attached Scene view presents successive frames through fresh MTKView drawable cycles (\(drawables.count) presentations, \(Set(drawables).count) drawables)")

        let report: [String: Any] = ["success": true, "checkCount": checks.count, "checks": checks,
                                     "delayedTransportMeanFrameIntervalMilliseconds": cadenceMean * 1_000,
                                     "drawableCycles": drawables.count, "differentDrawables": Set(drawables).count,
                                     "fixtureOnly": true, "realXPCServiceLaunched": false,
                                     "actualSteamCacheRead": false, "cpuFrameReadback": false]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        if let destination = CommandLine.arguments.dropFirst().first {
            try data.write(to: URL(fileURLWithPath: destination), options: .atomic)
        }
        print(String(decoding: data, as: UTF8.self))
    }
}
