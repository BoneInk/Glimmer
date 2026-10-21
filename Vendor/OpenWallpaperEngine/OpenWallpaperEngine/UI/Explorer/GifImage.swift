//
//  GifImage.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/15.
//

import Cocoa
import SwiftUI
import ImageIO

struct GifImage: NSViewRepresentable {
    private static let imageCache = NSCache<NSString, StillImage>()

    var gifName: String?
    var gifUrl: URL?

    var isResizable: Bool = false
    var contentMode: ContentMode = .fill

    var animates: Bool

    final class Coordinator {
        var loadedKey: String?
        var loadingKey: String?
    }

    init(_ gifName: String, animates: Bool = true) {
        self.gifName = gifName
        self.animates = animates
    }

    init(contentsOf url: URL, animates: Bool = true) {
        self.gifUrl = url
        self.animates = animates
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> PreviewImageView {
        let nsView = PreviewImageView()
        nsView.fills = contentMode == .fill
        nsView.wantsAnimation = animates

        loadImage(into: nsView, coordinator: context.coordinator)

        return nsView
    }

    func updateNSView(_ nsView: PreviewImageView, context: Context) {
        nsView.fills = contentMode == .fill
        nsView.wantsAnimation = animates
        loadImage(into: nsView, coordinator: context.coordinator)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PreviewImageView, context: Context) -> CGSize? {
        if !self.isResizable {
            return nsView.still.map { CGSize(width: $0.width, height: $0.height) }
        } else {
            guard let width = proposal.width, let height = proposal.height else { return nil }
            return CGSize(width: width, height: height)
        }
    }

    /// Loads the downsampled still the view shows until (and unless) it plays; a playing view
    /// decodes its frames itself (`PreviewFrameSequence`).
    private func loadImage(into nsView: PreviewImageView, coordinator: Coordinator) {
        let url = gifUrl ?? gifName.flatMap { AppBundleLayout.framework.url(forResource: $0, withExtension: "gif") }
        guard let url else { return }
        nsView.animationURL = url
        let key = Self.stillKey(url)
        guard coordinator.loadedKey != key else { return }
        if let cached = Self.imageCache.object(forKey: key as NSString) {
            nsView.still = cached.image
            coordinator.loadedKey = key
            coordinator.loadingKey = nil
            return
        }
        guard coordinator.loadingKey != key else { return }
        coordinator.loadingKey = key
        DispatchQueue.global(qos: .userInitiated).async {
            guard let image = Self.downsampledImage(at: url, maxPixelSize: 512) else { return }
            Self.imageCache.setObject(StillImage(image: image), forKey: key as NSString)
            DispatchQueue.main.async {
                guard coordinator.loadingKey == key else { return }
                nsView.still = image
                coordinator.loadedKey = key
                coordinator.loadingKey = nil
            }
        }
    }

    /// The downsampled still a tile shows for `url`: the one already loaded, else read now and
    /// kept for the tiles. For a few pictures at once, such as a drag's image.
    static func still(at url: URL) -> CGImage? {
        let key = Self.stillKey(url)
        if let cached = imageCache.object(forKey: key as NSString) { return cached.image }
        guard let image = downsampledImage(at: url, maxPixelSize: 512) else { return nil }
        imageCache.setObject(StillImage(image: image), forKey: key as NSString)
        return image
    }

    /// The cache key of `url`'s still: its path and modification date, so a preview the Wallpaper
    /// Editor writes again under the same name (`preview.jpg`) shows the new picture.
    private static func stillKey(_ url: URL) -> String {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate // Optional: a missing file has no date.
        return url.path + "#" + String(modified?.timeIntervalSinceReferenceDate ?? 0) + "#still"
    }

    private final class StillImage {
        let image: CGImage
        init(image: CGImage) { self.image = image }
    }

    private static func downsampledImage(at url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }

    func resizable(capInsets: EdgeInsets = EdgeInsets(), resizingMode: Image.ResizingMode = .stretch) -> Self {
        var view = self
        view.isResizable = true
        return view
    }

    func aspectRatio(_ aspectRatio: CGFloat? = nil, contentMode: ContentMode) -> Self {
        var view = self
        view.contentMode = contentMode
        return view
    }
}

/// The preview `GifImage` shows: a layer that scales the picture to fill its bounds (cropping the
/// overflow) or to fit inside them. It shows the still until it plays; it plays only while asked
/// to and while its window is on screen (`ThumbnailAnimation.windowShows`), from the shared
/// `PreviewAnimator`, with its frames decoded off the main thread at the size it shows them
/// (`PreviewFrameSequence`). A preview that stops keeps the frame it shows.
final class PreviewImageView: NSView {
    let imageLayer = CALayer()
    private var windowObservers: [NSObjectProtocol] = []
    /// The enclosing scroll view's clip view, watched so a tile scrolled out of sight stops.
    private var scrollObserver: NSObjectProtocol?
    private var sequence: PreviewFrameSequence?
    private var shownFrame: Int?
    /// `animationURL` isn't an animation (one frame, or unreadable): the still stays.
    private var isStillOnly = false

