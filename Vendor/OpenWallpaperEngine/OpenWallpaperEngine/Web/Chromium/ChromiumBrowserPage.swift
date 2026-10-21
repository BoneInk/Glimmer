import AppKit
import CoreImage
import Foundation

/// One Chromium browser showing one page, as `WebWallpaperPage`: what a WKWebView is to the
/// WebKit path. It owns the browser in the shared helper (`ChromiumBrowserHost`), serves its
/// `owe-wallpaper` requests from the wallpaper folder, relays the bridge's messages and hands
/// frames to its view. The browser is created once the view has a size, and created again if
/// the page or the helper goes away.
final class ChromiumBrowserPage: NSObject, WebWallpaperPage, ChromiumBrowserClient, @unchecked Sendable {
    /// What the page is: the URL to open and the folder its `owe-wallpaper` requests come from.
    struct Content: Equatable {
        var url: URL
        var directory: URL?
        var patches: WebCompatPatches = WebCompatPatches(actions: [])
        /// A remote embed page, served at `ChromiumResourceServing.embedPageURL`.
        var embedHTML: String?
        /// The user's files the page may read (`WebUserFiles`).
        var userFiles: WebUserFiles?
    }

    private let host: ChromiumBrowserHost
    private let startScript: String

    /// The page's messages, decoded from JSON (main thread).
    var onMessage: ((String, Any) -> Void)?
    /// The main frame finished loading (main thread); the status is HTTP's or a CEF error.
    var onLoad: ((Int) -> Void)?
    /// Each frame (XPC's queue).
    var onFrame: ((ChromiumFrame) -> Void)?
    weak var view: NSView?

    // Main thread only.
    private(set) var browserId: Int?
    private var content: Content?
    private var size: (width: Int, height: Int, scale: Double)?
    private var hidden = false
    private var muted = false
    private var frameRate: Int
    private var evaluations: [Int: (Any?) -> Void] = [:]
    private var nextEvaluation = 1
    private var closed = false
    /// Recreations after a crash in a row; a page that keeps crashing stops being retried.
    private var crashes = 0
    static let maxCrashes = 3
    /// Screenshots waiting for their frame, by token.
    private var captures: [Int: (width: Int, height: Int, resized: Bool, completion: (CGImage?) -> Void)] = [:]
    private var nextCapture = 1

    // `lock` guards what the XPC queue reads.
    private let lock = NSLock()
    private var servedContent: Content?
    private var lastFrame: ChromiumFrame?
    /// The screenshot frame being waited for.
    private var pendingCapture: PendingCapture?
    /// The image of the screenshot frame that came, by token.
    private var capturedImages: [Int: CGImage] = [:]
    /// A screenshot's size, whose frames still in flight after it are dropped.
    private var staleSize: (width: Int, height: Int)?
    /// The displays mirroring the page (`WebPageMirrorView`), each fed every frame shown.
    private var frameObservers: [ObjectIdentifier: (ChromiumFrame) -> Void] = [:]

    init(host: ChromiumBrowserHost = .shared, startScripts: [String], frameRate: Int) {
        self.host = host
        self.startScript = ChromiumPageScripts.startScript(startScripts)
        self.frameRate = frameRate
    }

    deinit {
        if let browserId { host.closeBrowser(browserId) }
    }

    /// Opens `content` (closing the page shown before).
    func load(_ content: Content) {
        self.content = content
        lock.withLock { servedContent = content }
        crashes = 0
        recreate()
    }

    /// The view's size in points and its pixels per point.
    func resize(width: Int, height: Int, scale: Double) {
        guard width > 0, height > 0, scale > 0 else { return }
        if let size, size.width == width, size.height == height, size.scale == scale { return }
        let hadSize = size != nil
        size = (width, height, scale)
        if let browserId {
            host.resize(browserId, width: width, height: height, scale: scale)
        } else if !hadSize {
            recreate()
        }
    }

    func setFrameRate(_ frameRate: Int) {
        guard frameRate != self.frameRate else { return }
        self.frameRate = frameRate
        if let browserId { host.setFrameRate(browserId, frameRate: frameRate) }
    }

    /// Closes the browser for good.
    func close() {
        closed = true
        if let browserId { host.closeBrowser(browserId) }
        browserId = nil
        evaluations.values.forEach { $0(nil) }
        evaluations.removeAll()
    }

