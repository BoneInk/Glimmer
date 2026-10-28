import AppKit
import CoreVideo
import WebKit

/// Live WebKit composition and bounded OS snapshots are separate operations.
/// The page runs its native rendering loop, with no per-frame JS IPC/readback.
@MainActor
final class GWWebLayerSurface: GWNativeWallpaperSurface {
    let context: CAContext
    let assetID: UUID
    let root = CALayer()
    let recipe: LiveWallpaperRecipe
    private let directory: URL
    private var request: GWRequest
    private var sleeping = false
    private var stopped = false
    private var revision: UInt64 = 0
    private var operation: Task<Void, Never>?
    private var startup: ((Bool) -> Void)?
    private var observers = [NSObjectProtocol]()
    private var captureTask: Task<Void, Error>?
    private var captureID = UUID()
    private var documentReady = false
    private var document = UUID()
    private var cachedImage: CGImage?
    private var renderingActivity: NSObjectProtocol?
    private var recoveryAttempts = 0
    private var recoveryExhausted = false
    private(set) var recoveryCount = 0
#if GW_DIAGNOSTIC_ENTRY
    var preparationFailuresForTesting = 0
#endif
    private(set) var lastBuffer: CVPixelBuffer?
    private(set) var runtime: WebWallpaperRuntime?
    private(set) var host: GWWebRenderHost?
    private(set) var lastError: String?
    private(set) var snapshotCount = 0
    private(set) var documentCount = 0
    var isReady: Bool { lastBuffer != nil && lastError == nil }
    var isPlaying: Bool { documentReady && runtime?.state == .ready && host?.isExported == true && wantsPlayback }
    var isReconciling: Bool { operation != nil }
    private var wantsPlayback: Bool {
        request.shouldPlay && !sleeping && (request.displayID.map { CGDisplayIsAsleep($0) == 0 } ?? true)
    }

