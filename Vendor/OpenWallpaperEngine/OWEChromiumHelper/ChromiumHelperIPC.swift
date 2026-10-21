import Foundation
import IOSurface

// Compiled into both the app and owe-chromium-helper: the XPC contract between them. Class and
// protocol names are fixed with @objc(...) so both modules archive and look up the same names.

enum ChromiumHelperIPC {
    /// The bundle identifier of the XPC service in `Contents/XPCServices`.
    static let serviceName = "app.openwallpaperengine.chromium.helper"
    /// The largest frame side either end accepts, in pixels.
    static let maxDimension = 16_384
    /// The only pixel format frames come in: 8-bit BGRA, what CEF paints on macOS.
    static let pixelFormat: OSType = 0x4247_5241 // 'BGRA'
    /// The self-contained app bundle each installed version is assembled into (CEF's macOS layout),
    /// so CEF's sandbox, which allows its main bundle, covers the framework and helpers.
    static let engineBundleName = "OWE Chromium.app"
    /// CEF's helper inside that bundle's Frameworks folder; Chromium derives the variants'
    /// names from it ("<name> (Renderer)", "(GPU)", "(Plugin)").
    static let helperName = "OWE Chromium Helper"
    static let helperVariants = ["", " (Renderer)", " (GPU)", " (Plugin)"]
}

/// What the app asks the helper to do.
@objc(OWEChromiumHelperProtocol)
protocol ChromiumHelperProtocol {
    /// Loads CEF from `engineBundle` (the installed version's `OWE Chromium.app`), keeps its
    /// profile in `cacheDirectory` and opens `url` windowless at `width`×`height` pixels, painting
    /// at most `frameRate` frames a second. `debugNoSandbox` turns CEF's sandbox off in Debug
    /// builds only (an XPC service doesn't inherit the app's environment, so switches come this
    /// way). Replies nil once the browser exists, else the reason.
    func start(url: String, engineBundle: String, cacheDirectory: String, width: Int, height: Int,
               frameRate: Int, debugNoSandbox: Bool, reply: @escaping (String?) -> Void)
    /// Closes the browser; the helper exits when the connection goes away.
    func stop()
}

/// What the helper sends back.
@objc(OWEChromiumHostProtocol)
protocol ChromiumHostProtocol {
    func didPaint(_ frame: ChromiumFrameMessage)
}

/// One painted frame: an IOSurface (sent as a Mach port by XPC, never copied) and its number.
@objc(OWEChromiumFrameMessage)
final class ChromiumFrameMessage: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }

    let surface: IOSurface
    /// Counts up from 1 per browser.
    let frameNumber: Int64
    /// The browser that painted it (`ChromiumBrowserHelperProtocol.createBrowser`); 0 for the
    /// phase-1 `start` browser.
    let browserId: Int

    init(surface: IOSurface, frameNumber: Int64, browserId: Int = 0) {
        self.surface = surface
        self.frameNumber = frameNumber
        self.browserId = browserId
    }

    func encode(with coder: NSCoder) {
        coder.encode(surface, forKey: "surface")
        coder.encode(frameNumber, forKey: "frameNumber")
        coder.encode(browserId, forKey: "browserId")
    }

    init?(coder: NSCoder) {
        guard let surface = coder.decodeObject(of: IOSurface.self, forKey: "surface") else { return nil }
        self.surface = surface
        frameNumber = coder.decodeInt64(forKey: "frameNumber")
        browserId = coder.decodeInteger(forKey: "browserId")
    }

    /// Whether the frame is one the app can show: BGRA, inside the size limit, a positive number.
    var isValid: Bool {
        surface.pixelFormat == ChromiumHelperIPC.pixelFormat
            && (1...ChromiumHelperIPC.maxDimension).contains(surface.width)
            && (1...ChromiumHelperIPC.maxDimension).contains(surface.height)
            && frameNumber > 0
    }
}

// MARK: - Web wallpapers (phase 2)

