import AppKit
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Darwin
import ImageIO
import Observation
import SwiftUI

enum WallpaperBackdropSourceRouting {
    /// A missing assignment on a known screen is meaningful; never borrow another screen's video.
    static func sessionDisplayID(screenIsKnown: Bool, windowDisplayID: String?, primaryDisplayID: String?,
                                 activeSessionDisplayIDs: Set<String>) -> String? {
        let candidate = screenIsKnown ? windowDisplayID : primaryDisplayID
        return candidate.flatMap { activeSessionDisplayIDs.contains($0) ? $0 : nil }
    }
}

enum WallpaperBackdropComposition {
    /// Use only the source's upper-middle slice: 12%...70% measured from the top.
    /// Core Image grows upwards, so the same region starts at 30% from the bottom.
    static func sourceRegion(in extent: CGRect) -> CGRect {
        CGRect(x: extent.minX, y: extent.minY + extent.height * 0.30,
               width: extent.width, height: extent.height * 0.58)
    }
}

enum WallpaperBackdropViewportPolicy {
    static func resolved(probeBounds: CGSize, windowBounds: CGSize) -> CGSize {
        if probeBounds.width.isFinite, probeBounds.height.isFinite,
           probeBounds.width > 0, probeBounds.height > 0 {
            return probeBounds
        }
        if windowBounds.width.isFinite, windowBounds.height.isFinite,
           windowBounds.width > 0, windowBounds.height > 0 {
            return windowBounds
        }
        return .zero
    }
}

struct WallpaperBackdropProbeOwnership<ID: Equatable> {
    private(set) var activeID: ID?

    mutating func claim(_ id: ID) {
        activeID = id
    }

    mutating func release(_ id: ID) -> Bool {
        guard activeID == id else { return false }
        activeID = nil
        return true
    }
}

