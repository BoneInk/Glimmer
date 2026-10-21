//
//  WebKitVideoPlayer.swift
//  Open Wallpaper Engine
//

import AVFoundation
import WebKit

/// Plays a local video AVFoundation can't decode (WebM: VP8/VP9) through WebKit's `<video>`.
/// The file is opened as WebKit's media document with read access limited to its wallpaper
/// folder; no network is involved. Music sync (`VideoMusicSyncEffect`) styles the `<video>` with
/// CSS and paces its `playbackRate`, from the system audio level delivered while the page is seen.
@MainActor
final class WebKitVideoPlayer: NSObject, WKNavigationDelegate {
    struct State: Equatable {
        var placement: WallpaperPlacement = .fill
        var paused = false
        var muted = true
        var volume: Float = 1
        var rate: Float = 1
    }

    /// Whether `url` goes through WebKit: a local WebM that AVFoundation reports it can't play.
    /// Other types, and a WebM once AVFoundation plays it, stay on the AVFoundation paths.
    nonisolated static func handles(_ url: URL) -> Bool {
        guard url.isFileURL, url.pathExtension.lowercased() == "webm" else { return false }
        return !AVURLAsset.isPlayableExtendedMIMEType("video/webm")
    }

    /// The page playing the video: a WKWebView, or a Chromium browser when the Chromium engine
    /// plays web content (`WebEngineRouting`).
    let page: WebWallpaperPage
    /// The page when WebKit plays it.
    var webView: WKWebView? { page as? WKWebView }
    private var chromiumPage: ChromiumBrowserPage? { page as? ChromiumBrowserPage }
    let url: URL
    /// Bumped per state change, so a retry for an older state stops.
    private var generation = 0
    private var stopped = false
    var state = State() {
        didSet {
            guard state != oldValue else { return }
            apply()
            updateMusicSyncTimer()
        }
    }

    /// The live screen saver draws this page (`ScreenSaverPageSharing`): the video plays, silent,
    /// and counts as seen, whatever `state` and the windows covering it say.
    private(set) var heldForScreenSaver = false

    func holdForScreenSaver(_ hold: Bool) {
        guard hold != heldForScreenSaver else { return }
        heldForScreenSaver = hold
        visibility.heldForScreenSaver = hold
        apply()
        updateMusicSyncTimer()
    }

    /// What the page plays: `state`, or playing and silent while held for the screen saver.
    var shownState: State {
        guard heldForScreenSaver else { return state }
        var shown = state
        shown.paused = false
        shown.muted = true
        if shown.rate <= 0 { shown.rate = 1 }
        return shown
    }

    /// The wallpaper's music-sync amounts; while any is on the level is delivered to the page.
    var musicSync = VideoMusicSyncEffect() {
        didSet { if musicSync != oldValue { updateMusicSyncTimer() } }
    }
    /// Whether the page can be seen: its window is on screen, the displays are awake and it plays.
    /// The music-sync timer runs only then, as a web wallpaper's audio delivery does.
    private var visibility = WebHeartbeatGate()
    private var visibilityObservers: [(NotificationCenter, NSObjectProtocol)] = []
    private var musicSyncTimer: Timer?
    /// Keeps system audio capture on while the music-sync timer runs.
    private var audioCaptureLease: AudioCaptureLease?
    /// The level pace follows (`VideoMusicSyncEffect.paceSmoothing`).
    private var smoothedLevel: Double = 0
    /// Holds pace's `playbackRate` between meaningful steps (`PaceRateLimiter`).
    private var paceLimiter = PaceRateLimiter()
    /// The last music-sync script the page applied, so an unchanged frame isn't sent again. A new
    /// page starts without music sync.
    private var appliedMusicSyncScript = WebKitVideoPlayer.musicSyncScript(nil)

    init(url: URL, readAccess: URL) {
        self.url = url
        let configuration = WKWebViewConfiguration()
        // The media document autoplays with sound unless playback waits for a gesture; the script
        // `apply()` evaluates counts as one, so the video starts muted or not as the state says.
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.allowsAirPlayForMediaPlayback = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        page = webView
        super.init()
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        OWELog.info(.library, "Playing \(url.lastPathComponent) through WebKit")
        observeVisibility()
        // WebKit shows the file as its media document; `apply()` styles and drives its `<video>`.
        webView.loadFileURL(url, allowingReadAccessTo: readAccess)
        apply()
    }

    /// Plays `url` in a Chromium browser, served from `readAccess` through `owe-wallpaper` with
    /// the same containment as a web wallpaper. Chromium shows the file as its media document too.
    init(chromiumPage: ChromiumBrowserPage, url: URL, readAccess: URL) {
        self.url = url
        page = chromiumPage
        super.init()
        OWELog.info(.library, "Playing \(url.lastPathComponent) through Chromium")
        observeVisibility()
        let root = readAccess.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        let relative = path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : url.lastPathComponent
        if let pageURL = WebWallpaperSchemeHandler.url(forRelativePath: relative) {
            // Silent until `apply()` says otherwise: the media document autoplays.
            chromiumPage.setPageMuted(true)
            chromiumPage.load(.init(url: pageURL, directory: readAccess))
        } else {
            OWELog.error(.library, "Can't play \(url.lastPathComponent) through Chromium: invalid path")
        }
        apply()
    }