    /// The first frame, downsampled: shown until a frame plays.
    var still: CGImage? {
        didSet {
            guard still !== oldValue, shownFrame == nil else { return }
            setContents(still)
        }
    }

    /// The animated preview to play.
    var animationURL: URL? {
        didSet {
            guard animationURL != oldValue else { return }
            sequence = nil
            shownFrame = nil
            isStillOnly = false
            setContents(still)
            updateAnimation()
        }
    }

    /// Scale to fill the bounds (cropping) rather than fit inside them.
    var fills = true {
        didSet {
            guard fills != oldValue else { return }
            imageLayer.contentsGravity = fills ? .resizeAspectFill : .resizeAspect
            sequence = nil
        }
    }

    /// Whether the image is to play while its window shows.
    var wantsAnimation = false {
        didSet { if wantsAnimation != oldValue { updateAnimation() } }
    }

    /// Whether the image is playing now.
    private(set) var isAnimating = false

    /// The frames' decode size: what the view covers in pixels.
    var shownPixelSize: CGSize {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        return CGSize(width: (bounds.width * scale).rounded(.up), height: (bounds.height * scale).rounded(.up))
    }

    /// A press on a preview belongs to its tile (a click, a drag onto a folder), never to moving
    /// a window that moves by its background; NSView's default allows that for any non-opaque view.
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
    }

    override func layout() {
        super.layout()
        imageLayer.frame = bounds
        updateAnimation() // Moved or resized into or out of the visible part of its scroll view.
        // A tile that grew past what its frames were decoded for decodes them again.
        if let sequence, sequence.pixelSize.width < min(shownPixelSize.width, sequence.sourceSize.width) - 1,
           sequence.pixelSize.height < min(shownPixelSize.height, sequence.sourceSize.height) - 1 {
            self.sequence = nil
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        imageLayer.contentsScale = window?.backingScaleFactor ?? 2
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        windowObservers = []
        if let window {
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification] {
                windowObservers.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.updateAnimation() }
                    })
            }
        }
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        scrollObserver = nil
        if window != nil, let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateAnimation() }
                }
        }
        updateAnimation()
    }

    /// Plays only while its window shows and some of it is inside its scroll view's visible part:
    /// a scrolled-away tile stops and lets its decoded frames go (it keeps the frame it shows, and
    /// decodes again, off the main thread, if it scrolls back).
    private func updateAnimation() {
        let plays = wantsAnimation && animationURL != nil && !isStillOnly && ThumbnailAnimation.windowShows(window)
            && !visibleRect.isEmpty
        guard plays != isAnimating else { return }
        isAnimating = plays
        if plays {
            PreviewAnimator.shared.add(self)
        } else {
            PreviewAnimator.shared.remove(self)
            sequence = nil
            shownFrame = nil
        }
    }

    /// From `PreviewAnimator`: shows the frame for `time` once it is decoded.
    func showFrame(at time: Double) {
        guard let url = animationURL else { return }
        if sequence == nil {
            let size = shownPixelSize
            guard size.width > 0, size.height > 0 else { return }
            // Nil for a still picture: it keeps showing the still.
            sequence = PreviewFrameSequence(url: url, fitting: size, fills: fills)
            guard sequence != nil else {
                isStillOnly = true
                return updateAnimation()
            }
        }
        guard let sequence,
              let next = sequence.frameToShow(at: time, nextTick: time + 1 / PreviewAnimator.maximumRate),
              next.index != shownFrame else { return }
        shownFrame = next.index
        setContents(next.image)
    }

    private func setContents(_ image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image
        CATransaction.commit()
    }
}