/// Reads the wallpaper already in use. This view never starts a player or changes assignments.
struct WallpaperWorkspaceBackdrop: View {
    let playback: DesktopPlaybackController
    let displays: DisplayRegistry
    var brightness: Double = 0.28
    var blurAmount: Double = 0.5
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.windowGlassReduceTransparencyOverride) private var reviewReduceTransparency
    @GlassState private var model = WallpaperBackdropModel()

    var body: some View {
        // These reads make assignments and screen hot-plug immediately update the probe.
        let revision = playback.sessions.map { id, session in
            let runtime = session.webRuntime
            let scene = session.sceneRuntime
            let sceneRevision = scene.map { "\(ObjectIdentifier($0)):\($0.state):\($0.posterImage != nil)" } ?? "none"
            return "\(id):\(session.item.id):\(session.item.fileURL.absoluteString):\(runtime.map { String(describing: ObjectIdentifier($0)) } ?? "none"):\(runtime?.state.rawValue ?? "none"):\(sceneRevision)"
        }.sorted().joined()
        let opaque = reduceTransparency || reviewReduceTransparency
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            if !opaque, let image = model.image {
                GeometryReader { proxy in
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        .overlay(Color.black.opacity(max(0, 0.5 - brightness) * 1.5))
                        .overlay(Color.white.opacity(max(0, brightness - 0.5) * 1.5))
                }
                // One continuous atmosphere across the window, with no opaque sidebar plate.
                LinearGradient(
                    colors: colorScheme == .dark
                        ? [Color(red: 0.025, green: 0.065, blue: 0.10).opacity(0.16),
                           Color(red: 0.035, green: 0.045, blue: 0.09).opacity(0.32)]
                        : [.white.opacity(0.02), .white.opacity(0.06)],
                    startPoint: .top, endPoint: .bottom
                )
            }
            WallpaperBackdropWindowProbe(
                model: model, playback: playback, displays: displays,
                reduceTransparency: opaque,
                revision: revision, screenRevision: displays.displays, blurAmount: blurAmount
            )
            // Keep the AppKit probe in the laid-out hierarchy. A zero-area representable can
            // remain detached after a full-height column relayout, leaving no window to probe.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A soft still carries the wallpaper's color across the window; additional blur
/// increases towards the bottom without leaving sharp image detail behind controls.
actor WallpaperBackdropRenderer {
    private let context = CIContext(options: [.cacheIntermediates: false])
    static let maximumDimension = 960

    func render(frame: CGImage?, desktopURL: URL?, transform: CGAffineTransform = .identity,
                viewportSize: CGSize? = nil, blurAmount: Double = 0.5) -> CGImage? {
        autoreleasepool {
            let source: CGImage?
            if let frame {
                source = frame
            } else if let desktopURL,
                      let imageSource = CGImageSourceCreateWithURL(desktopURL as CFURL, nil) {
                source = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: Self.maximumDimension,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true
                ] as CFDictionary)
            } else {
                source = nil
            }
            guard let source else { return nil }
            var input = CIImage(cgImage: source)
            if frame != nil {
                input = input.transformed(by: transform)
                input = input.transformed(by: CGAffineTransform(translationX: -input.extent.minX, y: -input.extent.minY))
            }
            // Crop the actual viewport BEFORE applying the vertical mask. Otherwise aspect-fill
            // of a portrait source in a wide window would crop away both ends of the gradient.
            if let viewportSize, viewportSize.width > 0, viewportSize.height > 0 {
                // Deliberately magnify a partial wallpaper, rather than fitting the full poster.
                // This is geometric upper-middle selection, with no subject detection.
                input = input.cropped(to: WallpaperBackdropComposition.sourceRegion(in: input.extent))
                let aspect = viewportSize.width / viewportSize.height
                let width = min(input.extent.width, input.extent.height * aspect)
                let height = min(input.extent.height, input.extent.width / aspect)
                let crop = CGRect(x: input.extent.midX - width / 2, y: input.extent.midY - height / 2,
                                  width: width, height: height)
                input = input.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            }
            let ratio = min(1, CGFloat(Self.maximumDimension) / max(input.extent.width, input.extent.height))
            if ratio < 1 { input = input.transformed(by: CGAffineTransform(scaleX: ratio, y: ratio)) }
            let extent = input.extent.integral
            let scale = max(extent.width, extent.height) / CGFloat(Self.maximumDimension)
            let amount = blurAmount.isFinite ? min(1, max(0, blurAmount)) : 0.5
            let softened = input.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 40 * amount * scale])
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.9])
            let mask = CIFilter.smoothLinearGradient()
            mask.point0 = CGPoint(x: 0, y: extent.minY)
            mask.point1 = CGPoint(x: 0, y: extent.maxY * 0.55)
            mask.color0 = CIColor(red: 1, green: 1, blue: 1)
            mask.color1 = CIColor(red: 0, green: 0, blue: 0)
            let blur = CIFilter.maskedVariableBlur()
            blur.inputImage = softened
            blur.mask = mask.outputImage?.cropped(to: extent)
            blur.radius = Float(88 * amount * scale)
            guard let output = blur.outputImage else { return nil }
            return context.createCGImage(output.cropped(to: extent), from: extent)
        }
    }
}

/// One poster survives viewport, focus and playback-state changes. Only source replacement,
/// opaque mode or closing releases it. Kept independent so its lifecycle can be tested directly.
struct WallpaperBackdropFrameCache<Frame> {
    private(set) var sourceKey: String?
    var frame: Frame?

    mutating func select(_ key: String) -> Bool {
        guard sourceKey != key else { return false }
        sourceKey = key
        frame = nil
        return true
    }

    mutating func releaseFrame() { frame = nil }
    mutating func reset() { sourceKey = nil; frame = nil }

    mutating func replaceWebSnapshot(_ candidate: Frame, isPainted: Bool) -> Bool {
        guard isPainted else { return false }
        frame = candidate
        return true
    }
}

enum WallpaperBackdropPosterQuality {
    private static let sampleDimension = 24
    private static let minimumVisibleComponent: UInt8 = 16

    /// WebKit can successfully return an opaque black or transparent bitmap while its
    /// document is hidden. Such a bitmap is transport success, not a painted poster.
    static func isPainted(_ image: CGImage) -> Bool {
        metrics(image).map { $0.visiblePixels >= sampleDimension * sampleDimension / 10 && $0.brightest >= minimumVisibleComponent } ?? false
    }

