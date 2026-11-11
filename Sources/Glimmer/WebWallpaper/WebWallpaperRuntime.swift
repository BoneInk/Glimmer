import AppKit
import Foundation
import Observation
import WebKit

@MainActor
@Observable
final class WebWallpaperRuntime: NSObject {
    enum State: String, Sendable { case idle, loading, waitingForListener, ready, paused, failed, disposed }
    let webView: WKWebView
    let location: WebWallpaperProjectLocation
    let capabilities: WebWallpaperCapabilities
    private(set) var state: State = .idle
    private(set) var lastError: String?
    /// Owners of remote layers may recreate a failed document while keeping
    /// their displayed backing. Ordinary desktop owners keep their own policy.
    @ObservationIgnored var failureHandler: (@MainActor (String) -> Void)?
    /// At most 64 unique nonfatal messages per document; cleared on reload.
    private(set) var diagnostics: [String] = []
    private(set) var unsupportedPropertyKeys: [String]
    private(set) var propertyDeliveryCount = 0
    private(set) var lastDeliveredPropertyKeys: [String] = []
    private let schemeHandler: LocalWallpaperSchemeHandler
    private let messages: WebWallpaperMessageHandler
    private var properties: WebWallpaperPropertyPayload
    private var generalJSON = "{\"fps\":30}"
    private(set) var frameRateLimit = 30
    private var paused = false
    private var token = ""
    private var revision = 0
    private var navigation: WKNavigation?
    private var pushTask: Task<Void, Never>?
    private var finishedDocument = false
    private var resourceSnapshot: WebWallpaperResourceSnapshot?
    private var resourceItemID: UUID?
    private(set) var canApplyUserProperties = false
    private(set) var canApplyDirectoryProperties = false
    private var resourceWaiter: PropertyWaiter?
    private var resourceTimeoutTask: Task<Void, Never>?
    private var lastConsumedDirectoriesJSON: String?
    private var lastConsumedDirectoriesRevision = -1
    private var lastConsumedJSON: String?
    private var lastConsumedRevision = -1
    private struct PropertyWaiter {
        let id: UUID
        let json: String
        let minimumRevision: Int
        let continuation: CheckedContinuation<Void, Error>
    }
    private var propertyWaiter: PropertyWaiter?
    private var propertyTimeoutTask: Task<Void, Never>?


    /// Initialization validates locations/payload but does not load. Call load explicitly;
    /// pending settings can be changed before loading and are delivered on readiness.
    private let toleratesBlockedHTTPS: Bool

    init(projectURL: URL, entryURL: URL, propertiesJSON: Data,
         allowHTTPS: Bool = false, mutedPlayback: Bool = false, toleratesBlockedHTTPS: Bool = false,
         animationFrameRateLimit: Int? = nil, remoteLayerRendering: Bool = false,
         allowsAudioAutoplay: Bool = false) throws {
        guard animationFrameRateLimit.map({ (1...240).contains($0) }) ?? true else {
            throw WebWallpaperFailure(message: "Web animation frame rate must be in 1...240.")
        }
        let initialFPS = animationFrameRateLimit ?? 30
        frameRateLimit = initialFPS
        generalJSON = "{\"fps\":\(initialFPS)}"
        capabilities = WebWallpaperCapabilities(remoteResources: allowHTTPS)
        self.toleratesBlockedHTTPS = toleratesBlockedHTTPS
        let location = try WebWallpaperProjectLocation(projectURL: projectURL, entryURL: entryURL)
        let payload = try WebWallpaperPropertyPayload(propertiesJSON)
        self.location = location; properties = payload; unsupportedPropertyKeys = payload.unsupportedKeys
        schemeHandler = LocalWallpaperSchemeHandler(location: location, allowHTTPS: allowHTTPS)
        messages = WebWallpaperMessageHandler()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: WebWallpaperProjectLocation.scheme)
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        // Wallpaper windows normally sit behind other apps. WebKit's inactive
        // scheduling would add a second, visibility-dependent throttle. The
        // shared RAF scheduler below owns the requested animation rate instead.
        configuration.preferences.inactiveSchedulingPolicy = .none
        // Requiring a gesture for video prevents lock-screen backgrounds from
        // loading at all. Silence output separately while allowing video frames.
        configuration.mediaTypesRequiringUserActionForPlayback = (mutedPlayback || allowsAudioAutoplay) ? [] : .audio
        configuration.userContentController.add(messages, name: "gwWallpaper")
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        if mutedPlayback { try WebWallpaperMutedMediaPolicy.apply(to: webView) }
        messages.runtime = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    func load() { guard state != .disposed else { return }; beginDocument() }
    func reload() { guard state != .disposed else { return }; beginDocument() }