    private func recreate() {
        if let browserId { host.closeBrowser(browserId) }
        browserId = nil
        guard !closed, let content, let size else { return }
        let url = content.embedHTML != nil ? URL(string: ChromiumResourceServing.embedPageURL)! : content.url
        var opened: Int?
        let id = host.openBrowser(for: self, url: url, width: size.width, height: size.height, scale: size.scale,
                                  frameRate: frameRate, startScript: startScript) { [weak self] error in
            guard let error else { return }
            OWELog.error(.web, "Can't open \(url.lastPathComponent) in Chromium: \(error)")
            if let self, self.browserId == opened { self.browserId = nil }
        }
        opened = id
        browserId = id
        // A new browser starts shown and audible.
        if hidden { host.setHidden(id, hidden: true) }
        if muted { host.setAudioMuted(id, muted: true) }
    }

    // MARK: WebWallpaperPage

    func evaluate(_ script: String) {
        guard let browserId else { return }
        host.execute(browserId, script: script)
    }

    func evaluate(_ script: String, completion: @escaping (Any?) -> Void) {
        guard let browserId else {
            completion(nil)
            return
        }
        let id = nextEvaluation
        nextEvaluation += 1
        evaluations[id] = completion
        host.execute(browserId, script: ChromiumPageScripts.evaluation(script, id: id))
    }

    func setPageMuted(_ muted: Bool) {
        self.muted = muted
        if let browserId { host.setAudioMuted(browserId, muted: muted) }
    }

    /// Pausing is the bridge's scripts plus hiding the page (`applySchedulingPolicy`), which stops
    /// Chromium drawing it: unlike WebKit, a page that ignores `setPaused` stops too.
    func setPagePaused(_ paused: Bool) {}

    /// A page nobody can see is hidden: Chromium stops its layout, painting and animation frames
    /// and throttles its timers, while its sound plays on (an audible covered wallpaper keeps its
    /// sound, as in WebKit).
    func applySchedulingPolicy(muted: Bool, visible: Bool) {
        guard hidden == visible else { return }
        hidden = !visible
        if let browserId { host.setHidden(browserId, hidden: hidden) }
    }

    var hostWindow: NSWindow? { view?.window }

    func snapshot(completion: @escaping (CGImage?) -> Void) {
        completion(lock.withLock { lastFrame }.flatMap(Self.image))
    }