/// Many windowless browsers in one helper: one per web wallpaper instance, all sharing CEF's
/// browser, GPU and (per site) renderer processes. Sizes are in points; CEF paints
/// `width × scale` by `height × scale` pixels.
@objc(OWEChromiumBrowserHelperProtocol)
protocol ChromiumBrowserHelperProtocol: ChromiumHelperProtocol {
    /// Loads and starts CEF from `engineBundle` (the installed version's `OWE Chromium.app`) once
    /// per helper; later calls reply with the first outcome. `debugNoSandbox` as for `start`.
    /// `remoteDebuggingPort` opens Chromium's DevTools on 127.0.0.1 at that port (0: closed); it
    /// holds for the helper's life, so the app starts a new helper to change it.
    func initialize(engineBundle: String, cacheDirectory: String, debugNoSandbox: Bool,
                    remoteDebuggingPort: Int, reply: @escaping (String?) -> Void)
    /// Opens `url` in a new browser numbered `browserId` (chosen by the app). `startScript` runs in
    /// the page's main frame before any of its own scripts, as a WKUserScript at document start does.
    func createBrowser(_ browserId: Int, url: String, width: Int, height: Int, scale: Double, frameRate: Int,
                       startScript: String, reply: @escaping (String?) -> Void)
    func closeBrowser(_ browserId: Int)
    func resizeBrowser(_ browserId: Int, width: Int, height: Int, scale: Double)
    /// Hidden: CEF stops layout, painting and animation frames (`was_hidden`).
    func setBrowserHidden(_ browserId: Int, hidden: Bool)
    func setBrowserFrameRate(_ browserId: Int, frameRate: Int)
    func setBrowserAudioMuted(_ browserId: Int, muted: Bool)
    func executeJavaScript(_ browserId: Int, script: String)
    func sendMouseEvent(_ browserId: Int, event: ChromiumMouseEvent)
}

@objc(OWEChromiumBrowserHostProtocol)
protocol ChromiumBrowserHostProtocol: ChromiumHostProtocol {
    /// The page called `__owePost(name, body)`; `body` is JSON.
    func browser(_ browserId: Int, postedMessage name: String, body: String)
    /// The main frame finished loading (`status` is the HTTP status, or a negative CEF error).
    func browser(_ browserId: Int, finishedLoadingWithStatus status: Int)
    /// The page's renderer process ended.
    func browserTerminated(_ browserId: Int, reason: String)
    /// A request for `owe-wallpaper://local/…`: the app decides what is served (its containment
    /// rules, WE's compatibility patches) and replies with the bytes or an open file.
    func browser(_ browserId: Int, requestsResource url: String, range: String?,
                 reply: @escaping (ChromiumResourceResponse) -> Void)
}

/// The app's answer to one `owe-wallpaper` request: a status, headers and either bytes or a
/// range of an open file. The file crosses XPC as a descriptor, so a large video is never copied
/// whole; the helper reads only `length` bytes from `offset`.
@objc(OWEChromiumResourceResponse)
final class ChromiumResourceResponse: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }

    let status: Int
    let headers: [String: String]
    let data: Data?
    let file: FileHandle?
    let offset: UInt64
    let length: UInt64

    init(status: Int, headers: [String: String], data: Data? = nil, file: FileHandle? = nil,
         offset: UInt64 = 0, length: UInt64 = 0) {
        self.status = status
        self.headers = headers
        self.data = data
        self.file = file
        self.offset = offset
        self.length = file == nil ? UInt64(data?.count ?? 0) : length
    }

    static func notFound() -> ChromiumResourceResponse {
        ChromiumResourceResponse(status: 404, headers: ["Access-Control-Allow-Origin": "*"], data: Data())
    }

    func encode(with coder: NSCoder) {
        coder.encode(status, forKey: "status")
        coder.encode(headers as NSDictionary, forKey: "headers")
        if let data { coder.encode(data as NSData, forKey: "data") }
        if let file { coder.encode(file, forKey: "file") }
        coder.encode(Int64(bitPattern: offset), forKey: "offset")
        coder.encode(Int64(bitPattern: length), forKey: "length")
    }

    init?(coder: NSCoder) {
        status = coder.decodeInteger(forKey: "status")
        headers = coder.decodeObject(of: [NSDictionary.self, NSString.self], forKey: "headers") as? [String: String] ?? [:]
        data = coder.decodeObject(of: NSData.self, forKey: "data") as Data?
        file = coder.decodeObject(of: FileHandle.self, forKey: "file")
        offset = UInt64(bitPattern: coder.decodeInt64(forKey: "offset"))
        length = UInt64(bitPattern: coder.decodeInt64(forKey: "length"))
    }
}

