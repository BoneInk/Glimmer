import AppKit
import AVFoundation
import CoreImage
import CoreMedia
import QuartzCore

/// One player/output/display-layer per host surface. Frames stay in memory; no capture files.
/// Remote-context sample-buffer composition follows the system wallpaper pipeline rather
/// than creating an NSWindow in the desktop or login session.
@MainActor
final class GWVideoSurface: GWNativeWallpaperSurface {
    let context: CAContext
    let root = CALayer()
    let layer = AVSampleBufferDisplayLayer()
    private let backing = CALayer()
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private let video: URL
    private(set) var player: AVQueuePlayer
    let assetID: UUID
    private var template: AVPlayerItem
    private var looper: AVPlayerLooper?
    private var output: AVPlayerItemVideoOutput?
    private weak var outputItem: AVPlayerItem?
    private var timer: Timer?
    private var startup: ((Bool) -> Void)?
    private var deadline = Date.distantPast
    private(set) var frameCount = 0
    private(set) var sampledSignatures = Set<UInt64>()
    private(set) var lastBuffer: CVPixelBuffer?
    private var wantsPlayback: Bool
    private var sleeping = false
    private var stopped = false
    private var playing = false
    private var lastFrameTime = CACurrentMediaTime()
    private var recoveryAttempts = 0
    private var sleepObservers = [NSObjectProtocol]()
    private var orientation = CGAffineTransform.identity

