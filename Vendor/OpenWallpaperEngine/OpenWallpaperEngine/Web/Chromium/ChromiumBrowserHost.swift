import Foundation
import Metal

/// What a browser reports back to the page object that owns it.
protocol ChromiumBrowserClient: AnyObject {
    /// A painted frame (XPC's queue).
    func chromiumFrame(_ frame: ChromiumFrame)
    /// The page called `__owePost(name, body)`; `body` is JSON (main thread).
    func chromiumMessage(name: String, body: String)
    /// The main frame finished loading (main thread).
    func chromiumDidFinishLoading(status: Int)
    /// The browser's renderer, or the whole helper, went away (main thread).
    func chromiumTerminated(reason: String)
    /// An `owe-wallpaper` request (XPC's queue): answered from the wallpaper's own folder only.
    func chromiumResource(url: String, range: String?) -> ChromiumResourceResponse
}

/// The app's single connection to owe-chromium-helper for web wallpapers: every page's browser
/// lives in the one helper process, the way WebKit pages share a web content process
/// (`WebProcessGroup`). Starts the helper on the first browser and lets it exit a few seconds
/// after the last one closes. Thread-safe; replies and frames arrive on XPC's queue.
final class ChromiumBrowserHost: NSObject, ChromiumBrowserHostProtocol, @unchecked Sendable {
    static let shared = ChromiumBrowserHost(
        makeConnection: { NSXPCConnection(serviceName: ChromiumHelperIPC.serviceName) },
        device: MTLCreateSystemDefaultDevice(),
        engine: {
            ChromiumEngineInstallation.activeInstall().map { ($0, ChromiumEngineInstallation.profileDirectory()) }
        })

    /// How long the helper stays up with no browser, so a wallpaper switch doesn't restart CEF.
    var idleExit: TimeInterval = 5

    private struct Client {
        weak var client: ChromiumBrowserClient?
    }

    private let makeConnection: () -> NSXPCConnection
    private let device: MTLDevice?
    private let engine: () -> (install: URL, profile: URL)?
    // `lock` guards everything below.
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var clients: [Int: Client] = [:]
    private var nextId = 1
    private var idleGeneration = 0
    private var requestedDebuggingPort = 0
    /// The DevTools port the current connection's helper was started with.
    private var connectionDebuggingPort = 0

    init(makeConnection: @escaping () -> NSXPCConnection, device: MTLDevice?,
         engine: @escaping () -> (install: URL, profile: URL)?) {
        self.makeConnection = makeConnection
        self.device = device
        self.engine = engine
    }

    /// Chromium's DevTools port on 127.0.0.1 (`WebDevtools`), 0 for closed. CEF opens it only as it
    /// starts, so a change lets the running helper go and its pages reopen in a new one.
    var remoteDebuggingPort: Int {
        get { lock.withLock { requestedDebuggingPort } }
        set {
            let (released, open): (NSXPCConnection?, [ChromiumBrowserClient]) = lock.withLock {
                requestedDebuggingPort = newValue
                guard let connection, connectionDebuggingPort != newValue else { return (nil, []) }
                self.connection = nil
                let open = clients.values.compactMap(\.client)
                clients.removeAll()
                return (connection, open)
            }
            guard let released else { return }
            OWELog.info(.web, "Restarting the Chromium helper with DevTools \(newValue > 0 ? "on port \(newValue)" : "off")")
            released.invalidate()
            DispatchQueue.main.async {
                open.forEach { $0.chromiumTerminated(reason: "The Chromium helper restarted for DevTools") }
            }
        }
    }

    /// Whether any web wallpaper page has a browser.
    var hasBrowsers: Bool { lock.withLock { clients.values.contains { $0.client != nil } } }

    private func helper(onError: @escaping (Error) -> Void) -> ChromiumBrowserHelperProtocol? {
        let connection: NSXPCConnection = lock.withLock {
            if let connection = self.connection { return connection }
            connectionDebuggingPort = requestedDebuggingPort
            let connection = makeConnection()
            connection.remoteObjectInterface = .chromiumBrowserHelper
            connection.exportedInterface = .chromiumBrowserHost
            connection.exportedObject = self
            connection.interruptionHandler = { [weak self, weak connection] in
                self?.connectionLost(connection, reason: "The Chromium helper exited unexpectedly")
            }
            connection.invalidationHandler = { [weak self, weak connection] in
                self?.connectionLost(connection, reason: nil)
            }
            connection.resume()
            self.connection = connection
            return connection
        }
        return connection.remoteObjectProxyWithErrorHandler(onError) as? ChromiumBrowserHelperProtocol
    }