/// One mouse event for a windowless browser, at a point in the view (points, top-left origin).
@objc(OWEChromiumMouseEvent)
final class ChromiumMouseEvent: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }

    enum Kind: Int {
        case move, down, up, wheel, leave
    }

    enum Button: Int {
        case left, middle, right
    }

    let kind: Kind
    let x: Double
    let y: Double
    let button: Button
    let clickCount: Int
    let deltaX: Double
    let deltaY: Double
    /// CEF's `cef_event_flags_t` bits.
    let modifiers: UInt32

    init(kind: Kind, x: Double, y: Double, button: Button = .left, clickCount: Int = 1,
         deltaX: Double = 0, deltaY: Double = 0, modifiers: UInt32 = 0) {
        self.kind = kind
        self.x = x
        self.y = y
        self.button = button
        self.clickCount = clickCount
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.modifiers = modifiers
    }

    func encode(with coder: NSCoder) {
        coder.encode(kind.rawValue, forKey: "kind")
        coder.encode(x, forKey: "x")
        coder.encode(y, forKey: "y")
        coder.encode(button.rawValue, forKey: "button")
        coder.encode(clickCount, forKey: "clickCount")
        coder.encode(deltaX, forKey: "deltaX")
        coder.encode(deltaY, forKey: "deltaY")
        coder.encode(Int64(modifiers), forKey: "modifiers")
    }

    init?(coder: NSCoder) {
        guard let kind = Kind(rawValue: coder.decodeInteger(forKey: "kind")),
              let button = Button(rawValue: coder.decodeInteger(forKey: "button")) else { return nil }
        self.kind = kind
        self.button = button
        x = coder.decodeDouble(forKey: "x")
        y = coder.decodeDouble(forKey: "y")
        clickCount = coder.decodeInteger(forKey: "clickCount")
        deltaX = coder.decodeDouble(forKey: "deltaX")
        deltaY = coder.decodeDouble(forKey: "deltaY")
        modifiers = UInt32(truncatingIfNeeded: coder.decodeInt64(forKey: "modifiers"))
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? ChromiumMouseEvent else { return false }
        return kind == other.kind && x == other.x && y == other.y && button == other.button
            && clickCount == other.clickCount && deltaX == other.deltaX && deltaY == other.deltaY
            && modifiers == other.modifiers
    }

    override var hash: Int { kind.rawValue &+ Int(x.rounded()) &* 31 &+ Int(y.rounded()) }

    override var description: String { "\(kind)@(\(x),\(y)) button \(button.rawValue) Δ(\(deltaX),\(deltaY))" }
}

extension NSXPCInterface {
    static var chromiumHelper: NSXPCInterface { NSXPCInterface(with: ChromiumHelperProtocol.self) }

    /// `didPaint`'s argument class comes from its signature; the message decodes its IOSurface itself.
    static var chromiumHost: NSXPCInterface { NSXPCInterface(with: ChromiumHostProtocol.self) }

    /// What the helper exports: the phase-1 calls and the per-browser ones.
    static var chromiumBrowserHelper: NSXPCInterface { NSXPCInterface(with: ChromiumBrowserHelperProtocol.self) }

    /// What the app exports to the helper; a phase-1 host only ever receives `didPaint`.
    static var chromiumBrowserHost: NSXPCInterface { NSXPCInterface(with: ChromiumBrowserHostProtocol.self) }
}