    /// A flat color can be valid authored content when no representative exists.
    /// When a project poster/known library thumbnail is already available, however,
    /// a uniform runtime bitmap is an unpainted HTML body and must not replace it.
    static func shouldReplaceRuntimeSnapshot(_ image: CGImage, hasRepresentative: Bool) -> Bool {
        guard let metrics = metrics(image),
              metrics.visiblePixels >= sampleDimension * sampleDimension / 10,
              metrics.brightest >= minimumVisibleComponent else { return false }
        return !hasRepresentative || metrics.maximumChannelSpan > 4
    }

    private static func metrics(_ image: CGImage) -> (visiblePixels: Int, brightest: UInt8, maximumChannelSpan: UInt8)? {
        let width = sampleDimension
        let height = sampleDimension
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var visiblePixels = 0
        var brightest: UInt8 = 0
        var minima = [UInt8](repeating: .max, count: 3)
        var maxima = [UInt8](repeating: .min, count: 3)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            guard pixels[index + 3] >= minimumVisibleComponent else { continue }
            visiblePixels += 1
            brightest = max(brightest, pixels[index], pixels[index + 1], pixels[index + 2])
            for channel in 0..<3 {
                minima[channel] = min(minima[channel], pixels[index + channel])
                maxima[channel] = max(maxima[channel], pixels[index + channel])
            }
        }
        let span = visiblePixels == 0 ? 0 : zip(minima,maxima).map { $1 &- $0 }.max() ?? 0
        return (visiblePixels,brightest,span)
    }
}

enum WallpaperBackdropPosterPolicy {
    static func seconds(duration: Double) -> Double {
        duration.isFinite && duration > 0 ? min(1, duration * 0.15) : 0
    }
}

/// Creates a representative still once, independent of player time, pause state or frame output.
struct WallpaperBackdropPosterSource: Equatable, Sendable {
    let url: URL
    let isCanonicalWebRepresentative: Bool
}

struct WallpaperBackdropLoadedPoster: @unchecked Sendable {
    let image: CGImage
    let isCanonicalWebRepresentative: Bool
}

struct WallpaperBackdropRepresentativeRequest: Equatable, Sendable {
    enum Kind: String, Sendable {
        case video
        case web
        case scene
        case desktop
    }

    let kind: Kind
    let projectURL: URL?
    let thumbnailURL: URL?
    let fallbackSources: [WallpaperBackdropPosterSource]
}

struct WallpaperBackdropResolvedRepresentatives: Sendable {
    let request: WallpaperBackdropRepresentativeRequest
    let revision: String
    let sources: [WallpaperBackdropPosterSource]
}