    /// `lostConnection` ended (nil: already released). Only the current connection's browsers
    /// are affected; one the host let go of on purpose has none.
    private func connectionLost(_ lostConnection: NSXPCConnection?, reason: String?) {
        let lost: [ChromiumBrowserClient] = lock.withLock {
            guard let lostConnection, lostConnection === connection else { return [] }
            connection = nil
            // An interrupted XPC service keeps no state: its browsers are gone; a new
            // connection starts a new helper.
            lostConnection.invalidate()
            let open = clients.values.compactMap(\.client)
            clients.removeAll()
            return open
        }
        if let reason { OWELog.error(.web, "\(reason); \(lost.count) web wallpaper page(s) will reload") }
        guard !lost.isEmpty else { return }
        DispatchQueue.main.async {
            lost.forEach { $0.chromiumTerminated(reason: reason ?? "The Chromium helper closed") }
        }
    }

    /// Opens a browser for `client` and returns its number at once; `completion` gets nil when the
    /// browser exists, else the reason (main thread).
    @discardableResult
    func openBrowser(for client: ChromiumBrowserClient, url: URL, width: Int, height: Int, scale: Double,
                     frameRate: Int, startScript: String, completion: @escaping (String?) -> Void) -> Int {
        let id: Int = lock.withLock {
            let id = nextId
            nextId += 1
            clients[id] = Client(client: client)
            idleGeneration += 1
            return id
        }
        let fail: (String) -> Void = { [weak self] reason in
            self?.forget(id)
            DispatchQueue.main.async { completion(reason) }
        }
        guard let engine = engine() else {
            fail("The Chromium engine isn't installed")
            return id
        }
        guard let helper = helper(onError: { fail($0.localizedDescription) }) else {
            fail("The Chromium helper isn't available")
            return id
        }
        do {
            try ChromiumEngineHelpers.sync(engine.install)
        } catch {
            fail("Can't update the Chromium engine's helpers: \(error.localizedDescription)")
            return id
        }
        let bundle = engine.install.appending(path: ChromiumHelperIPC.engineBundleName, directoryHint: .isDirectory)
        // Debug builds only (the helper ignores it otherwise): tells a sandbox problem from anything else.
        let noSandbox = ProcessInfo.processInfo.environment["OWE_CEF_NO_SANDBOX"] == "1"
        let debuggingPort = lock.withLock { connectionDebuggingPort }
        helper.initialize(engineBundle: bundle.path, cacheDirectory: engine.profile.path,
                          debugNoSandbox: noSandbox, remoteDebuggingPort: debuggingPort) { error in
            if let error {
                fail(error)
                return
            }
            helper.createBrowser(id, url: url.absoluteString, width: width, height: height, scale: scale,
                                 frameRate: frameRate, startScript: startScript) { error in
                if let error { fail(error) } else { DispatchQueue.main.async { completion(nil) } }
            }
        }
        return id
    }

    func closeBrowser(_ id: Int) {
        guard forget(id) else { return }
        proxy?.closeBrowser(id)
    }

    /// Drops `id`; the helper is let go once nothing has been open for `idleExit`.
    @discardableResult
    private func forget(_ id: Int) -> Bool {
        let (removed, generation, empty) = lock.withLock { () -> (Bool, Int, Bool) in
            let removed = clients.removeValue(forKey: id) != nil
            idleGeneration += 1
            return (removed, idleGeneration, clients.isEmpty)
        }
        if removed, empty {
            DispatchQueue.main.asyncAfter(deadline: .now() + idleExit) { [weak self] in self?.exitIfIdle(generation) }
        }
        return removed
    }

    private func exitIfIdle(_ generation: Int) {
        let connection: NSXPCConnection? = lock.withLock {
            guard generation == idleGeneration, clients.isEmpty else { return nil }
            defer { self.connection = nil }
            return self.connection
        }
        guard let connection else { return }
        OWELog.info(.web, "No web wallpaper uses Chromium; letting its helper exit")
        connection.invalidate()
    }

    private var proxy: ChromiumBrowserHelperProtocol? {
        lock.withLock { connection }?.remoteObjectProxyWithErrorHandler { error in
            OWELog.debug(.web, "Chromium helper call failed: \(error)")
        } as? ChromiumBrowserHelperProtocol
    }

    func resize(_ id: Int, width: Int, height: Int, scale: Double) {
        proxy?.resizeBrowser(id, width: width, height: height, scale: scale)
    }

    func setHidden(_ id: Int, hidden: Bool) { proxy?.setBrowserHidden(id, hidden: hidden) }
    func setFrameRate(_ id: Int, frameRate: Int) { proxy?.setBrowserFrameRate(id, frameRate: frameRate) }
    func setAudioMuted(_ id: Int, muted: Bool) { proxy?.setBrowserAudioMuted(id, muted: muted) }
    func execute(_ id: Int, script: String) { proxy?.executeJavaScript(id, script: script) }
    func send(_ id: Int, mouse event: ChromiumMouseEvent) { proxy?.sendMouseEvent(id, event: event) }

    private func client(_ id: Int) -> ChromiumBrowserClient? {
        lock.withLock { clients[id]?.client }
    }

    // MARK: ChromiumBrowserHostProtocol