    func stop() {
        stopped = true
        updateMusicSyncTimer()
        for (center, observer) in visibilityObservers { center.removeObserver(observer) }
        visibilityObservers = []
        page.evaluate("document.querySelectorAll('video').forEach(function(v){v.pause();v.removeAttribute('src');v.load();})")
        webView?.stopLoading()
        chromiumPage?.close()
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { logFailure(error) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { logFailure(error) }
    }

    private func logFailure(_ error: Error) {
        OWELog.error(.library, "WebKit video \(url.lastPathComponent) failed to load: \(error.localizedDescription)")
    }

    /// Applies `state` to the page's `<video>`, retrying until the media document has one (a
    /// media document reports no navigation finish to rely on).
    private func apply() {
        // Chromium mutes the whole page too: its media document starts playing on its own.
        chromiumPage?.setPageMuted(shownState.muted)
        // Chromium stops drawing a paused video's page altogether.
        chromiumPage?.applySchedulingPolicy(muted: shownState.muted, visible: !(shownState.paused || shownState.rate <= 0))
        generation += 1
        attempt(generation)
    }

    /// Retries every 0.1 s, without a limit, until the page has its `<video>`, the player stops
    /// or a newer state replaces this one; a page still without one after `slowAttempts` is logged
    /// (once per state).
    private func attempt(_ generation: Int, count: Int = 0) {
        guard !stopped, generation == self.generation else { return }
        if count == Self.slowAttempts {
            OWELog.debug(.library, "WebKit video \(url.lastPathComponent): no <video> after \(count) tries; still retrying every 0.1 s")
        }
        page.evaluate(Self.script(for: shownState)) { [weak self] result in
            // An error here is the page still loading; the retry covers it.
            guard (result as? Bool) != true else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                MainActor.assumeIsolated { self?.attempt(generation, count: count + 1) }
            }
        }
    }

    /// 5 s of retries.
    private static let slowAttempts = 50

    /// Styles the media document's `<video>` like the AVKit view's gravity and applies playback.
    static func script(for state: State) -> String {
        let objectFit: String
        switch state.placement {
        case .stretch: objectFit = "fill"
        case .fill, .zoom: objectFit = "cover"
        case .fit, .center: objectFit = "contain"
        }
        let volume: Float = min(1, max(0, state.volume))
        let rate: Float = max(0, state.rate)
        let paused: Bool = state.paused || rate <= 0
        return """
        (function(){var v=document.querySelector('video');if(!v)return false;
        v.controls=false;v.loop=true;
        v.style.cssText='position:fixed;left:0;top:0;width:100vw;height:100vh;max-width:none;max-height:none;margin:0;object-fit:\(objectFit);object-position:center';
        v.muted=\(state.muted);v.volume=\(volume);
        if(\(rate)>0){v.defaultPlaybackRate=\(rate);v.playbackRate=\(rate);}
        if(\(paused)){v.pause();}else if(v.paused){v.play().catch(function(){});}
        document.documentElement.style.overflow='hidden';if(document.body){document.body.style.overflow='hidden';}
        if(window.__oweSyncApply){window.__oweSyncApply(v);}
        return true;})()
        """
    }

    // MARK: - Music sync

    /// What music sync does to the picture and pace at one audio level.
    struct MusicSyncFrame: Equatable {
        var zoom: Double
        var tilt: Double
        var saturation: Double
        /// The playback rate with pace on; nil leaves the state's rate.
        var rate: Float?

        init(zoom: Double = 1, tilt: Double = 0, saturation: Double = 1, rate: Float? = nil) {
            self.zoom = zoom
            self.tilt = tilt
            self.saturation = saturation
            self.rate = rate
        }

        /// `effect` at `level`, with pace following `smoothedLevel` for a video playing at `baseRate`.
        init(effect: VideoMusicSyncEffect, level: Double, smoothedLevel: Double, baseRate: Float) {
            self.init(zoom: effect.zoom(at: level), tilt: effect.tilt(at: level),
                      saturation: effect.saturation(at: level),
                      rate: effect.paceAmount != 0 ? effect.rate(base: baseRate, level: smoothedLevel) : nil)
        }
    }