    /// Changes native output without reloading authored media or its timeline.
    func setMuted(_ muted: Bool) throws {
        guard state != .disposed else { throw WebWallpaperFailure(message: "Web wallpaper runtime is disposed.") }
        try WebWallpaperMutedMediaPolicy.setMuted(muted, on: webView)
    }

    /// Delivers only mouse input; original desktop events continue to Finder.
    func forwardMouseEvent(_ event: NSEvent, screenPoint: NSPoint) {
        guard state == .ready, let window = webView.window,
              webView.bounds.width > 0, webView.bounds.height > 0 else { return }
        let point = webView.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        let x = point.x / webView.bounds.width
        let y = webView.isFlipped ? point.y / webView.bounds.height : 1 - point.y / webView.bounds.height
        guard x.isFinite, y.isFinite else { return }
        let kind: String
        switch event.type {
        case .leftMouseDown: kind = "down"
        case .leftMouseUp: kind = "up"
        case .mouseMoved, .leftMouseDragged: kind = "move"
        case .scrollWheel: kind = "wheel"
        default: return
        }
        let scale = kind == "wheel" && event.hasPreciseScrollingDeltas ? 1.0 : 16.0
        let dx = kind == "wheel" ? -Double(event.scrollingDeltaX) * scale : 0
        let dy = kind == "wheel" ? -Double(event.scrollingDeltaY) * scale : 0
        guard dx.isFinite, dy.isFinite else { return }
        let payload: [String: Any] = ["kind": kind, "x": x, "y": y, "dx": dx, "dy": dy,
            "clicks": kind == "down" || kind == "up" ? event.clickCount : 0,
            "alt": event.modifierFlags.contains(.option), "ctrl": event.modifierFlags.contains(.control),
            "shift": event.modifierFlags.contains(.shift), "meta": event.modifierFlags.contains(.command)]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.__gwForwardPointer?.(\(json));true", completionHandler: nil)
    }

    func applyPropertiesJSON(_ data: Data) throws {
        guard state != .disposed else { throw WebWallpaperFailure(message: "Web wallpaper runtime is disposed.") }
        let payload = try WebWallpaperPropertyPayload(data, resources: resourceSnapshot)
        finishPropertyWaiter(throwing: CancellationError())
        properties = payload; unsupportedPropertyKeys = payload.unsupportedKeys
        lastError = nil
        pushState()
    }