/// Resolves project descriptors and representative cover metadata away from the
/// main thread. Each request revalidates file metadata, so an edited project or
/// cover invalidates the cached descriptor without polling.
actor WallpaperBackdropRepresentativeResolver {
    private struct FileStamp: Equatable, Sendable {
        let exists: Bool
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int

        static func read(_ url: URL?) -> FileStamp {
            guard let url else {
                return FileStamp(exists: false, device: 0, inode: 0, size: 0,
                                 modifiedSeconds: 0, modifiedNanoseconds: 0)
            }
            var info = stat()
            guard lstat(url.path, &info) == 0 else {
                return FileStamp(exists: false, device: 0, inode: 0, size: 0,
                                 modifiedSeconds: 0, modifiedNanoseconds: 0)
            }
            return FileStamp(exists: true, device: UInt64(info.st_dev), inode: info.st_ino,
                             size: Int64(info.st_size),
                             modifiedSeconds: info.st_mtimespec.tv_sec,
                             modifiedNanoseconds: info.st_mtimespec.tv_nsec)
        }

        var revisionText: String {
            "\(exists):\(device):\(inode):\(size):\(modifiedSeconds):\(modifiedNanoseconds)"
        }
    }

    private struct CachedWebSource {
        let projectStamp: FileStamp
        let thumbnailStamp: FileStamp
        let posterURL: URL?
        let sources: [WallpaperBackdropPosterSource]
    }

    private struct WebCacheKey: Hashable {
        let projectURL: URL
        let thumbnailURL: URL?
    }

    private var cachedWebSources: [WebCacheKey: CachedWebSource] = [:]

    func resolve(_ request: WallpaperBackdropRepresentativeRequest) async
        -> WallpaperBackdropResolvedRepresentatives {
        guard request.kind == .web, let projectURL = request.projectURL else {
            return .init(request: request, revision: "static", sources: request.fallbackSources)
        }
        let projectStamp = FileStamp.read(projectURL)
        let thumbnailStamp = FileStamp.read(request.thumbnailURL)
        let cacheKey = WebCacheKey(projectURL: projectURL, thumbnailURL: request.thumbnailURL)
        var cached = cachedWebSources[cacheKey]
        if cached?.projectStamp != projectStamp || cached?.thumbnailStamp != thumbnailStamp {
            let descriptor = try? WebWallpaperProjectDescriptor(projectURL: projectURL)
            let poster = descriptor?.posterURL
            var sources: [WallpaperBackdropPosterSource] = []
            if let poster {
                sources.append(.init(url: poster, isCanonicalWebRepresentative: true))
            }
            if let thumbnailURL = request.thumbnailURL, thumbnailStamp.exists {
                sources.append(.init(url: thumbnailURL, isCanonicalWebRepresentative: true))
            }
            cached = CachedWebSource(projectStamp: projectStamp, thumbnailStamp: thumbnailStamp,
                                     posterURL: poster, sources: sources)
            cachedWebSources[cacheKey] = cached
        }
        let posterURL = cached?.posterURL
        let posterStamp = FileStamp.read(posterURL)
        let fallbackRevision = request.fallbackSources.map {
            "\($0.url.absoluteString):\($0.isCanonicalWebRepresentative)"
        }.joined(separator: ",")
        let revision = [
            projectURL.absoluteString, projectStamp.revisionText,
            posterURL?.absoluteString ?? "none", posterStamp.revisionText,
            request.thumbnailURL?.absoluteString ?? "none", thumbnailStamp.revisionText,
            fallbackRevision
        ].joined(separator: "|")
        let representative = cached?.sources ?? []
        return .init(request: request, revision: revision,
                     sources: representative + request.fallbackSources)
    }
}

actor WallpaperBackdropPosterLoader {
    func load(videoURL: URL?, desktopSources: [WallpaperBackdropPosterSource]) async -> WallpaperBackdropLoadedPoster? {
        if let videoURL {
            let asset = AVURLAsset(url: videoURL)
            let duration = (try? await asset.load(.duration))?.seconds ?? 0
            guard !Task.isCancelled else { return nil }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 960, height: 960)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let time = CMTime(seconds: WallpaperBackdropPosterPolicy.seconds(duration: duration), preferredTimescale: 600)
            let frame = try? await VideoProbe.cancellableImage(generator: generator, at: time)
            guard !Task.isCancelled else { return nil }
            return frame.map { WallpaperBackdropLoadedPoster(image:$0,isCanonicalWebRepresentative:false) }
        }
        for source in desktopSources {
            guard !Task.isCancelled else { return nil }
            let frame: CGImage? = autoreleasepool {
                guard let imageSource = CGImageSourceCreateWithURL(source.url as CFURL, nil) else { return nil }
                return CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 960,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true
                ] as CFDictionary)
            }
            if let frame { return .init(image:frame,isCanonicalWebRepresentative:source.isCanonicalWebRepresentative) }
        }
        return nil
    }
}

/// Static first posters cannot depend on WindowServer's advisory occlusion bit. Some
/// ordered-on-screen native windows report only undocumented bits (observed 0x2000).
/// Once a source has a poster, occlusion still defers ordinary viewport re-renders.
enum WallpaperBackdropVisibilityPolicy {
    static func canRender(eligible: Bool, unoccluded: Bool, firstPoster: Bool) -> Bool {
        eligible && (unoccluded || firstPoster)
    }
}

/// Failed snapshots retry only after a real ready transition or visible re-entry.
/// Pausing/playing a ready host and unrelated view updates cannot change a captured poster.
struct WallpaperBackdropWebPosterPolicy {
    private(set) var captured = false
    private var attempted = false
    private var wasReady = false
    private var wasVisible = false
    mutating func update(ready: Bool, visible: Bool) -> Bool {
        defer { wasReady = ready; wasVisible = visible }
        if (!wasReady && ready) || (!wasVisible && visible) { attempted = false }
        guard ready, visible, !captured, !attempted else { return false }
        attempted = true
        return true
    }
    mutating func didCapture() { captured = true }
}

