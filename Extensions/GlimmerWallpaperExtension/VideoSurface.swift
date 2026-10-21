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
    let player: AVQueuePlayer
    let assetID: UUID
    private let template: AVPlayerItem
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
    private var stopped = false
    private var orientation = CGAffineTransform.identity

    init(config: GWConfiguration, video: URL, request: GWRequest) throws {
        guard CAContext.responds(to: NSSelectorFromString("remoteContext")) else { throw GWError(20, "Remote CAContext is unavailable") }
        let options = request.displayID.map { ["displayId": $0] } ?? [:]
        let raw = options.isEmpty ? CAContext.remoteContext() : CAContext.remoteContext(withOptions: options)
        guard let remote = raw as? CAContext, remote.contextId != 0 else { throw GWError(21, "Could not create wallpaper remote context") }
        context = remote
        assetID = config.assetID
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
        root.addSublayer(layer)
        context.layer = root
        CATransaction.flush()
        looper = AVPlayerLooper(player: player, templateItem: template)
    }

    func start(completion: @escaping (Bool) -> Void) {
        startup = completion
        deadline = Date().addingTimeInterval(5)
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
        }
    }

    private func present(_ buffer: CVPixelBuffer) {
        var description: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &description) == noErr,
              let description else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
                formatDescription: description, sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        if layer.sampleBufferRenderer.requiresFlushToResumeDecoding { layer.sampleBufferRenderer.flush() }
        guard layer.sampleBufferRenderer.isReadyForMoreMediaData else { return }
        layer.sampleBufferRenderer.enqueue(sample)
        lastBuffer = buffer
        frameCount += 1
        if sampledSignatures.count < 12 { sampledSignatures.insert(Self.signature(buffer)) }
        CATransaction.flush()
        if let callback = startup {
            startup = nil
            if !wantsPlayback { player.pause(); timer?.invalidate(); timer = nil }
            callback(true)
        }
    }

    func update(_ request: GWRequest) {
        guard !stopped else { return }
        root.frame = CGRect(origin: .zero, size: request.size)
        root.contentsScale = request.scale
        applyGeometry()
        wantsPlayback = request.shouldPlay
        if wantsPlayback {
            player.play()
            if timer == nil {
                timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.tick() }
                }
                if let timer { RunLoop.main.add(timer, forMode: .common) }
            }
        } else if startup == nil {
            player.pause(); timer?.invalidate(); timer = nil
        }
        CATransaction.flush()
    }

    private func applyGeometry() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // AVPlayerItemVideoOutput pixels carry natural track orientation. Rotate the display
        // layer for quarter-turn tracks without stretching its aspect-fill content.
        let quarterTurn = abs(orientation.b) > 0.5 && abs(orientation.c) > 0.5
        layer.setAffineTransform(.identity)
        layer.bounds = CGRect(origin: .zero, size: quarterTurn ? CGSize(width: root.bounds.height, height: root.bounds.width) : root.bounds.size)
        layer.position = CGPoint(x: root.bounds.midX, y: root.bounds.midY)
        layer.setAffineTransform(CGAffineTransform(a: orientation.a, b: orientation.b, c: orientation.c, d: orientation.d, tx: 0, ty: 0))
        CATransaction.commit()
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        timer?.invalidate(); timer = nil
        player.pause()
        if let output, let outputItem { outputItem.remove(output) }
        output = nil; outputItem = nil
        looper?.disableLooping(); looper = nil
        player.removeAllItems()
        layer.sampleBufferRenderer.flush(removingDisplayedImage: true)
        layer.removeFromSuperlayer()
        context.layer = nil
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