    /// Completes only after this document's authored property listener consumes this
    /// payload. A newer property update supersedes the outstanding request.
    func applyPropertiesAndWait(_ data: Data, timeout: TimeInterval = 5) async throws {
        let payload = try WebWallpaperPropertyPayload(data, resources: resourceSnapshot)
        guard state != .disposed else { throw WebWallpaperFailure(message: "Web wallpaper runtime is disposed.") }
        guard timeout.isFinite, timeout > 0, timeout <= 60 else { throw WebWallpaperFailure(message: "Property acknowledgement timeout must be in 0...60 seconds.") }
        try Task.checkCancellation()
        finishPropertyWaiter(throwing: CancellationError())
        let alreadyConsumed = lastConsumedJSON == payload.json && properties.json == payload.json && lastConsumedRevision >= revision && lastError == nil
        properties = payload; unsupportedPropertyKeys = payload.unsupportedKeys
        lastError = nil
        if alreadyConsumed { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                propertyWaiter = PropertyWaiter(id: id, json: payload.json, minimumRevision: revision + 1, continuation: continuation)
                propertyTimeoutTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                    guard let self, self.propertyWaiter?.id == id else { return }
                    self.finishPropertyWaiter(throwing: WebWallpaperFailure(message: "Wallpaper property listener acknowledgement timed out."))
                }
                pushState()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.propertyWaiter?.id == id else { return }
                self?.finishPropertyWaiter(throwing: CancellationError())
            }
        }
    }

    private func finishPropertyWaiter(throwing error: Error? = nil) {
        guard let waiter = propertyWaiter else { return }
        propertyWaiter = nil
        propertyTimeoutTask?.cancel(); propertyTimeoutTask = nil
        if let error { waiter.continuation.resume(throwing: error) }
        else { waiter.continuation.resume() }
    }

    /// Install only explicit managed copies. A runtime can never change item identity.
    func configureResourceManifest(_ manifest: WebWallpaperResourceManifest) throws {
        guard state != .disposed else { throw WebWallpaperFailure(message: "Web wallpaper runtime is disposed.") }
        let snapshot = try WebWallpaperResourceSnapshot(manifest)
        guard resourceItemID == nil || resourceItemID == snapshot.itemID else { throw WebWallpaperFailure(message: "Resource manifest belongs to a different wallpaper item.") }
        finishResourceWaiter(throwing: CancellationError())
        if resourceSnapshot?.files != snapshot.files {
            finishPropertyWaiter(throwing: CancellationError())
            lastConsumedJSON = nil; lastConsumedRevision = -1
        }
        resourceItemID = snapshot.itemID; resourceSnapshot = snapshot
        lastError = nil
        schemeHandler.configureResources(root: snapshot.rootURL, grants: snapshot.files)
        pushState()
    }

    /// Separate from scalar ACK: waits for fetchall directory added/changed/removed
    /// callbacks. File/ondemand values still use applyPropertiesAndWait.
    func configureResourceManifestAndWait(_ manifest: WebWallpaperResourceManifest, timeout: TimeInterval = 5) async throws {
        guard timeout.isFinite, timeout > 0, timeout <= 60 else { throw WebWallpaperFailure(message: "Resource acknowledgement timeout must be in 0...60 seconds.") }
        try Task.checkCancellation()
        try configureResourceManifest(manifest)
        let id = UUID(), json = resourceSnapshot!.directoriesJSON
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                resourceWaiter = PropertyWaiter(id: id, json: json, minimumRevision: revision + 1, continuation: continuation)
                resourceTimeoutTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                    guard let self, self.resourceWaiter?.id == id else { return }
                    self.finishResourceWaiter(throwing: WebWallpaperFailure(message: "Wallpaper directory callback acknowledgement timed out."))
                }
                pushState()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.resourceWaiter?.id == id else { return }
                self?.finishResourceWaiter(throwing: CancellationError())
            }
        }
    }

    private func finishResourceWaiter(throwing error: Error? = nil) {
        guard let waiter = resourceWaiter else { return }
        resourceWaiter = nil; resourceTimeoutTask?.cancel(); resourceTimeoutTask = nil
        if let error { waiter.continuation.resume(throwing: error) } else { waiter.continuation.resume() }
    }

    func setGeneralPropertiesJSON(_ data: Data) throws {
        guard state != .disposed else { throw WebWallpaperFailure(message: "Web wallpaper runtime is disposed.") }
        generalJSON = try WebWallpaperPropertyPayload.generalJSON(data)
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let fps = object["fps"] as? NSNumber {
            frameRateLimit = fps.intValue
        }
        pushState()
    }

    func setFrameRateLimit(_ fps: Int) throws {
        guard (1...240).contains(fps) else {
            throw WebWallpaperFailure(message: "Web wallpaper frame rate must be in 1...240.")
        }
        try setGeneralPropertiesJSON(try JSONSerialization.data(withJSONObject: ["fps": fps]))
    }

    /// Suspends the live RAF scheduler and HTML media, and delivers the official
    /// cooperative callback. CSS, workers and timers keep their own clocks.
    func setPaused(_ value: Bool) {
        guard state != .disposed else { return }
        paused = value
        webView.setAllMediaPlaybackSuspended(value, completionHandler: nil)
        pushState()
    }

    func dispose() {
        guard state != .disposed else { return }
        failureHandler = nil
        finishPropertyWaiter(throwing: WebWallpaperFailure(message: "Web wallpaper runtime was disposed."))
        finishResourceWaiter(throwing: WebWallpaperFailure(message: "Web wallpaper runtime was disposed."))
        resourceSnapshot = nil; lastConsumedDirectoriesJSON = nil; lastConsumedDirectoriesRevision = -1
        canApplyUserProperties = false; canApplyDirectoryProperties = false
        lastConsumedJSON = nil; lastConsumedRevision = -1
        token = UUID().uuidString
        pushTask?.cancel(); pushTask = nil
        webView.stopLoading()
        webView.setAllMediaPlaybackSuspended(true, completionHandler: nil)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "gwWallpaper")
        webView.configuration.userContentController.removeAllUserScripts()
        messages.runtime = nil
        webView.navigationDelegate = nil; webView.uiDelegate = nil
        schemeHandler.dispose()
        webView.loadHTMLString("", baseURL: nil)
        navigation = nil; finishedDocument = false
        state = .disposed
    }

    private func beginDocument() {
        finishPropertyWaiter(throwing: WebWallpaperFailure(message: "Web wallpaper document was reloaded."))
        finishResourceWaiter(throwing: WebWallpaperFailure(message: "Web wallpaper document was reloaded."))
        lastConsumedDirectoriesJSON = nil; lastConsumedDirectoriesRevision = -1
        canApplyUserProperties = false; canApplyDirectoryProperties = false
        lastConsumedJSON = nil; lastConsumedRevision = -1
        webView.stopLoading()
        pushTask?.cancel(); pushTask = nil
        token = UUID().uuidString; revision = 0; finishedDocument = false
        propertyDeliveryCount = 0; lastDeliveredPropertyKeys = []; lastError = nil; diagnostics = []
        state = .loading
        schemeHandler.beginDocument(token: token)
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(source: WebWallpaperPointerBridge.script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(source: WebWallpaperBridge.script(token: token), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(source: WebWallpaperFramePacer.script(fps: frameRateLimit, paused: paused),
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        navigation = webView.load(URLRequest(url: location.documentURL))
    }

    fileprivate func receive(_ body: [String: Any]) {
        guard state != .disposed, body["token"] as? String == token, let kind = body["kind"] as? String else { return }
        switch kind {
        case "bootstrap", "documentReady":
            if state == .loading { state = .waitingForListener }
            pushState()
        case "waiting":
            if state != .failed { state = .waitingForListener }
        case "directoriesConsumed":
            guard let json = body["directoriesJSON"] as? String, let consumedRevision = body["revision"] as? Int else { return }
            lastConsumedDirectoriesJSON = json; lastConsumedDirectoriesRevision = consumedRevision
            if let waiter = resourceWaiter, waiter.json == json, consumedRevision >= waiter.minimumRevision { finishResourceWaiter() }
        case "directoriesError":
            guard let json = body["directoriesJSON"] as? String else { return }
            if json == (resourceSnapshot?.directoriesJSON ?? "{}") {
                let message = body["message"] as? String ?? "Wallpaper directory callback failed."
                fail(message)
            }
        case "propertiesError":
            guard let rawJSON = body["propertiesJSON"] as? String,
                  let canonical = try? WebWallpaperPropertyPayload(Data(rawJSON.utf8), resources: resourceSnapshot),
                  let failedRevision = body["revision"] as? Int else { return }
            // A superseded async callback cannot fail the newer desired payload.
            if canonical.json == properties.json {
                fail(body["message"] as? String ?? "Wallpaper property callback failed.")
            } else if let waiter = propertyWaiter, waiter.json == canonical.json, failedRevision >= waiter.minimumRevision {
                finishPropertyWaiter(throwing: WebWallpaperFailure(message: body["message"] as? String ?? "Wallpaper property callback failed."))
            }
        case "propertiesConsumed":
            guard let rawJSON = body["propertiesJSON"] as? String,
                  let canonical = try? WebWallpaperPropertyPayload(Data(rawJSON.utf8), resources: resourceSnapshot),
                  let consumedRevision = body["revision"] as? Int else { return }
            lastConsumedJSON = canonical.json; lastConsumedRevision = consumedRevision
            if let waiter = propertyWaiter, waiter.json == canonical.json, consumedRevision >= waiter.minimumRevision {
                finishPropertyWaiter()
            }
        case "propertiesApplied":
            propertyDeliveryCount += 1
            lastDeliveredPropertyKeys = (body["keys"] as? [String] ?? []).sorted()
        case "capabilities":
            canApplyUserProperties = body["userPropertiesListener"] as? Bool ?? false
            canApplyDirectoryProperties = body["directoryListener"] as? Bool ?? false
        case "ready":
            canApplyUserProperties = body["userPropertiesListener"] as? Bool ?? false
            canApplyDirectoryProperties = body["directoryListener"] as? Bool ?? false
            if lastError == nil { state = paused ? .paused : .ready }
        case "diagnostic":
            let message = String((body["message"] as? String ?? "Wallpaper diagnostic").prefix(2048))
            let rawURI = String((body["uri"] as? String ?? "").prefix(2048))
            var uri = rawURI
            if var components = URLComponents(string: rawURI) {
                components.user = nil; components.password = nil
                components.query = nil; components.fragment = nil
                uri = components.string ?? "[resource]"
            }
            let value = message + (uri.isEmpty ? "" : " " + uri)
            if diagnostics.count < 64, !diagnostics.contains(value) { diagnostics.append(value) }
        case "securityError":
            if toleratesBlockedHTTPS, (body["uri"] as? String)?.hasPrefix("https:") == true,
               ["connect-src", "img-src", "font-src", "style-src", "script-src", "media-src"].contains(body["directive"] as? String ?? "") {
                // The request remains blocked by CSP. A disabled weather request
                // need not stop the rest of a live clock/document.
                break
            }
            fail(body["message"] as? String ?? "Wallpaper policy violation.")
        case "scriptError": fail(body["message"] as? String ?? "Wallpaper JavaScript failed.")
        default: break
        }
    }

    private func pushState() {
        guard state != .idle, state != .loading, state != .disposed else { return }
        revision += 1
        let revision = revision, token = token, properties = properties.json, general = generalJSON, paused = paused, directories = resourceSnapshot?.directoriesJSON ?? "{}"
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            guard let self, self.token == token, !Task.isCancelled else { return }
            let failure: String? = await withCheckedContinuation { continuation in
                self.webView.callAsyncJavaScript(
                    "if (typeof window.__gwWallpaperReceive === 'function') window.__gwWallpaperReceive(token, revision, properties, general, paused, directories);",
                    arguments: ["token": token, "revision": revision, "properties": properties, "general": general, "paused": paused, "directories": directories], in: nil, in: .page,
                    completionHandler: { result in
                        if case let .failure(error) = result { continuation.resume(returning: error.localizedDescription) }
                        else { continuation.resume(returning: nil) }
                    })
            }
            guard !Task.isCancelled, self.token == token, self.state != .disposed else { return }
            if let failure {
                self.fail("Could not deliver wallpaper settings: " + failure)
            }
        }
    }

    private func fail(_ message: String) {
        let wasFailed = state == .failed
        lastError = String(message.prefix(2048)); state = .failed
        finishPropertyWaiter(throwing: WebWallpaperFailure(message: lastError!))
        finishResourceWaiter(throwing: WebWallpaperFailure(message: lastError!))
        if !wasFailed { failureHandler?(lastError!) }
    }
}

@MainActor
private final class WebWallpaperMessageHandler: NSObject, WKScriptMessageHandler {
    weak var runtime: WebWallpaperRuntime?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any] else { return }
        runtime?.receive(body)
    }
}

extension WebWallpaperRuntime: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard state != .disposed, navigationAction.targetFrame?.isMainFrame == true,
              let url = navigationAction.request.url,
              url.scheme == WebWallpaperProjectLocation.scheme, url.host == WebWallpaperProjectLocation.host,
              url.path == location.documentURL.path,
              navigationAction.navigationType == .other || navigationAction.navigationType == .reload else {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard state != .disposed, self.navigation === navigation else { return }
        finishedDocument = true
        if state == .loading { state = .waitingForListener }
        pushState()
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard state != .disposed, self.navigation === navigation, (error as NSError).code != NSURLErrorCancelled else { return }
        fail("Wallpaper navigation failed: " + error.localizedDescription)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.webView(webView, didFail: navigation, withError: error)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard state != .disposed else { return }; fail("Wallpaper WebKit content process terminated. Reload to retry.")
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void) {
        fail("Wallpaper alert: " + message); completionHandler()
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) { completionHandler(false) }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (String?) -> Void) { completionHandler(nil) }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
}