enum WallpaperBackdropWebSourcePolicy {
    static func canAttemptSnapshot(representativeResolved: Bool, ready: Bool, visible: Bool) -> Bool {
        representativeResolved && ready && visible
    }
}

@MainActor
@Observable
final class WallpaperBackdropModel {
    private(set) var image: CGImage?
    private let renderer = WallpaperBackdropRenderer()
    private let loader = WallpaperBackdropPosterLoader()
    private let representativeResolver = WallpaperBackdropRepresentativeResolver()
    private let storage: AppStorage
    private var cache = WallpaperBackdropFrameCache<CGImage>()
    private var sourceTask: Task<Void, Never>?
    private var representativeTask: Task<Void, Never>?
    private var representativeResolution: WallpaperBackdropResolvedRepresentatives?
    private var renderTask: Task<Void, Never>?
    private var webSnapshotTask: Task<Void, Never>?
    private var webPosterPolicy = WallpaperBackdropWebPosterPolicy()
    private var scenePosterCaptured = false
    private var sourceGeneration = 0
    private var sourceRevision: String?
    private var renderGeneration = 0
    private var sourceAttempted = false
    private var representativeResolved = false
    private var hasCanonicalWebRepresentative = false
    private var viewportSize = CGSize.zero
    private var renderedViewport: CGSize?
    private var requestedViewport: CGSize?
    private var visible = false
    private var unoccluded = false
    private var posterNeedsFirstRender = false
    private var blurAmount: Double = 0.5
    private var probeOwnership = WallpaperBackdropProbeOwnership<UUID>()

    init(storage: AppStorage = AppStorage()) {
        self.storage = storage
    }

