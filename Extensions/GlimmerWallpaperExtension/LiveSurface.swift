import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import IOSurface
@preconcurrency import Metal
import WebKit

@MainActor
protocol GWNativeWallpaperSurface: AnyObject {
    var context: CAContext { get }
    var assetID: UUID { get }
    var lastBuffer: CVPixelBuffer? { get }
    func snapshot() async throws -> CVPixelBuffer?
    func start(completion: @escaping (Bool) -> Void)
    func update(_ request: GWRequest)
    func setSleeping(_ value: Bool)
    func stop()
}

extension GWNativeWallpaperSurface {
    func snapshot() async throws -> CVPixelBuffer? { lastBuffer }
}

@MainActor
func GWMakeNativeWallpaperSurface(config: GWConfiguration, url: URL, request: GWRequest) async throws -> any GWNativeWallpaperSurface {
    guard config.liveDirectoryName != nil else { return try GWVideoSurface(config: config, video: url, request: request) }
    let recipe = try await Task.detached(priority: .userInitiated) { try LiveWallpaperBundle.load(url) }.value
    guard recipe.assetID == config.assetID else { throw GWError(51, "Live wallpaper revision changed") }
    if recipe.kind == .web { return try GWWebLayerSurface(config: config, directory: url, recipe: recipe, request: request) }
    return try GWLiveSurface(config: config, directory: url, request: request, recipe: recipe)
}

/// An independently owned Scene helper feeds the native remote context.
@MainActor
final class GWLiveSurface: GWNativeWallpaperSurface {
    private static let pool = SceneBackendServicePool(serviceNames: (0..<8).map { "com.boneink.Glimmer.LockScreenScene.slot\($0)" })
    let context: CAContext
    let root = CALayer()
    let layer = AVSampleBufferDisplayLayer()
    let assetID: UUID
    private let directory: URL
    private var request: GWRequest
    private(set) var recipe: LiveWallpaperRecipe?
    private(set) var frameCount = 0
    private(set) var lastBuffer: CVPixelBuffer?
    private(set) var lastError: String?
    private(set) var failureDetail: SceneBackendFailureDetail?
    private(set) var helperPID: Int32?
    private let preparedRecipe: LiveWallpaperRecipe?
    private var client: SceneBackendXPCClient?
    private var lease: Int?
    private let sessionID = UUID()
    private var sequence: UInt64 = 0
    private var framePool: CVPixelBufferPool?
    private let device: MTLDevice
    private let commands: MTLCommandQueue
    private var loop: Task<Void, Never>?
    private var startup: ((Bool) -> Void)?
    private var stopped = false
    private var sleeping = false
    private var sleepObservers = [NSObjectProtocol]()