    func didPaint(_ frame: ChromiumFrameMessage) {
        guard let device, let client = client(frame.browserId),
              let texture = ChromiumEngineSession.texture(for: frame, device: device) else { return }
        client.chromiumFrame(ChromiumFrame(texture: texture, surface: frame.surface, frameNumber: frame.frameNumber))
    }

    func browser(_ browserId: Int, postedMessage name: String, body: String) {
        DispatchQueue.main.async { [weak self] in self?.client(browserId)?.chromiumMessage(name: name, body: body) }
    }

    func browser(_ browserId: Int, finishedLoadingWithStatus status: Int) {
        DispatchQueue.main.async { [weak self] in self?.client(browserId)?.chromiumDidFinishLoading(status: status) }
    }

    func browserTerminated(_ browserId: Int, reason: String) {
        OWELog.error(.web, "A Chromium web wallpaper page ended: \(reason)")
        guard let client = client(browserId) else { return }
        forget(browserId)
        DispatchQueue.main.async { client.chromiumTerminated(reason: reason) }
    }

    func browser(_ browserId: Int, requestsResource url: String, range: String?,
                 reply: @escaping (ChromiumResourceResponse) -> Void) {
        reply(client(browserId)?.chromiumResource(url: url, range: range) ?? .notFound())
    }
}

/// The scripts a Chromium page starts with: exactly WebKit's document-start scripts, with
/// `window.webkit.messageHandlers.<name>.postMessage(body)` pointed at the helper's
/// `__oweHostPost(name, json)`. Nothing named `webkit` is defined, so a page can't mistake
/// Chromium for Safari.
enum ChromiumPageScripts {
    static let webKitHandlers = "window.webkit.messageHandlers."
    static let chromiumHandlers = "window.__oweMessageHandlers."
    /// The message the result of `evaluate(_:completion:)` comes back as.
    static let evaluationResultMessage = "__oweEvaluationResult"

    /// Defines `__oweMessageHandlers`: any handler name, whose `postMessage` sends JSON.
    static let prelude = """
    (function(){
      var post = window.__oweHostPost;
      if (typeof post !== 'function' || window.__oweMessageHandlers) return;
      var handlers = new Proxy({}, { get: function(target, name){
        return { postMessage: function(body){
          try { post(String(name), JSON.stringify(body === undefined ? null : body)); } catch(e) {}
        } };
      } });
      Object.defineProperty(window, '__oweMessageHandlers', { value: handlers, enumerable: false });
    })();
    """

    /// A WebKit bridge script, made to post through the helper.
    static func adapt(_ script: String) -> String {
        script.replacingOccurrences(of: webKitHandlers, with: chromiumHandlers)
    }

    /// The prelude followed by `scripts`, adapted.
    static func startScript(_ scripts: [String]) -> String {
        ([prelude] + scripts.map(adapt)).joined(separator: "\n")
    }

    /// Evaluates `expression` and posts `{id, value}` back as `evaluationResultMessage`.
    static func evaluation(_ expression: String, id: Int) -> String {
        """
        (function(){var value=null;try{value=(\(expression));}catch(e){value=null;}\
        try{window.__oweMessageHandlers.\(evaluationResultMessage).postMessage({id:\(id),value:value===undefined?null:value});}catch(e){}})();
        """
    }
}

/// Answers a Chromium page's `owe-wallpaper` requests with the same rules as WebKit's
/// `WebWallpaperSchemeHandler`: only regular files inside the wallpaper folder (symlinks resolved,
/// security audit H1/H2), WE's compatibility patches applied, byte ranges honoured.
enum ChromiumResourceServing {
    /// The https origin a remote embed page is served at, as WebKit's `loadHTMLString` base URL.
    static let embedPageURL = "https://localhost/"

    static func response(for urlString: String, range: String?, directory: URL?, patches: WebCompatPatches,
                         embedHTML: String?, userFiles: WebUserFiles? = nil) -> ChromiumResourceResponse {
        if urlString == embedPageURL {
            guard let embedHTML else { return .notFound() }
            return ChromiumResourceResponse(status: 200, headers: ["Content-Type": "text/html; charset=utf-8"],
                                            data: Data(embedHTML.utf8))
        }
        guard let url = URL(string: urlString), url.scheme == WebWallpaperSchemeHandler.scheme,
              url.host == WebWallpaperSchemeHandler.host else { return .notFound() }
        var request = URLRequest(url: url)
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }
        let reply = WebWallpaperSchemeHandler.reply(to: request, directory: directory, patches: patches, userFiles: userFiles)
        switch reply.body {
        case .data(let data):
            return ChromiumResourceResponse(status: reply.status, headers: reply.headers, data: data)
        case .file(let fileURL, let range):
            do {
                let handle = try FileHandle(forReadingFrom: fileURL)
                return ChromiumResourceResponse(status: reply.status, headers: reply.headers, file: handle,
                                                offset: range.lowerBound, length: UInt64(range.count))
            } catch {
                OWELog.debug(.web, "Web wallpaper file \(fileURL.lastPathComponent) unavailable: \(error)")
                return .notFound()
            }
        }
    }
}