    func configure(window: NSWindow?, playback: DesktopPlaybackController, displays: DisplayRegistry,
                   reduceTransparency: Bool, blurAmount: Double = 0.5,
                   probeBounds: CGSize = .zero, probeID: UUID? = nil) {
        if let probeID { probeOwnership.claim(probeID) }
        let normalizedBlur = blurAmount.isFinite ? min(1, max(0, blurAmount)) : 0.5
        if self.blurAmount != normalizedBlur {
            self.blurAmount = normalizedBlur
            renderGeneration += 1
            renderTask?.cancel()
            renderTask = nil
            requestedViewport = nil
            renderedViewport = nil
            posterNeedsFirstRender = cache.frame != nil
        }
        let screen = window?.screen
        let number = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        let display = number.flatMap { id in displays.displays.first { $0.displayID == id } }
        let sessionID = WallpaperBackdropSourceRouting.sessionDisplayID(
            screenIsKnown: screen != nil, windowDisplayID: display?.id,
            primaryDisplayID: displays.primary?.id, activeSessionDisplayIDs: Set(playback.sessions.keys)
        )
        let session = sessionID.flatMap { playback.session(for: $0) }
        let videoURL = session?.item.isVideoWallpaper == true ? session?.item.fileURL : nil
        let fallbackScreen = screen ?? displays.primary.flatMap { primary in
            NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == primary.displayID }
        }
        let systemURL = fallbackScreen.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
        let runtime = session?.webRuntime
        let scene = session?.sceneRuntime
        let systemSource = systemURL.map {
            WallpaperBackdropPosterSource(url: $0, isCanonicalWebRepresentative: false)
        }
        let representativeRequest: WallpaperBackdropRepresentativeRequest
        if let item = session?.item, item.isWebWallpaper {
            representativeRequest = .init(
                kind: .web, projectURL: item.fileURL,
                thumbnailURL: storage.thumbnailURL(for: item.id),
                fallbackSources: systemSource.map { [$0] } ?? []
            )
        } else if session?.item.isSceneWallpaper == true {
            // The active Scene host already inspected/rendered its source. Never inspect or
            // decode it again on a window notification just to make an application backdrop.
            representativeRequest = .init(
                kind: .scene, projectURL: nil, thumbnailURL: nil,
                fallbackSources: systemSource.map { [$0] } ?? []
            )
        } else if session == nil {
            representativeRequest = .init(
                kind: .desktop, projectURL: nil, thumbnailURL: nil,
                fallbackSources: systemSource.map { [$0] } ?? []
            )
        } else if session?.item.isVideoWallpaper == true {
            representativeRequest = .init(
                kind: .video, projectURL: nil, thumbnailURL: nil, fallbackSources: []
            )
        } else {
            representativeRequest = .init(
                kind: .scene, projectURL: nil, thumbnailURL: nil,
                fallbackSources: systemSource.map { [$0] } ?? []
            )
        }
        let key = session.map {
            "session:\(sessionID ?? "none"):\($0.item.id):\($0.item.fileURL.absoluteString):\(runtime.map { String(describing: ObjectIdentifier($0)) } ?? "none"):\(scene.map { String(describing: ObjectIdentifier($0)) } ?? "none")"
        } ?? "desktop:\(number.map(String.init) ?? "none"):\(systemURL?.absoluteString ?? "none")"
        if cache.select(key) {
            cancelWork()
            representativeResolution = nil
            sourceRevision = nil
            sourceAttempted = false
            representativeResolved = false
            hasCanonicalWebRepresentative = false
            webPosterPolicy = WallpaperBackdropWebPosterPolicy()
            scenePosterCaptured = false
            posterNeedsFirstRender = false
            image = nil
            renderedViewport = nil
        }
        viewportSize = WallpaperBackdropViewportPolicy.resolved(
            probeBounds: probeBounds,
            windowBounds: window?.contentView?.bounds.size ?? .zero
        )
        visible = window?.isVisible == true && window?.isMiniaturized == false
            && !NSApp.isHidden && !reduceTransparency
        unoccluded = window?.occlusionState.contains(.visible) == true
        // First-source rendering and a one-time Web upgrade are bounded work. Never let a
        // missing advisory bit permanently suppress them in a window the user has opened.
        if !unoccluded && !posterNeedsFirstRender {
            renderGeneration += 1
            renderTask?.cancel()
            renderTask = nil
            requestedViewport = nil
        }
        guard visible else {
            cancelWork()
            if reduceTransparency {
                cache.releaseFrame()
                webPosterPolicy = WallpaperBackdropWebPosterPolicy()
                scenePosterCaptured = false
                posterNeedsFirstRender = false
                sourceAttempted = false
                representativeResolved = false
                hasCanonicalWebRepresentative = false
                image = nil
                renderedViewport = nil
            }
            return
        }
        if !scenePosterCaptured, let frame = scene?.posterImage {
            scenePosterCaptured = true
            renderGeneration += 1
            renderTask?.cancel()
            renderTask = nil
            requestedViewport = nil
            renderedViewport = nil
            cache.frame = frame
            posterNeedsFirstRender = true
        }
        if representativeResolved, let runtime {
            captureWebSnapshotIfNeeded(runtime:runtime,key:key)
        }
        if cache.frame != nil {
            renderIfNeeded()
        }
        if representativeRequest.kind == .web {
            revalidateRepresentatives(request: representativeRequest, key: key,
                                      videoURL: videoURL, runtime: runtime)
        }
        guard cache.frame == nil, !sourceAttempted, sourceTask == nil else { return }
        if representativeResolution?.request == representativeRequest {
            startSourceLoadIfNeeded(request: representativeRequest, key: key,
                                    videoURL: videoURL, runtime: runtime)
        } else {
            revalidateRepresentatives(request: representativeRequest, key: key,
                                      videoURL: videoURL, runtime: runtime)
        }
    }

    func stop(closing: Bool = false, probeID: UUID? = nil) {
        if let probeID, !probeOwnership.release(probeID) { return }
        visible = false
        _ = webPosterPolicy.update(ready: false, visible: false)
        cancelWork()
        if closing {
            cache.reset()
            scenePosterCaptured = false
            posterNeedsFirstRender = false
            webPosterPolicy = WallpaperBackdropWebPosterPolicy()
            sourceAttempted = false
            representativeResolved = false
            hasCanonicalWebRepresentative = false
            image = nil
            renderedViewport = nil
        }
    }

    private func captureWebSnapshotIfNeeded(runtime: WebWallpaperRuntime, key: String) {
        let ready = runtime.state == .ready || runtime.state == .paused
        guard WallpaperBackdropWebSourcePolicy.canAttemptSnapshot(
            representativeResolved:representativeResolved,ready:ready,visible:visible
        ) else { return }
        let shouldSnapshot = webPosterPolicy.update(
            ready:ready, visible:visible)
        guard shouldSnapshot, webSnapshotTask == nil else { return }
        let ticket = sourceGeneration
        webSnapshotTask = Task { [weak self, weak runtime] in
            guard let self, let runtime else { return }
            let frame = try? await runtime.captureStaticPoster()
            guard !Task.isCancelled, self.sourceGeneration == ticket,
                  self.cache.sourceKey == key, self.visible else { return }
            self.webSnapshotTask = nil
            guard let frame,
                  self.cache.replaceWebSnapshot(frame,isPainted:
                    WallpaperBackdropPosterQuality.shouldReplaceRuntimeSnapshot(
                        frame,hasRepresentative:self.hasCanonicalWebRepresentative
                    )) else {
                self.renderIfNeeded()
                return
            }
            self.webPosterPolicy.didCapture()
            self.renderGeneration += 1
            self.renderTask?.cancel(); self.renderTask = nil
            self.requestedViewport = nil; self.renderedViewport = nil
            self.posterNeedsFirstRender = true
            self.renderIfNeeded()
        }
    }

    private func cancelWork() {
        sourceGeneration += 1
        renderGeneration += 1
        if sourceTask != nil { sourceAttempted = false }
        sourceTask?.cancel()
        sourceTask = nil
        webSnapshotTask?.cancel()
        webSnapshotTask = nil
        representativeTask?.cancel()
        representativeTask = nil
        representativeResolution = nil
        renderTask?.cancel()
        renderTask = nil
        requestedViewport = nil
    }

    private func revalidateRepresentatives(
        request: WallpaperBackdropRepresentativeRequest, key: String,
        videoURL: URL?, runtime: WebWallpaperRuntime?
    ) {
        guard representativeTask == nil else { return }
        let ticket = sourceGeneration
        representativeTask = Task { [weak self] in
            guard let self else { return }
            let resolved = await self.representativeResolver.resolve(request)
            guard !Task.isCancelled, self.sourceGeneration == ticket,
                  self.cache.sourceKey == key, self.visible else { return }
            self.representativeTask = nil
            let changed = self.sourceRevision != nil && self.sourceRevision != resolved.revision
            self.representativeResolution = resolved
            self.sourceRevision = resolved.revision
            if changed { self.invalidateResolvedSourceForRevisionChange() }
            guard !self.sourceAttempted, self.sourceTask == nil else { return }
            self.startSourceLoadIfNeeded(request: request, key: key,
                                         videoURL: videoURL, runtime: runtime)
        }
    }

    private func startSourceLoadIfNeeded(
        request: WallpaperBackdropRepresentativeRequest, key: String,
        videoURL: URL?, runtime: WebWallpaperRuntime?
    ) {
        guard !sourceAttempted, sourceTask == nil,
              let resolution = representativeResolution, resolution.request == request else { return }
        sourceAttempted = true
        let ticket = sourceGeneration
        sourceTask = Task { [weak self] in
            guard let self else { return }
            let loaded = await self.loader.load(videoURL: videoURL, desktopSources: resolution.sources)
            guard !Task.isCancelled, self.sourceGeneration == ticket,
                  self.cache.sourceKey == key, self.visible else { return }
            self.sourceTask = nil
            guard !self.webPosterPolicy.captured, !self.scenePosterCaptured else { return }
            self.representativeResolved = true
            self.hasCanonicalWebRepresentative = loaded?.isCanonicalWebRepresentative == true
            self.cache.frame = loaded?.image
            self.posterNeedsFirstRender = loaded != nil
            self.renderIfNeeded()
            if let runtime { self.captureWebSnapshotIfNeeded(runtime:runtime,key:key) }
        }
    }

    private func invalidateResolvedSourceForRevisionChange() {
        sourceGeneration += 1
        sourceTask?.cancel()
        sourceTask = nil
        webSnapshotTask?.cancel()
        webSnapshotTask = nil
        renderTask?.cancel()
        renderTask = nil
        cache.releaseFrame()
        sourceAttempted = false
        representativeResolved = false
        hasCanonicalWebRepresentative = false
        webPosterPolicy = WallpaperBackdropWebPosterPolicy()
        scenePosterCaptured = false
        posterNeedsFirstRender = false
        image = nil
        requestedViewport = nil
        renderedViewport = nil
    }

    private func renderIfNeeded() {
        guard WallpaperBackdropVisibilityPolicy.canRender(eligible: visible, unoccluded: unoccluded,
                                                          firstPoster: posterNeedsFirstRender),
              let frame = cache.frame, let key = cache.sourceKey,
              viewportSize.width > 0, viewportSize.height > 0,
              renderedViewport != viewportSize,
              requestedViewport != viewportSize || renderTask == nil else { return }
        renderGeneration += 1
        let ticket = renderGeneration
        let size = viewportSize
        let amount = blurAmount
        requestedViewport = size
        renderTask?.cancel()
        renderTask = Task { [weak self] in
            guard let self else { return }
            let output = await self.renderer.render(frame: frame, desktopURL: nil, viewportSize: size, blurAmount: amount)
            guard !Task.isCancelled, self.renderGeneration == ticket,
                  self.cache.sourceKey == key, self.visible else { return }
            self.renderTask = nil
            self.requestedViewport = nil
            guard self.viewportSize == size else {
                self.renderIfNeeded()
                return
            }
            if let output {
                self.renderedViewport = size
                self.posterNeedsFirstRender = false
                self.image = output
            }
        }
    }
}