    /// A screenshot `pixelWidth` pixels wide (main thread, as `completion`): the browser is drawn
    /// at the device scale that makes it that wide, a frame of that size (`captureSettle`) is read
    /// on XPC's queue before the helper reuses its surface, and the page gets its own size back.
    /// A hidden (or paused) page, or one already that wide, gives its last frame. Without a frame
    /// of that size within `timeout`, the last frame at the page's own size; nil without any.
    func capture(pixelWidth: Int, timeout: TimeInterval = 5, completion: @escaping (CGImage?) -> Void) {
        let last = lock.withLock { lastFrame }
        guard let browserId, let size, !hidden, pixelWidth > 0 else {
            completion(last.flatMap(Self.image))
            return
        }
        let scale = Double(pixelWidth) / Double(size.width)
        let height = Int((Double(size.height) * scale).rounded())
        if let last, Self.frame(last, matches: (pixelWidth, height)) {
            completion(Self.image(of: last))
            return
        }
        let token = nextCapture
        nextCapture += 1
        // Another size than the page's own: its frames are the screenshot's, not the page's.
        let resized = abs(Int((Double(size.width) * size.scale).rounded()) - pixelWidth) > 1
        captures[token] = (pixelWidth, height, resized, completion)
        lock.withLock { pendingCapture = PendingCapture(token: token, width: pixelWidth, height: height, resized: resized) }
        host.resize(browserId, width: size.width, height: size.height, scale: scale)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finishCapture(token, timedOut: true)
        }
    }

    private func finishCapture(_ token: Int, timedOut: Bool) {
        guard let capture = captures.removeValue(forKey: token) else {
            _ = lock.withLock { capturedImages.removeValue(forKey: token) }
            return
        }
        let (image, last): (CGImage?, ChromiumFrame?) = lock.withLock {
            if pendingCapture?.token == token { pendingCapture = nil }
            // Frames of the screenshot's size still on their way aren't the page's.
            if capture.resized { staleSize = (capture.width, capture.height) }
            return (capturedImages.removeValue(forKey: token), lastFrame)
        }
        if let browserId, let size {
            host.resize(browserId, width: size.width, height: size.height, scale: size.scale)
        }
        if let image {
            capture.completion(image)
            return
        }
        if timedOut {
            OWELog.info(.web, "Chromium drew no \(capture.width)×\(capture.height) frame in time; the screenshot is the page at its own size")
        }
        capture.completion(last.flatMap(Self.image))
    }

    private struct PendingCapture {
        let token: Int
        let width: Int
        let height: Int
        let resized: Bool
        /// When the first frame of that size came.
        var firstAt: CFAbsoluteTime?
    }

    /// The first frames after a resize can be half drawn (a canvas redrawn on the next animation
    /// frame, tiles still rastering): the screenshot is the newest frame of its size this long
    /// after the first, or that first one when the page stops painting.
    static let captureSettle: TimeInterval = 0.5

    /// Chromium rounds a scaled size its own way; a pixel either side is the same size.
    static func frame(_ frame: ChromiumFrame, matches size: (width: Int, height: Int)) -> Bool {
        abs(frame.texture.width - size.width) <= 1 && abs(frame.texture.height - size.height) <= 1
    }

    private static let imageContext = CIContext()

    /// The frame as an upright sRGB image; reads the surface now, while the helper doesn't reuse it.
    static func image(of frame: ChromiumFrame) -> CGImage? {
        guard let image = CIImage(mtlTexture: frame.texture, options: [.colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
        else { return nil }
        // Metal's origin is top-left, Core Image's bottom-left.
        let upright = image.transformed(by: CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -image.extent.height))
        return imageContext.createCGImage(upright, from: upright.extent)
    }

    /// Hands `owner` every frame the page shows from now on (XPC's queue), starting with the
    /// last one (on this thread), so a mirror shows the page at once.
    func addFrameObserver(_ owner: AnyObject, _ observer: @escaping (ChromiumFrame) -> Void) {
        let last = lock.withLock {
            frameObservers[ObjectIdentifier(owner)] = observer
            return lastFrame
        }
        if let last { observer(last) }
    }

    func removeFrameObserver(_ owner: AnyObject) {
        _ = lock.withLock { frameObservers.removeValue(forKey: ObjectIdentifier(owner)) }
    }

    func sendMouse(_ event: ChromiumMouseEvent) {
        guard let browserId, !hidden else { return }
        host.send(browserId, mouse: event)
    }

    // MARK: ChromiumBrowserClient

    func chromiumFrame(_ frame: ChromiumFrame) {
        enum Use { case show, capture(Int, last: Bool), drop }
        let use: Use = lock.withLock {
            if var pending = pendingCapture, Self.frame(frame, matches: (pending.width, pending.height)) {
                let now = CFAbsoluteTimeGetCurrent()
                guard let first = pending.firstAt else {
                    pending.firstAt = now
                    pendingCapture = pending
                    return .capture(pending.token, last: false)
                }
                guard now - first >= Self.captureSettle else { return .drop }
                pendingCapture = nil
                if pending.resized { staleSize = (pending.width, pending.height) }
                return .capture(pending.token, last: true)
            }
            if let stale = staleSize {
                if Self.frame(frame, matches: stale) { return .drop }
                staleSize = nil
            }
            lastFrame = frame
            return .show
        }
        switch use {
        case .show:
            onFrame?(frame)
            lock.withLock { Array(frameObservers.values) }.forEach { $0(frame) }
        case .capture(let token, let last):
            let image = Self.image(of: frame)
            lock.withLock { if let image { capturedImages[token] = image } }
            DispatchQueue.main.asyncAfter(deadline: .now() + (last ? 0 : 2 * Self.captureSettle)) { [weak self] in
                self?.finishCapture(token, timedOut: false)
            }
        case .drop:
            break
        }
    }

    func chromiumMessage(name: String, body: String) {
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: Data(body.utf8), options: [.fragmentsAllowed])
        } catch {
            OWELog.debug(.web, "Ignoring a malformed \(name) message from a Chromium page")
            return
        }
        if name == ChromiumPageScripts.evaluationResultMessage {
            guard let object = value as? [String: Any], let id = (object["id"] as? NSNumber)?.intValue,
                  let completion = evaluations.removeValue(forKey: id) else { return }
            completion(object["value"] is NSNull ? nil : object["value"])
            return
        }
        onMessage?(name, value)
    }

    func chromiumDidFinishLoading(status: Int) {
        if status > 0 { crashes = 0 }
        onLoad?(status)
    }

    func chromiumTerminated(reason: String) {
        browserId = nil
        evaluations.values.forEach { $0(nil) }
        evaluations.removeAll()
        guard !closed else { return }
        crashes += 1
        guard crashes <= Self.maxCrashes else {
            OWELog.error(.web, "A Chromium web wallpaper page ended \(crashes) times in a row; not reopening it")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.browserId == nil else { return }
            self.recreate()
        }
    }

    func chromiumResource(url: String, range: String?) -> ChromiumResourceResponse {
        guard let content = lock.withLock({ servedContent }) else { return .notFound() }
        return ChromiumResourceServing.response(for: url, range: range, directory: content.directory,
                                                patches: content.patches, embedHTML: content.embedHTML,
                                                userFiles: content.userFiles)
    }
}