    /// Applies `frame` to the page's `<video>` as the AVKit view does: scale and rotation about the
    /// centre, a saturation filter, and pace as `playbackRate`. nil removes music sync, back to the
    /// rate `script(for:)` set. The frame stays on the page, so `script(for:)` reapplies it.
    nonisolated static func musicSyncScript(_ frame: MusicSyncFrame?) -> String {
        func number(_ value: Double) -> String { String(format: "%.4f", value.isFinite ? value : 0) }
        let payload: String
        if let frame {
            let rate = frame.rate.map { number(Double($0)) } ?? "null"
            payload = "{zoom:\(number(frame.zoom)),tilt:\(number(frame.tilt)),saturation:\(number(frame.saturation)),rate:\(rate)}"
        } else {
            payload = "null"
        }
        return """
        (function(){window.__oweSync=\(payload);
        if(!window.__oweSyncApply){window.__oweSyncApply=function(v){var s=window.__oweSync;
        v.style.transform=s?'scale('+s.zoom+') rotate('+s.tilt+'deg)':'';
        v.style.filter=s&&s.saturation!==1?'saturate('+s.saturation+')':'';
        var r=s&&s.rate!==null?s.rate:v.defaultPlaybackRate;
        if(!v.paused&&v.playbackRate!==r){try{v.playbackRate=r;}catch(e){}}};}
        var v=document.querySelector('video');if(!v)return false;window.__oweSyncApply(v);return true;})()
        """
    }

    /// Runs the 30 Hz level delivery only while music sync is on and the page can be seen; a
    /// hidden page would drop the values, so the timer and its IPC stop too.
    private func updateMusicSyncTimer() {
        visibility.playing = !shownState.paused && shownState.rate > 0
        guard !stopped, musicSync.isActive, visibility.expectsHeartbeats else {
            musicSyncTimer?.invalidate()
            musicSyncTimer = nil
            audioCaptureLease = nil
            // Switched off: the plain picture and rate. A hidden page keeps its last frame.
            if !stopped, !musicSync.isActive { send(nil) }
            return
        }
        guard musicSyncTimer == nil else { return }
        audioCaptureLease = WallpaperServices.shared.acquireAudioCapture()
        // The rate of WE's audio delivery to web wallpapers.
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.deliverMusicSync() }
        }
        RunLoop.main.add(timer, forMode: .common)
        musicSyncTimer = timer
    }

    private func deliverMusicSync() {
        let raw = WallpaperServices.shared.audioLevel
        let level = raw.isFinite ? raw : 0
        smoothedLevel = musicSync.paceAmount != 0
            ? smoothedLevel + (level - smoothedLevel) * VideoMusicSyncEffect.paceSmoothing
            : level
        var frame = MusicSyncFrame(effect: musicSync, level: level, smoothedLevel: smoothedLevel, baseRate: shownState.rate)
        if let rate = frame.rate {
            frame.rate = paceLimiter.rate(for: rate, base: shownState.rate, at: ProcessInfo.processInfo.systemUptime)
        }
        send(frame)
    }

    /// The media element's video and sound share one `playbackRate`, and every change re-times
    /// both (WebKit's pitch-preserving stretch restarts), so pacing it at the 30 Hz frame rate reads
    /// as stutter and warbles the sound. The rate moves only by a real step and at most a few times
    /// a second; a new base rate or a stop (rate 0) goes through at once.
    struct PaceRateLimiter {
        static let step: Float = 0.05
        static let interval: TimeInterval = 0.25
        private var applied: Float?
        private var base: Float?
        private var changedAt: TimeInterval = -.infinity

        mutating func rate(for target: Float, base: Float, at time: TimeInterval) -> Float {
            if let applied, self.base == base, target != 0 || applied == 0,
               abs(target - applied) < Self.step || time - changedAt < Self.interval {
                return applied
            }
            applied = target
            self.base = base
            changedAt = time
            return target
        }
    }

    /// Sends `frame` unless the page already shows it; a page without its `<video>` yet gets it again.
    private func send(_ frame: MusicSyncFrame?) {
        let script = Self.musicSyncScript(frame)
        guard script != appliedMusicSyncScript else { return }
        page.evaluate(script) { [weak self] result in
            // An error here is the page still loading; the next frame is sent anyway.
            guard (result as? Bool) == true else { return }
            MainActor.assumeIsolated { self?.appliedMusicSyncScript = script }
        }
    }

    /// Tracks what hides the page: an occluded window and sleeping displays (system sleep also
    /// sleeps the displays), as `WebWallpaperViewModel` does for web wallpapers.
    private func observeVisibility() {
        let workspace = NSWorkspace.shared.notificationCenter
        let displays: [(Notification.Name, Bool)] = [
            (NSWorkspace.screensDidSleepNotification, false), (NSWorkspace.screensDidWakeNotification, true),
            (NSWorkspace.willSleepNotification, false), (NSWorkspace.didWakeNotification, true),
            (NSWorkspace.sessionDidResignActiveNotification, false), (NSWorkspace.sessionDidBecomeActiveNotification, true),
        ]
        for (name, awake) in displays {
            let observer = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.visibility.displaysAwake = awake
                    self?.updateMusicSyncTimer()
                }
            }
            visibilityObservers.append((workspace, observer))
        }
        let center = NotificationCenter.default
        let occlusion = center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil,
                                           queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, let window = notification.object as? NSWindow,
                      window === self.page.hostWindow else { return }
                self.visibility.windowVisible = window.occlusionState.contains(.visible)
                self.updateMusicSyncTimer()
            }
        }
        visibilityObservers.append((center, occlusion))
    }
}