    init(config: GWConfiguration, directory: URL, request: GWRequest, recipe: LiveWallpaperRecipe? = nil) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let commands = device.makeCommandQueue(),
              let context = (request.displayID.map { CAContext.remoteContext(withOptions: ["displayId": $0]) }
                ?? CAContext.remoteContext()) as? CAContext, context.contextId != 0,
              GWUseRemoteVideoComposition(layer) else { throw GWError(50, "Live wallpaper composition is unavailable") }
        self.device = device; self.commands = commands; self.context = context
        self.directory = directory; self.request = request; assetID = config.assetID
        preparedRecipe = recipe
        root.backgroundColor = NSColor.black.cgColor
        layer.videoGravity = config.gravity == "fit" ? .resizeAspect : .resizeAspectFill
        root.addSublayer(layer); context.layer = root
        update(request)
        for notification in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            sleepObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: notification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setSleeping(true) }
            })
        }
        for notification in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            sleepObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: notification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setSleeping(false) }
            })
        }
    }

    func start(completion: @escaping (Bool) -> Void) {
        guard loop == nil, !stopped else { completion(false); return }
        startup = completion
        loop = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let directory = directory
                let recipe = if let preparedRecipe { preparedRecipe }
                    else { try await Task.detached(priority: .userInitiated) { try LiveWallpaperBundle.load(directory) }.value }
                try Task.checkCancellation()
                guard recipe.assetID == assetID, recipe.kind == .scene, !stopped else { throw GWError(51, "Scene wallpaper revision changed") }
                self.recipe = recipe
                try createFramePool(recipe)
                try await prepareScene(recipe)
                var lastTick: ContinuousClock.Instant?, elapsed = 0.0, sentPaused: Bool?
                while !stopped, !Task.isCancelled {
                    let playing = request.shouldPlay && !sleeping
                        && (request.displayID.map { CGDisplayIsAsleep($0) == 0 } ?? true)
                    let paused = frameCount > 0 && !playing
                    if sentPaused != paused {
                        try await client?.setPaused(paused)
                        sentPaused = paused
                        lastTick = nil
                    }
                    if !paused {
                        let now = ContinuousClock.now
                        if let lastTick { elapsed += Self.seconds(lastTick.duration(to: now)) }
                        lastTick = now
                        let buffer: CVPixelBuffer
                        guard let client else { throw GWError(52, "Live Scene helper is unavailable") }
                        buffer = try await sceneFrame(client, recipe: recipe, elapsed: elapsed)
                        guard !stopped, !Task.isCancelled else { break }
                        if frameCount > 0, !request.shouldPlay || sleeping { continue }
                        if present(buffer) {
                            frameCount += 1
                            if let completion = startup { startup = nil; completion(true) }
                        }
                    }
                    try await Task.sleep(for: paused ? .milliseconds(100) : .seconds(1 / Double(recipe.fps)))
                }
            } catch is CancellationError { }
            catch {
                lastError = error.localizedDescription
                failureDetail = (error as? SceneBackendWireFailure)?.detail
                GWLog("live wallpaper failed: \(error.localizedDescription)")
                stop()
            }
        }
    }

    private func prepareScene(_ recipe: LiveWallpaperRecipe) async throws {
        let acquired = try Self.pool.acquire(); lease = acquired.0
        let connection = SceneBackendXPCClient(serviceName: acquired.1)
        client = connection
        let status = try await connection.status()
        guard status.ownsSession else { throw GWError(52, "Live Scene helper is already owned") }
        helperPID = status.helperPID
        // The helper has its own identity and cannot use another app's private
        // container. The application creates these explicit private cache roots;
        // the extension keeps read-only access to the shared project tree.
        let base = directory.deletingLastPathComponent()
            .appendingPathComponent("SceneCaches/" + assetID.uuidString + "/slot\(acquired.0)")
        let roots = SceneBackendRoots(projectRoot: directory.appendingPathComponent("project"),
            assetsRoot: directory.appendingPathComponent("assets"), cacheRoot: base,
            projectDigest: recipe.projectDigest, assetsManifestDigest: recipe.assetsManifestDigest)
        let configuration = SceneBackendConfiguration(protocolVersion: 1, sessionID: sessionID,
            generation: 1, roots: roots, width: recipe.width, height: recipe.height,
            framesPerSecond: recipe.fps, properties: recipe.sceneProperties)
        let ready = try await connection.prepare(configuration)
        guard ready.isStrictlyReady, ready.sessionID == sessionID, ready.generation == 1,
              ready.projectDigest == recipe.projectDigest, ready.assetsManifestDigest == recipe.assetsManifestDigest else {
            throw GWError(53, "Live Scene did not complete strict preparation")
        }
        try await connection.setSceneSound(enabled: false, volume: 0)
        try await connection.setAspectFill(true)
        connection.invalidationHandler = { [weak self] in
            guard let self, !stopped else { return }
            lastError = "Live Scene helper disconnected"; stop()
        }
    }

    private func sceneFrame(_ client: SceneBackendXPCClient, recipe: LiveWallpaperRecipe, elapsed: Double) async throws -> CVPixelBuffer {
        sequence += 1
        let (token, surface) = try await client.render(.init(sessionID: sessionID, generation: 1,
            sequence: sequence, elapsedSeconds: elapsed, cursorX: nil, cursorY: nil, leftMouseDown: false))
        guard token.sessionID == sessionID, token.generation == 1, token.sequence == sequence,
              token.width == recipe.width, token.height == recipe.height, token.pixelFormat == "BGRA8Unorm",
              IOSurfaceGetWidth(surface) == recipe.width, IOSurfaceGetHeight(surface) == recipe.height,
              IOSurfaceGetBytesPerRow(surface) == token.bytesPerRow,
              IOSurfaceGetPixelFormat(surface) == kCVPixelFormatType_32BGRA else { throw GWError(54, "Invalid live Scene surface") }
        let buffer = try allocateFrame()
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: recipe.width, height: recipe.height, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = [.shaderRead, .shaderWrite]
        guard let destination = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue(),
              let source = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0),
              let target = device.makeTexture(descriptor: descriptor, iosurface: destination, plane: 0),
              let command = commands.makeCommandBuffer(), let blit = command.makeBlitCommandEncoder() else {
            throw GWError(55, "Cannot retain live Scene frame")
        }
        blit.copy(from: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(x: 0, y: 0, z: 0),
            sourceSize: .init(width: recipe.width, height: recipe.height, depth: 1), to: target,
            destinationSlice: 0, destinationLevel: 0, destinationOrigin: .init(x: 0, y: 0, z: 0))
        blit.endEncoding()
        let completed = await withCheckedContinuation { continuation in
            command.addCompletedHandler { continuation.resume(returning: $0.status == .completed) }
            command.commit()
        }
        // The display layer only receives an extension-owned copy. Release the
        // helper's slot after GPU completion, never while it is still displayed.
        try await client.acknowledge(token)
        guard completed else { throw GWError(56, "Live Scene GPU copy failed") }
        return buffer
    }

    private func createFramePool(_ recipe: LiveWallpaperRecipe) throws {
        let attributes: [String: Any] = [kCVPixelBufferWidthKey as String: recipe.width,
            kCVPixelBufferHeightKey as String: recipe.height, kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:], kCVPixelBufferMetalCompatibilityKey as String: true]
        guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &framePool) == kCVReturnSuccess else { throw GWError(62, "Cannot allocate live frame pool") }
    }
    private func allocateFrame() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        guard let framePool,
              CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, framePool,
                [kCVPixelBufferPoolAllocationThresholdKey: 6] as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { throw GWError(63, "Live frame pool exhausted") }
        return buffer
    }
    private func present(_ buffer: CVPixelBuffer) -> Bool {
        var format: CMVideoFormatDescription?, sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format) == noErr,
              let format, CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer,
                formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { return false }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        if layer.sampleBufferRenderer.requiresFlushToResumeDecoding { layer.sampleBufferRenderer.flush() }
        guard layer.sampleBufferRenderer.isReadyForMoreMediaData else { return false }
        layer.sampleBufferRenderer.enqueue(sample)
        lastBuffer = buffer; CATransaction.flush(); return true
    }

    func update(_ request: GWRequest) {
        self.request = request
        CATransaction.begin(); CATransaction.setDisableActions(true)
        root.frame = .init(origin: .zero, size: request.size); root.contentsScale = request.scale
        layer.frame = root.bounds
        CATransaction.commit(); CATransaction.flush()
    }
    func setSleeping(_ value: Bool) { sleeping = value }
    func stop() {
        guard !stopped else { return }
        stopped = true; loop?.cancel(); loop = nil
        for observer in sleepObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        sleepObservers.removeAll()
        let client = client, lease = lease, pid = helperPID, session = sessionID
        self.client = nil; self.lease = nil
        client?.invalidationHandler = nil
        Task { @MainActor in
            await client?.close(sessionID: session, generation: 1)
            await client?.invalidateAndWait()
            let reusable = if let pid { await SceneBackendProcessExit.wait(pid: pid) } else { client == nil }
            if let lease { Self.pool.release(lease, reusable: reusable) }
        }
        layer.sampleBufferRenderer.flush(removingDisplayedImage: true)
        layer.removeFromSuperlayer(); context.layer = nil; lastBuffer = nil; framePool = nil
        let completion = startup; startup = nil; completion?(false)
        CATransaction.flush()
    }
    private static func seconds(_ duration: Duration) -> Double {
        let value = duration.components
        return Double(value.seconds) + Double(value.attoseconds) / 1e18
    }
}