    init(config: GWConfiguration, video: URL, request: GWRequest) throws {
        guard CAContext.responds(to: NSSelectorFromString("remoteContext")) else { throw GWError(20, "Remote CAContext is unavailable") }
        let options = request.displayID.map { ["displayId": $0] } ?? [:]
        let raw = options.isEmpty ? CAContext.remoteContext() : CAContext.remoteContext(withOptions: options)
        guard let remote = raw as? CAContext, remote.contextId != 0 else { throw GWError(21, "Could not create wallpaper remote context") }
        context = remote
        assetID = config.assetID
        self.video = video
        template = AVPlayerItem(url: video)
        player = AVQueuePlayer()
        player.isMuted = true
        player.volume = 0
        wantsPlayback = request.shouldPlay
        guard GWUseRemoteVideoComposition(layer) else { throw GWError(22, "Remote video composition SPI is unsupported") }
        root.frame = CGRect(origin: .zero, size: request.size)
        root.contentsScale = request.scale
        root.backgroundColor = NSColor.black.cgColor
        layer.frame = root.bounds
        layer.videoGravity = config.gravity == "fit" ? .resizeAspect : .resizeAspectFill
        backing.contentsGravity = config.gravity == "fit" ? .resizeAspect : .resizeAspectFill
        root.addSublayer(backing)
        root.addSublayer(layer)
        context.layer = root
        CATransaction.flush()
        looper = AVPlayerLooper(player: player, templateItem: template)
        applyGeometry()
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            sleepObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setSleeping(true) }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            sleepObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setSleeping(false) }
            })
        }
    }

    func start(completion: @escaping (Bool) -> Void) {
        guard !stopped, startup == nil, timer == nil else { completion(false); return }
        startup = completion
        deadline = Date().addingTimeInterval(5)
        playing = wantsPlayback && !sleeping
        lastFrameTime = CACurrentMediaTime()
        // A frozen desktop still needs its first real frame. Pause immediately after it lands.
        player.play()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        Task { [weak self] in
            guard let self, let track = try? await self.template.asset.loadTracks(withMediaType: .video).first,
                  let transform = try? await track.load(.preferredTransform), !self.stopped else { return }
            self.orientation = transform
            self.applyGeometry()
        }
    }

    private func tick() {
        guard !stopped else { return }
        if let item = player.currentItem {
            if outputItem !== item {
                if let old = outputItem, let output { old.remove(output) }
                let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int]()])
                item.add(output)
                self.output = output
                outputItem = item
            }
            if let output {
                let time = output.itemTime(forHostTime: CACurrentMediaTime())
                if output.hasNewPixelBuffer(forItemTime: time), let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
                    present(buffer)
                }
            }
        }
        if startup != nil && Date() > deadline {
            let callback = startup; startup = nil
            callback?(false)
            stop()
            return
        }
        // AVPlayer/VideoOutput can remain nominally ready after the media
        // services lose their decoder during a long sleep. Recover even when
        // no failure notification arrives, with bounded retries while visible.
        if startup == nil, playing, CACurrentMediaTime() - lastFrameTime > 3, recoveryAttempts < 3 {
            recoveryAttempts += 1
            lastFrameTime = CACurrentMediaTime()
            holdLastFrame()
            restorePresentation()
            rebuildPlayer()
            player.play()
            GWLog("recovering stalled video context=\(context.contextId) attempt=\(recoveryAttempts)")
        }
    }

    @discardableResult
    private func enqueue(_ buffer: CVPixelBuffer) -> Bool {
        var description: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &description) == noErr,
              let description else { return false }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
                formatDescription: description, sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { return false }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        if layer.sampleBufferRenderer.requiresFlushToResumeDecoding { layer.sampleBufferRenderer.flush() }
        guard layer.sampleBufferRenderer.isReadyForMoreMediaData else { return false }
        layer.sampleBufferRenderer.enqueue(sample)
        return true
    }

    private func present(_ buffer: CVPixelBuffer) {
        guard enqueue(buffer) else { return }
        lastBuffer = buffer
        lastFrameTime = CACurrentMediaTime()
        recoveryAttempts = 0
        frameCount += 1
        if sampledSignatures.count < 12 { sampledSignatures.insert(Self.signature(buffer)) }
        CATransaction.flush()
        if let callback = startup {
            startup = nil
            if !wantsPlayback || sleeping {
                holdLastFrame()
                player.pause(); timer?.invalidate(); timer = nil
            }
            callback(true)
        }
    }

    func update(_ request: GWRequest) {
        guard !stopped else { return }
        root.frame = CGRect(origin: .zero, size: request.size)
        root.contentsScale = request.scale
        applyGeometry()
        wantsPlayback = request.shouldPlay
        reconcilePlayback()
        CATransaction.flush()
    }

    func setSleeping(_ value: Bool) {
        guard !stopped, sleeping != value else { return }
        sleeping = value
        if !value {
            // The compositor may discard its displayed image during sleep.
            // Republish a retained frame even if the host is still inactive.
            restorePresentation()
        }
        reconcilePlayback()
    }

    private func reconcilePlayback() {
        guard !stopped else { return }
        let shouldPlay = wantsPlayback && !sleeping
        let resuming = shouldPlay && !playing
        let pausing = !shouldPlay && playing
        playing = shouldPlay
        if shouldPlay {
            if resuming {
                lastFrameTime = CACurrentMediaTime()
                recoveryAttempts = 0
                restorePresentation()
                detachOutput()
                if player.currentItem == nil || player.status == .failed { rebuildPlayer() }
            }
            player.play()
            if timer == nil {
                timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.tick() }
                }
                if let timer { RunLoop.main.add(timer, forMode: .common) }
            }
        } else if startup == nil {
            if pausing || backing.contents == nil { holdLastFrame() }
            player.pause(); timer?.invalidate(); timer = nil
        }
    }

    private func holdLastFrame() {
        guard let lastBuffer, let image = imageContext.createCGImage(CIImage(cvPixelBuffer: lastBuffer),
            from: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(lastBuffer), height: CVPixelBufferGetHeight(lastBuffer))) else { return }
        // A normal image backing survives a video-renderer flush. Capture only
        // at lifecycle transitions/recovery, never on the per-frame path.
        CATransaction.begin(); CATransaction.setDisableActions(true)
        backing.contents = image
        CATransaction.commit(); CATransaction.flush()
    }

    private func restorePresentation() {
        layer.sampleBufferRenderer.flush(removingDisplayedImage: true)
        if let lastBuffer { enqueue(lastBuffer) }
        CATransaction.flush()
    }

    private func detachOutput() {
        if let output, let outputItem { outputItem.remove(output) }
        output = nil; outputItem = nil
    }

    private func rebuildPlayer() {
        player.pause()
        detachOutput()
        looper?.disableLooping()
        player.removeAllItems()
        template = AVPlayerItem(url: video)
        player = AVQueuePlayer()
        player.isMuted = true; player.volume = 0
        looper = AVPlayerLooper(player: player, templateItem: template)
    }

    private func applyGeometry() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // AVPlayerItemVideoOutput pixels carry natural track orientation. Rotate the display
        // layer for quarter-turn tracks without stretching its aspect-fill content.
        let quarterTurn = abs(orientation.b) > 0.5 && abs(orientation.c) > 0.5
        for output in [backing, layer] {
            output.setAffineTransform(.identity)
            output.bounds = CGRect(origin: .zero, size: quarterTurn ? CGSize(width: root.bounds.height, height: root.bounds.width) : root.bounds.size)
            output.position = CGPoint(x: root.bounds.midX, y: root.bounds.midY)
            output.setAffineTransform(CGAffineTransform(a: orientation.a, b: orientation.b, c: orientation.c, d: orientation.d, tx: 0, ty: 0))
        }
        CATransaction.commit()
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        sleepObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        sleepObservers.removeAll()
        timer?.invalidate(); timer = nil
        player.pause()
        detachOutput()
        looper?.disableLooping(); looper = nil
        player.removeAllItems()
        layer.sampleBufferRenderer.flush(removingDisplayedImage: true)
        layer.removeFromSuperlayer()
        context.layer = nil
        backing.contents = nil
        lastBuffer = nil
        let callback = startup; startup = nil
        callback?(false)
        CATransaction.flush()
    }

    private static func signature(_ buffer: CVPixelBuffer) -> UInt64 {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0 }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let length = CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer)
        var hash: UInt64 = 1469598103934665603
        for index in stride(from: 0, to: length, by: max(1, length / 1024)) { hash = (hash ^ UInt64(bytes[index])) &* 1099511628211 }
        return hash
    }
}