    init(config: GWConfiguration, directory: URL, recipe: LiveWallpaperRecipe, request: GWRequest) throws {
        guard recipe.kind == .web, recipe.assetID == config.assetID,
              let context = (request.displayID.map { CAContext.remoteContext(withOptions: ["displayId": $0]) }
                ?? CAContext.remoteContext()) as? CAContext, context.contextId != 0 else {
            throw GWError(82, "Live Web composition is unavailable")
        }
        self.context = context; assetID = config.assetID
        self.directory = directory; self.recipe = recipe; self.request = request
        root.backgroundColor = NSColor.black.cgColor
        root.masksToBounds = true
        root.contentsGravity = config.gravity == "fit" ? .resizeAspect : .resizeAspectFill
        context.layer = root
        layout()
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setSleeping(true) }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setSleeping(false) }
            })
        }
    }

    func start(completion: @escaping (Bool) -> Void) {
        guard !stopped, startup == nil, operation == nil, !isReady else { completion(false); return }
        startup = completion
        reconcile()
    }

    func update(_ request: GWRequest) {
        guard !stopped else { return }
        let wasPlaying = wantsPlayback
        self.request = request
        if !wasPlaying, wantsPlayback { resetRecovery() }
        layout()
        reconcile()
    }

    func setSleeping(_ value: Bool) {
        guard !stopped else { return }
        sleeping = value
        // A system/dark wake can precede display wake. Always reconcile the
        // latter even if both notifications carry the same awake value.
        if !value { resetRecovery() }
        reconcile()
    }

    private func resetRecovery() {
        recoveryAttempts = 0
        recoveryExhausted = false
    }

    private func layout() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        root.frame = CGRect(origin: .zero, size: request.size)
        root.contentsScale = request.scale
        host?.resize(to: request.size)
        if let runtime {
            _ = GWSetWebDeviceScale(runtime.webView, renderScale)
        }
        CATransaction.commit(); CATransaction.flush()
    }

    private var renderScale: Double {
        min(Double(request.scale), Double(recipe.width) / request.size.width,
            Double(recipe.height) / request.size.height)
    }

    private func reconcile() {
        revision &+= 1
        guard operation == nil else { return }
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { operation = nil }
            while !stopped, !Task.isCancelled {
                do {
                    if recoveryExhausted, wantsPlayback { return }
                    let current = revision
                    if let runtime, runtime.state == .failed {
                        throw GWError(89, runtime.lastError ?? "Web content process failed")
                    }
                    // The OS also needs an initial held frame for an inactive
                    // acquisition. Prepare it once, then release the document.
                    if wantsPlayback || lastBuffer == nil {
                        if runtime == nil { try await prepareDocument() }
                        if stopped { return }
                        if !wantsPlayback { releaseDocument() }
                    } else if runtime != nil {
                        // At most one readback on a visibility transition.
                        // A failed refresh keeps the already validated backing.
                        _ = try? await snapshot()
                        if !wantsPlayback { releaseDocument() }
                    }
                    if let completion = startup, isReady {
                        startup = nil; completion(true)
                    }
                    if current == revision { return }
                } catch is CancellationError { return }
                catch {
                    guard !stopped, !Task.isCancelled else { return }
                    lastError = error.localizedDescription
                    GWLog("Web layer failed: \(error.localizedDescription)")
                    // Remove the failed live tree immediately to expose the
                    // retained image, without invalidating the remote context.
                    releaseDocument()
                    guard lastBuffer != nil else {
                        let completion = startup; startup = nil; completion?(false)
                        return
                    }
                    guard wantsPlayback else { return }
                    guard recoveryAttempts < 3 else { recoveryExhausted = true; return }
                    recoveryAttempts += 1
                    recoveryCount += 1
                    GWLog("recovering Web layer context=\(context.contextId) attempt=\(recoveryAttempts)")
                    do { try await Task.sleep(for: .milliseconds(500 * (1 << (recoveryAttempts - 1)))) }
                    catch { return }
                    // Recheck visibility after the delay; a sleep/update may
                    // have arrived while this operation was waiting.
                }
            }
        }
    }

    private func prepareDocument() async throws {
#if GW_DIAGNOSTIC_ENTRY
        if preparationFailuresForTesting > 0 {
            preparationFailuresForTesting -= 1
            throw GWError(98, "Injected Web preparation failure")
        }
#endif
        // The remotely visible layer has no ordered AppKit window. Tell the
        // OS that this process is doing visible work, while still allowing
        // normal idle system sleep. End the activity with the document.
        renderingActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Rendering a visible native Web wallpaper surface")
        let project = directory.appendingPathComponent("project")
        let runtime = try WebWallpaperRuntime(projectURL: project.appendingPathComponent("project.json"),
            entryURL: project.appendingPathComponent(recipe.entryFile!), propertiesJSON: recipe.propertiesJSON,
            allowHTTPS: recipe.allowHTTPS, mutedPlayback: true, toleratesBlockedHTTPS: true,
            animationFrameRateLimit: recipe.fps, remoteLayerRendering: true)
        self.runtime = runtime
        runtime.failureHandler = { [weak self, weak runtime] _ in
            guard let self, let runtime, self.runtime === runtime, !self.stopped else { return }
            self.reconcile()
        }
        document = UUID(); let token = document
        documentCount += 1
        runtime.webView.frame = CGRect(origin: .zero, size: request.size)
        guard GWSetWebDeviceScale(runtime.webView, renderScale) else { throw GWError(83, "Web device scale is unavailable") }
        let host = GWWebRenderHost(webView: runtime.webView)
        self.host = host
        try runtime.setFrameRateLimit(recipe.fps)
        runtime.load()
        let deadline = ContinuousClock.now + .seconds(15)
        while runtime.state != .ready {
            try Task.checkCancellation()
            guard !stopped, document == token, runtime.state != .failed, ContinuousClock.now < deadline else {
                throw GWError(84, runtime.lastError ?? "Web layer did not become ready")
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        let presentation = SceneBackendDeadlineRace<Bool>()
        GWAfterWebPresentation(runtime.webView) { presentation.finish(.success($0)) }
        guard try await presentation.wait(seconds: 5), !stopped, document == token else {
            throw GWError(85, "WebKit did not commit its first presentation")
        }
        try host.export(to: root)
        _ = try await snapshot()
        guard !stopped, document == token, host.isExported else { throw CancellationError() }
        guard runtime.state != .failed else { throw GWError(89, runtime.lastError ?? "Web content process failed") }
        // A remote compositor layer covers the held backing as soon as it is
        // ready; that backing remains available for OS snapshots and teardown.
        lastError = nil
        documentReady = true
        GWLog("Web layer ready context=\(context.contextId) documents=\(documentCount) snapshots=\(snapshotCount)")
    }

    func snapshot() async throws -> CVPixelBuffer? {
        if let captureTask { try await captureTask.value; return lastBuffer }
        guard !stopped, let runtime else { return lastBuffer }
        let token = document
        let id = UUID(); captureID = id
        let task = Task { @MainActor [weak self] () throws -> Void in
            guard let self else { throw CancellationError() }
            let race = SceneBackendDeadlineRace<NSImage>()
            let config = WKSnapshotConfiguration()
            config.rect = runtime.webView.bounds
            // snapshotWidth is in window points, not output pixels.
            config.snapshotWidth = NSNumber(value: Double(recipe.width) / max(1, host?.window.backingScaleFactor ?? 1))
            config.afterScreenUpdates = true
            snapshotCount += 1
            runtime.webView.takeSnapshot(with: config) { image, error in
                if let image { race.finish(.success(image)) }
                else { race.finish(.failure(error ?? GWError(86, "Web snapshot is unavailable"))) }
            }
            let image = try await race.wait(seconds: 5)
            guard !stopped, document == token,
                  let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw CancellationError() }
            var value: CVPixelBuffer?
            let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
            guard CVPixelBufferCreate(nil, recipe.width, recipe.height, kCVPixelFormatType_32BGRA,
                attributes as CFDictionary, &value) == kCVReturnSuccess, let value else { throw GWError(87, "Web snapshot allocation failed") }
            CVPixelBufferLockBaseAddress(value, [])
            defer { CVPixelBufferUnlockBaseAddress(value, []) }
            guard let bitmap = CGContext(data: CVPixelBufferGetBaseAddress(value), width: recipe.width, height: recipe.height,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(value), space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else {
                throw GWError(88, "Web snapshot bitmap failed")
            }
            bitmap.draw(cg, in: CGRect(x: 0, y: 0, width: recipe.width, height: recipe.height))
            lastBuffer = value; cachedImage = cg; root.contents = cg
        }
        captureTask = task
        defer { if captureID == id { captureTask = nil } }
        try await task.value
        return lastBuffer
    }

    private func releaseDocument() {
        document = UUID()
        documentReady = false
        captureID = UUID()
        captureTask?.cancel(); captureTask = nil
        let runtime = runtime
        self.runtime = nil
        runtime?.failureHandler = nil
        host?.close(); host = nil
        runtime?.dispose()
        if let runtime { GWCloseWebPage(runtime.webView) }
        if let activity = renderingActivity { ProcessInfo.processInfo.endActivity(activity) }
        renderingActivity = nil
        CATransaction.flush()
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        operation?.cancel(); operation = nil
        releaseDocument()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        root.contents = nil; cachedImage = nil; lastBuffer = nil; context.layer = nil
        let completion = startup; startup = nil; completion?(false)
        CATransaction.flush()
    }
}
