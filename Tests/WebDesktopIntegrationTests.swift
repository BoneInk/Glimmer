import AppKit
import WebKit
import Foundation

@main @MainActor
enum WebDesktopIntegrationTests {
    static var passed = 0
    static var failed = 0
    static var audioWindow: NSWindow?
    static func check(_ condition: Bool, _ title: String) {
        if condition { passed += 1; print("PASS \(title)") }
        else { failed += 1; print("FAIL \(title)") }
    }
    static func value(_ runtime: WebWallpaperRuntime, _ script: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            runtime.webView.evaluateJavaScript(script) { result, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: String(describing: result ?? "nil")) }
            }
        }
    }
    static func ready(_ session: DesktopPlaybackSession) async throws -> WebWallpaperRuntime {
        for _ in 0..<400 {
            if let runtime = session.webRuntime, runtime.state == .ready || runtime.state == .paused { return runtime }
            if let error = session.lastError { throw WebProjectError.invalid(error) }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw WebProjectError.invalid("Web session readiness timed out")
    }

    static func waitForAudio(_ runtime: WebWallpaperRuntime) async throws {
        mountAudioHost(runtime)
        for _ in 0..<200 {
            if try await value(runtime, "!!window.testAudio && !testAudio.paused && testAudio.currentTime > 0.1") == "1" { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        throw WebProjectError.invalid("Audio did not autoplay: " + (try await value(runtime, "window.audioResult")))
    }

    static func mountAudioHost(_ runtime: WebWallpaperRuntime) {
        if audioWindow == nil {
            audioWindow = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 400, height: 240),
                styleMask: [.titled], backing: .buffered, defer: false)
            audioWindow?.title = "Glimmer isolated Web audio regression"
        }
        runtime.webView.frame = NSRect(x: 0, y: 0, width: 400, height: 240)
        audioWindow?.contentView = runtime.webView
        audioWindow?.orderFrontRegardless()
    }

    static func muted(_ runtime: WebWallpaperRuntime) -> Bool {
        ((runtime.webView.value(forKey: "_mediaMutedState") as? NSNumber)?.uintValue ?? 0) & 1 != 0
    }

    static func requestIsBlockedByCSP(_ runtime: WebWallpaperRuntime) async throws -> Bool {
        _ = try await value(runtime, """
        window.networkProbeDone=false;window.networkProbeBlocked=false;
        document.addEventListener('securitypolicyviolation',e=>{
          if(e.effectiveDirective==='connect-src')window.networkProbeBlocked=true;
        },{once:true});
        const abort=new AbortController();setTimeout(()=>abort.abort(),700);
        fetch('https://127.0.0.1:44443/glimmer-isolated-csp-test',{signal:abort.signal})
          .catch(()=>{}).finally(()=>setTimeout(()=>window.networkProbeDone=true,50));true
        """)
        for _ in 0..<100 {
            if try await value(runtime, "networkProbeDone") == "1" {
                return try await value(runtime, "networkProbeBlocked") == "1"
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw WebProjectError.invalid("CSP network probe timed out")
    }

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("WebDesktopIntegration-\(UUID())", isDirectory: true)
            do {
                let store = VideoLibraryStore(storage: AppStorage(root: root))
                let fixture = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("project.json")
                let original = try Data(contentsOf: fixture)
                let item = try await WebWallpaperProjectImporter.importProject(fixture, store: store)
                check(item.isWebWallpaper, "import records Web renderer")
                check(item.id == VideoLibraryStore(storage: store.storage).items.first?.id, "Web record committed across restart")
                let displays = DisplayRegistry()
                guard let primary = displays.primary else { throw WebProjectError.invalid("No display") }
                let playback = DesktopPlaybackController(store: store, displayRegistry: displays, storage: store.storage, previewOnly: true)
                playback.setWallpaperFPS(24)
                check(playback.apply(item: item, to: [primary.id]) == nil, "explicit desktop apply accepts local Web")
                guard let session = playback.session(for: primary.id) else { throw WebProjectError.invalid("No session") }
                let runtime = try await ready(session)
                check(runtime.frameRateLimit == 24, "new desktop Web host inherits the global FPS cap")
                playback.setWallpaperFPS(75)
                check(runtime.frameRateLimit == 75, "live FPS change reaches the desktop Web host")
                check(session.player == nil && session.playerLayer == nil, "Web uses WebKit instead of AVPlayer")
                check(session.window == nil && session.webHostView === runtime.webView, "isolated session owns real WebKit view without desktop window")
                check(store.assignments[primary.id] == item.id, "explicit apply persists correct UUID")
                check(try await value(runtime, "document.getElementById('caption').textContent") == "AURORA", "project defaults reach actual page")
                check(session.isPlaying, "ready Web session reports playing")
                check(runtime.webView.configuration.mediaTypesRequiringUserActionForPlayback.isEmpty,
                    "desktop allows authored audio autoplay without a wallpaper-window gesture")
                try await waitForAudio(runtime)
                check(muted(runtime), "saved default mute silences an actually advancing audio element")
                playback.setMuted(false, displayID: primary.id)
                check(!muted(runtime) && !session.settings.isMuted, "sidebar unmute reaches native WebKit output")
                check(try await value(runtime, "audioResult") == "played", "authored audio starts without user gesture")
                playback.setMuted(true, displayID: primary.id)
                check(muted(runtime), "sidebar mute restores native WebKit output mute")
                try await waitForAudio(runtime)
                check(session.webRuntime === runtime, "mute does not reload or replace the authored document")
                _ = try await value(runtime, """
                window.pointerMoves=0;window.pointerClicks=0;window.pointerDowns=0;
                const control=document.createElement('button');control.id='pointer-test';control.textContent='INPUT';
                control.style.cssText='position:fixed;left:10px;top:10px;width:120px;height:60px;z-index:99999';
                control.addEventListener('mousemove',()=>pointerMoves++);
                control.addEventListener('mousedown',()=>pointerDowns++);
                control.addEventListener('click',()=>pointerClicks++);document.body.appendChild(control);true
                """)
                let screenPoint = audioWindow!.convertPoint(toScreen: NSPoint(x: 40, y: 200))
                for type in [NSEvent.EventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
                    let event = NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                        eventNumber: 1, clickCount: type == .mouseMoved ? 0 : 1, pressure: type == .leftMouseDown ? 1 : 0)!
                    runtime.forwardMouseEvent(event, screenPoint: screenPoint)
                }
                for _ in 0..<100 {
                    if try await value(runtime, "pointerClicks") == "1" { break }
                    try await Task.sleep(for: .milliseconds(30))
                }
                check(try await value(runtime, "pointerMoves>0 && pointerDowns===1 && pointerClicks===1") == "1",
                    "forwarded mouse move, down and up reach the actual Web button at converted coordinates")
                _ = try await value(runtime, """
                window.captureMoves=0;window.captureUps=0;window.captureLost=0;
                const dragControl=document.getElementById('pointer-test');
                dragControl.addEventListener('pointerdown',e=>dragControl.setPointerCapture(e.pointerId));
                dragControl.addEventListener('pointermove',()=>captureMoves++);
                dragControl.addEventListener('pointerup',()=>captureUps++);
                dragControl.addEventListener('lostpointercapture',()=>captureLost++);true
                """)
                for (type, point) in [(NSEvent.EventType.leftMouseDown, NSPoint(x: 40, y: 200)),
                                      (.leftMouseDragged, NSPoint(x: 300, y: 100)), (.leftMouseUp, NSPoint(x: 300, y: 100))] {
                    let event = NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                        eventNumber: 2, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
                    runtime.forwardMouseEvent(event, screenPoint: audioWindow!.convertPoint(toScreen: point))
                }
                for _ in 0..<100 {
                    if try await value(runtime, "captureLost") == "1" { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                check(try await value(runtime, "captureMoves>0 && captureUps===1 && captureLost===1 && pointerClicks===1 && !document.getElementById('pointer-test').hasPointerCapture(1)") == "1",
                    "drag preserves pointer capture across elements and releases without a stray click")
                _ = try await value(runtime, """
                const scroller=document.createElement('div');scroller.id='scroll-test';
                scroller.style.cssText='position:fixed;left:200px;top:10px;width:80px;height:80px;overflow:auto;z-index:99999';
                scroller.innerHTML='<div style="height:500px">wheel</div>';document.body.appendChild(scroller);true
                """)
                let wheel = NSEvent(cgEvent: CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                    wheelCount: 1, wheel1: -40, wheel2: 0, wheel3: 0)!)!
                runtime.forwardMouseEvent(wheel, screenPoint: audioWindow!.convertPoint(toScreen: NSPoint(x: 220, y: 200)))
                for _ in 0..<100 {
                    if try await value(runtime, "document.getElementById('scroll-test').scrollTop>0") == "1" { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                check(try await value(runtime, "document.getElementById('scroll-test').scrollTop>0") == "1",
                    "forwarded wheel scrolls the Web control under the desktop pointer")
                playback.updateVideoPlaybackPreferences(.init(isMuted: true), itemID: item.id)
                playback.setMuted(false, displayID: primary.id)
                check(!muted(runtime) && store.effectiveSettings(for: item.id, displayID: primary.id).isMuted == false,
                    "unmute survives a saved per-wallpaper override")
                let project = try AuthorPropertyServices.project(for: item)!
                let overrides = AuthorPropertyServices.shared.store(storage: store.storage)
                try await overrides.set(.string("LIVE SETTINGS"), for: "caption", itemID: item.id, project: project)
                try await overrides.set(.number(80), for: "scale", itemID: item.id, project: project)
                let payload = try await AuthorPropertyServices.payload(item: item, storage: store.storage)
                try playback.updateAuthorProperties(payload, itemID: item.id)
                try await AuthorPropertyServices.shared.applyAndWait(payload, itemID: item.id)
                check(try await value(runtime, "document.getElementById('caption').textContent") == "LIVE SETTINGS", "native override ACK changes real DOM")
                check(try await value(runtime, "document.getElementById('orb').style.width") == "80vmin", "slider changes real page geometry")
                let second = DesktopPlaybackSession(display: primary, item: item, settings: .default,
                    appSettings: store.appSettings, previewOnly: true, authorStorage: store.storage)
                check(second.start() == nil, "second isolated Web host starts")
                var earlyValues = project.resolve(overrides: [:]).values
                earlyValues["caption"] = .string("EARLY UPDATE")
                let early = try AuthorPropertyServices.payload(project: project, values: earlyValues)
                try second.updateAuthorProperties(early)
                let secondRuntime = try await ready(second)
                check(try await value(secondRuntime, "document.getElementById('caption').textContent") == "EARLY UPDATE", "preload edit survives asynchronous initial-store read")
                check(AuthorPropertyServices.shared.readyHosts(itemID: item.id).count == 2, "two same-item hosts registered")
                try await AuthorPropertyServices.shared.applyAndWait(payload, itemID: item.id)
                check(try await value(secondRuntime, "document.getElementById('caption').textContent") == "LIVE SETTINGS", "ACK updates every same-item host")
                second.tearDown()
                check(AuthorPropertyServices.shared.readyHosts(itemID: item.id).count == 1, "closing second host preserves first")
                playback.pauseAll()
                try await Task.sleep(for: .milliseconds(120))
                check(!session.isPlaying, "pause updates native session state")
                check(try await value(runtime, "window.pauseState") == "1", "pause reaches authored callback")
                playback.resumeAll()
                try await Task.sleep(for: .milliseconds(120))
                check(session.isPlaying, "resume restores authored session")
                playback.applyPolicyState(isBlocked: true, displayShouldPlay: { _ in true })
                check(!session.isPlaying, "policy suspends Web session")
                playback.setMuted(true, displayID: primary.id)
                playback.setMuted(false, displayID: primary.id)
                check(!session.isPlaying, "audio changes cannot bypass policy suspension")
                try playback.updateAuthorProperties(payload, itemID: item.id)
                check(!session.isPlaying, "property changes cannot bypass power policy")
                playback.applyPolicyState(isBlocked: false, displayShouldPlay: { _ in true })
                try await Task.sleep(for: .milliseconds(120))
                check(session.isPlaying, "policy release resumes saved intent")
                let assignments = store.assignments
                playback.tearDownAll()
                check(runtime.state == .disposed, "teardown disposes WebKit runtime")
                check(AuthorPropertyServices.shared.readyHosts(itemID: item.id).isEmpty, "teardown unregisters live host")
                check(store.assignments == assignments, "teardown preserves saved assignments")
                store.updateAppSettings { $0.autoApplyOnLaunch = true }
                store.flush()
                let restored = DesktopPlaybackController(store: store, displayRegistry: displays, storage: store.storage, previewOnly: true)
                restored.restoreAssignmentsIfNeeded()
                guard let restoredSession = restored.session(for: primary.id) else { throw WebProjectError.invalid("No restored session") }
                let restoredRuntime = try await ready(restoredSession)
                check(!muted(restoredRuntime), "restored desktop honors the saved unmute setting")
                try await waitForAudio(restoredRuntime)
                check(true, "restored desktop audio autoplays without another gesture")
                check(try await value(restoredRuntime, "document.getElementById('caption').textContent") == "LIVE SETTINGS", "restored desktop consumes saved author overrides")
                check(try Data(contentsOf: fixture) == original, "source project never modified")
                var broken = item; broken.filePath = root.appendingPathComponent("missing/project.json").path
                check(restored.apply(item: broken, to: [primary.id]) != nil, "invalid target reports failure")
                check(restored.session(for: primary.id) === restoredSession, "failed replacement retains working session")
                restored.clear()
                check(restoredRuntime.state == .disposed && store.assignments.isEmpty, "explicit clear releases renderer and assignment")
                let isolated = DesktopPlaybackController(store: store, displayRegistry: displays,
                    storage: store.storage, previewOnly: true, writesToLibrary: false)
                defer { isolated.tearDownAll() }
                let libraryBeforeHTTPS = try Data(contentsOf: store.storage.libraryFile)
                check(isolated.apply(item: item, to: [primary.id]) == nil, "isolated HTTPS preference host starts")
                let offline = try await ready(isolated.session(for: primary.id)!)
                check(!offline.capabilities.remoteResources, "legacy nil permission starts actual desktop runtime offline")
                check(try await requestIsBlockedByCSP(offline), "legacy offline document actually denies HTTPS fetch at CSP")
                isolated.pauseAll()
                isolated.updateWebHTTPS(true, itemID: item.id)
                let onlineSession = isolated.session(for: primary.id)!
                let online = try await ready(onlineSession)
                check(offline.state == .disposed && online !== offline && online.capabilities.remoteResources,
                    "HTTPS switch replaces the real WebKit document with the enabled permission")
                check(try await value(online, "document.querySelector('meta[http-equiv=\"Content-Security-Policy\"]').content.split(';').find(s=>s.trim().startsWith('connect-src')).includes('https:')") == "1",
                    "enabled desktop document has HTTPS connect permission in actual CSP")
                check(!onlineSession.isPlaying && online.state == .paused && onlineSession.settings.isPaused,
                    "HTTPS document replacement preserves isolated user pause intent")
                check(try await !requestIsBlockedByCSP(online), "enabled document permits HTTPS fetch past CSP without external network dependency")
                isolated.resumeAll()
                isolated.applyPolicyState(isBlocked: true, displayShouldPlay: { _ in true })
                isolated.updateWebHTTPS(false, itemID: item.id)
                let disabledSession = isolated.session(for: primary.id)!
                let disabled = try await ready(disabledSession)
                check(!disabled.capabilities.remoteResources && !disabledSession.isPlaying,
                    "disabling HTTPS rebuilds offline while policy suspension remains in effect")
                check(try await value(disabled, "!document.querySelector('meta[http-equiv=\"Content-Security-Policy\"]').content.includes('https:')") == "1",
                    "disabled desktop document removes HTTPS from actual CSP")
                check(try await requestIsBlockedByCSP(disabled), "revoked permission actually denies HTTPS fetch again")
                isolated.applyPolicyState(isBlocked: false, displayShouldPlay: { _ in true })
                for _ in 0..<100 {
                    if disabledSession.isPlaying { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                check(disabledSession.isPlaying, "policy release retains playing intent after HTTPS rebuild")
                check(store.item(withID: item.id)?.webAllowHTTPS == nil && store.assignments.isEmpty,
                    "isolated HTTPS changes preserve library preferences and assignments")
                check(try Data(contentsOf: store.storage.libraryFile) == libraryBeforeHTTPS,
                    "writesToLibrary false HTTPS changes leave persisted library bytes unchanged")
                playback.updateWebHTTPS(true, itemID: item.id)
                let networkRestoredStore = VideoLibraryStore(storage: store.storage)
                let networkRestoredItem = networkRestoredStore.item(withID: item.id)!
                check(networkRestoredItem.webAllowHTTPS == true,
                    "normal controller HTTPS preference persists through an actual store restart")
                let networkRestoredSession = DesktopPlaybackSession(display: primary, item: networkRestoredItem,
                    settings: .default, appSettings: networkRestoredStore.appSettings,
                    previewOnly: true, authorStorage: store.storage)
                defer { networkRestoredSession.tearDown() }
                check(networkRestoredSession.start() == nil, "saved HTTPS item restarts an isolated real desktop host")
                let networkRestoredRuntime = try await ready(networkRestoredSession)
                let restoredHTTPSBlocked = try await requestIsBlockedByCSP(networkRestoredRuntime)
                check(networkRestoredRuntime.capabilities.remoteResources && !restoredHTTPSBlocked,
                    "restarted desktop host enforces the saved HTTPS permission")
                if let path = ProcessInfo.processInfo.environment["GW_WEB_AUDIO_PROJECT"] {
                    let realItem = WallpaperItem(title: "Reported audio project", filePath: path, contentKind: .web, webAllowHTTPS: true)
                    let realSession = DesktopPlaybackSession(display: primary, item: realItem,
                        settings: .init(isPaused: false, isMuted: false, volume: 1, rate: 1, gravity: .fill), appSettings: store.appSettings,
                        previewOnly: true, authorStorage: store.storage)
                    defer { realSession.tearDown() }
                    check(realSession.start() == nil, "reported project starts in an isolated desktop host")
                    let realRuntime = try await ready(realSession)
                    mountAudioHost(realRuntime)
                    var advancing = false
                    for _ in 0..<300 {
                        if try await value(realRuntime, "!!document.getElementById('bgm') && !document.getElementById('bgm').paused && document.getElementById('bgm').currentTime > 0.2") == "1" {
                            advancing = true; break
                        }
                        try await Task.sleep(for: .milliseconds(40))
                    }
                    check(advancing && !muted(realRuntime), "reported wallpaper BGM plays without a gesture and native output is unmuted")
                    print("REPORTED_PROJECT_AUDIO " + (try await value(realRuntime, "JSON.stringify({paused:bgm.paused,time:bgm.currentTime,volume:bgm.volume,muted:bgm.muted})")))
                    var silent = realSession.settings; silent.isMuted = true
                    realSession.apply(settings: silent)
                    check(muted(realRuntime), "reported wallpaper obeys native page mute")
                }
                print("RESULT \(passed) passed, \(failed) failed")
            } catch { failed += 1; print("FAIL integration: \(error)") }
            audioWindow?.orderOut(nil)
            try? FileManager.default.removeItem(at: root)
            exit(failed == 0 ? 0 : 1)
        }
        app.run()
    }
}