private struct WallpaperBackdropWindowProbe: NSViewRepresentable {
    let model: WallpaperBackdropModel
    let playback: DesktopPlaybackController
    let displays: DisplayRegistry
    let reduceTransparency: Bool
    let revision: String
    let screenRevision: [DisplayDescriptor]
    let blurAmount: Double

    func makeNSView(context: Context) -> ProbeView { ProbeView() }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.configure = { [weak model, weak playback, weak displays, weak view] in
            guard let model, let playback, let displays else { return }
            model.configure(window: view?.window, playback: playback, displays: displays,
                            reduceTransparency: reduceTransparency, blurAmount: blurAmount,
                            probeBounds: view?.bounds.size ?? .zero, probeID: view?.probeID)
        }
        view.detach = { [weak model, weak view] in
            guard let probeID = view?.probeID else { return }
            model?.stop(closing: true, probeID: probeID)
        }
        // Defer state publication out of NSViewRepresentable's SwiftUI update pass.
        view.scheduleRefresh()
    }

    static func dismantleNSView(_ nsView: ProbeView, coordinator: ()) { nsView.cleanUp() }

    final class ProbeView: NSView {
        let probeID = UUID()
        var configure: (() -> Void)?
        var detach: (() -> Void)?
        private var observers: [NSObjectProtocol] = []
        private var pending: Task<Void, Never>?

        func scheduleRefresh() {
            pending?.cancel()
            pending = Task { @MainActor [weak self] in
                await Task.yield()
                guard !Task.isCancelled else { return }
                self?.configure?()
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            guard let window else { detach?(); return }
            let center = NotificationCenter.default
            for name in [NSWindow.didChangeScreenNotification, NSWindow.didChangeOcclusionStateNotification,
                         NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                         NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                         NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification] {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.scheduleRefresh() }
                })
            }
            observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                // A retained NSWindow can reopen. Dismantling the SwiftUI probe owns final cleanup.
                MainActor.assumeIsolated { self?.detach?() }
            })
            for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification,
                         NSApplication.didChangeScreenParametersNotification] {
                observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.scheduleRefresh() }
                })
            }
            scheduleRefresh()
        }

        func cleanUp() {
            pending?.cancel()
            pending = nil
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            detach?()
            configure = nil
            detach = nil
        }
    }
}
