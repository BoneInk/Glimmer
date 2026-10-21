import Cocoa
import Combine
import MetalKit
import OWESceneEditing

/// What a running scene reads from the app: the displays' wallpapers and the playback controls,
/// the user's quality and frame-rate settings, and the services every scene's scripts share.
struct SceneWallpaperEnvironment {
    weak var wallpapers: WallpaperViewModel?
    let settings: GlobalSettingsViewModel
    let scriptServices: SceneScriptServices?
    /// This launch's loading snapshots (`SceneLoadingSnapshotSession`); nil takes none.
    var loadingSnapshots: SceneLoadingSnapshotSession? = nil
}

/// One scene (or Metal video) wallpaper, running once for every display that shows it
/// (docs/architecture.md "Wallpaper instances"): it loads and builds the scene once, and has one
/// renderer with one script runtime, one particle, timeline and animation state, one effect graph
/// and one set of sound layers, so its sound plays once. Each display is a thin presenter
/// (`SceneWallpaperPresenter`): the display with the highest frame rate renders the frames
/// (`SceneFrameSchedule`), at the largest scene target the displays need, and every display
/// presents them at its own size.
/// Rendering runs on the instance's own render thread (`SceneRenderLoop`); this half stays on the
/// main thread and sends it what the app's controls, windows and displays change.
@MainActor
final class SceneWallpaperInstance {
    private struct Display {
        weak var view: MTKView?
        /// The display it is on, whose playback rules decide whether it draws.
        let screenID: String
    }

    let key: WallpaperInstanceKey
    let viewModel: SceneContentLoader
    /// The render-thread half: it owns the renderer and draws the displays.
    let renderLoop: SceneRenderLoop
    /// Nil when Metal can't make one; the displays then stay black. Render thread only (tests reach
    /// it through `renderLoop.thread.sync`).
    var renderer: SceneMetalRenderer? { renderLoop.renderer }
    /// A display drew the live scene (set on main after the render thread's first frame).
    var hasContent = false
    /// Screens that only preview the wallpaper (Scene Edit / Export's iPhone mode): they never make
    /// it audible.
    static let previewScreenIDs: Set<String> = ["iphone-preview"]

    /// Silent while previews are its only users; audible as usual once any display shows it.
    static func isPreviewOnly(screenIDs: [String]) -> Bool {
        !screenIDs.isEmpty && screenIDs.allSatisfy { previewScreenIDs.contains($0) }
    }

    private var isPreviewOnly: Bool { Self.isPreviewOnly(screenIDs: displays.values.map(\.screenID)) }
    private let hasRenderer: Bool
    private let environment: SceneWallpaperEnvironment
    private var displays: [ObjectIdentifier: Display] = [:]
    /// The render settings last sent to the renderer.
    private var sentRenderSettings = SceneRenderSettings()
    private var metalRevision = -1
    private var observers: [NSObjectProtocol] = []
    private var cancellables = Set<AnyCancellable>()
    private var pendingImpact: SceneChangeImpact = .none
    private var pendingUpdate: DispatchWorkItem?
    /// A property change was applied while the user edited properties: the content is rebuilt once
    /// editing ends, to exactly what a fresh load draws.
    private var appliedLive = false
    /// The Wallpaper Editor's latest overlay of this wallpaper and the scene's structure it reads
    /// over, while the editor is sending them: drawn live against the overlay the loaded scene was
    /// read with (`SceneWallpaperInstance+EditorLive`).
    var editorEdits: (overlay: SceneEditOverlay, base: SceneOutline)?
    /// How a picture that is previewed here and rendered elsewhere draws, the same in both (the
    /// iPhone & iPad Export's preview, `LivePhotoRenderer.presentation`): its own placement
    /// instead of the user's, a fixed pointer instead of the mouse, and its clock layers shown or
    /// not. Nil for a display's wallpaper.
    struct Presentation: Equatable {
        var placement: WallpaperPlacement
        /// `SceneMetalRenderer.fixedPointer`.
        var pointer: SIMD2<Float>
        var hidesClockLayers: Bool

        /// Render thread.
        func apply(to renderer: SceneMetalRenderer) {
            renderer.setPlacement(placement)
            renderer.fixedPointer = pointer
            renderer.hidesClockLayers = hidesClockLayers
        }
    }

    /// Set before the instance is shown; a change applies on the next `update()` (the export's
    /// Parallax Position moves the pointer while it is dragged).
    var presentation: Presentation?
    /// Called on the main thread with each content the instance loads (the export's Parallax
    /// Position shows only for a scene that follows the pointer, `LivePhotoParallax`).
    var onContent: ((SceneMetalContent) -> Void)?
    /// Objects a structural property change rebuilds alone, and the pending rebuild.
    private var pendingObjects = Set<Int>()
    private var pendingObjectRebuild: DispatchWorkItem?
    private var scriptsNotice: SafeRestartNotice?
    private var cursorMonitors: [Any] = []
    private var powerObserver: UUID?
    /// Refreshes the scene's loading snapshots; nil for a video or without a session.
    private let snapshotCapture: SceneLoadingSnapshotCapture?

    /// Where the displays find the picture to show while the scene loads; nil for a video.
    var loadingSnapshotStore: SceneLoadingSnapshotStore? { snapshotCapture == nil ? nil : environment.loadingSnapshots?.store }

    /// `screenID` is the display that starts it; its scripts keep their per-display storage there.
    /// `properties` is the store of user properties it runs with (`WallpaperInstanceKey.properties`).
    /// `followsLiveResize`: it is shown in a resizable window, not on a desktop
    /// (`SceneMetalRenderer.followsLiveResize`).
    init(wallpaper: WEWallpaper, environment: SceneWallpaperEnvironment, screenID: String,
         properties: WallpaperPropertyScope = .shared, followsLiveResize: Bool = false) {
        key = WallpaperInstanceKey(wallpaper, properties: properties)
        // Loaded on the preparation pool: the displays show the preview until the scene is ready.
        viewModel = SceneContentLoader(wallpaper: wallpaper, propertyScope: properties, loadsInBackground: true)
        self.environment = environment
        let renderer = SceneMetalRenderer(pixelFormat: .bgra8Unorm, scriptServices: environment.scriptServices,
                                          screenID: screenID)
        renderer?.followsLiveResize = followsLiveResize
        hasRenderer = renderer != nil
        if renderer == nil {
            OWELog.error(.scene, "\(wallpaper.project.title): Metal renderer unavailable; the wallpaper can't be drawn")
        }
        let isScene = wallpaper.project.type.caseInsensitiveCompare("scene") == .orderedSame
        snapshotCapture = isScene ? environment.loadingSnapshots.map {
            SceneLoadingSnapshotCapture(wallpaperDirectory: wallpaper.wallpaperDirectory, session: $0)
        } : nil
        renderLoop = SceneRenderLoop(renderer: renderer, name: "OWE render \(wallpaper.project.title)",
                                     snapshots: snapshotCapture)
        // Set up before any frame; from here on only the render thread touches the renderer.
        configureRenderer(renderer)
        renderLoop.onLoanChanged = { [weak self] in self?.updateVideoPlayback() }
        observeChanges()
        metalRevision = viewModel.metalRevision
        loadContent()
    }

    /// Stops everything: the scripts, the sound layers, a video's stream, the render thread. The
    /// registry calls it once no display shows the wallpaper.
    func shutdown() {
        pendingUpdate?.cancel()
        pendingUpdate = nil
        pendingObjectRebuild?.cancel()
        pendingObjectRebuild = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        for monitor in cursorMonitors { NSEvent.removeMonitor(monitor) }
        cursorMonitors.removeAll()
        if let powerObserver { PowerPolicyMonitor.shared.removeObserver(powerObserver) }
        powerObserver = nil
        cancellables.removeAll()
        scriptsNotice?.close()
        scriptsNotice = nil
        // Built layers hold the video stream and the sound layers, so the renderer has to let go
        // of them or the soundtrack outlives the wallpaper.
        renderLoop.perform { $0.releaseContent() }
        renderLoop.shutdown()
        displays.removeAll()
    }

    // MARK: - Displays

    /// `presenter` shows this wallpaper in `view`, on the display `screenID`, from now on.
    func attach(_ presenter: SceneWallpaperPresenter, view: MTKView, screenID: String) {
        let id = ObjectIdentifier(presenter)
        // The view's setup is main-thread work, done before its link draws it on the render thread.
        renderer?.configure(view)
        displays[id] = Display(view: view, screenID: screenID)
        // The link takes over (the view's own timer stops) before the view has a delegate to draw.
        renderLoop.attach(id, view: view, state: SceneRenderLoop.DisplayState(refresh: Self.refreshRate(of: view)))
        view.delegate = presenter
        update()
    }

    /// The view's link stops on the render thread; the view keeps its delegate (the presenter,
    /// which the view doesn't retain), so a draw already running there still finishes.
    func detach(_ presenter: SceneWallpaperPresenter) {
        let id = ObjectIdentifier(presenter)
        renderLoop.detach(id)
        displays[id] = nil
        // A display leaving a preview alone silences it.
        let sound = soundTarget
        renderLoop.perform { $0.sounds.setTarget(level: sound.level, audible: sound.audible) }
    }

    var displayCount: Int { displays.count }

    private static func refreshRate(of view: MTKView) -> Int {
        let refresh = view.window?.screen?.maximumFramesPerSecond ?? 60
        return refresh > 0 ? refresh : 60
    }

    // MARK: - Frame pacing

    /// Something that changes the picture happened: tick at `demand`'s rate from the next refresh.
    private func wakePacing(_ demand: FrameDemand) {
        // Thread boundary: main → render thread.
        renderLoop.thread.perform { [renderLoop] in renderLoop.wake(demand) }
    }

    /// A cursor move wakes an idle or slow scene at once (the displays' draws only poll the
    /// cursor, at the rate they tick). Mouse monitors need no permission.
    private func observeCursor() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        let wake: () -> Void = { [weak self] in
            MainActor.assumeIsolated { self?.wakePacing(.interactive) }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { _ in wake() }) {
            cursorMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in wake(); return event }) {
            cursorMonitors.append(local)
        }
    }

    /// Drawables a wallpaper's layer may have in flight. Up to 60 fps a frame has a whole refresh
    /// to finish, so two are enough and the third's memory (a full-screen texture) is saved; faster
    /// pacing keeps three so the GPU never waits on the display.
    nonisolated static func maximumDrawableCount(forRate rate: Int) -> Int {
        rate <= 60 ? 2 : 3
    }

    // MARK: - Updates

    /// Follows the app's controls: a rebuilt content, the placement, playback, the sound's gain, the
    /// frame rate and pause. Displays call it when SwiftUI updates them. The render thread applies
    /// the pause and each display's state (`SceneRenderLoop.applyPlayback`): a paused wallpaper
    /// eases its clock to a stop first; a display the rules pause, or that is asleep or covered,
    /// keeps its last frame at once while the others play.
    /// The Wallpaper Editor's Low FPS Simulation: its canvas drawn at most this many frames a
    /// second (WE's editor: 22, wallpaperui.exe 0x140088b6e); nil for no cap of its own.
    var frameRateCap: Int? {
        didSet {
            guard frameRateCap != oldValue else { return }
            let limits = frameLimits(environment.settings.effectiveSettings)
            // Thread boundary: main → render thread.
            renderLoop.perform { $0.framePacing.limits = limits }
        }
    }

    /// The pacing's limits for `settings`, the power policy's cap and `frameRateCap` included.
    private func frameLimits(_ settings: GlobalSettings) -> FramePacing.Limits {
        var limits = FramePacing.Limits(settings, power: PowerPolicyMonitor.shared.policy)
        if let cap = frameRateCap { limits.powerCap = min(limits.powerCap ?? cap, cap) }
        return limits
    }

    func update() {
        guard let wallpapers = environment.wallpapers else { return }
        if metalRevision != viewModel.metalRevision {
            metalRevision = viewModel.metalRevision
            loadContent()
        }
        // A display that joined or changed size can change WE's automatic texture resolution.
        applyRenderSettings(renderSettings(for: environment.settings.effectiveSettings))
        updateVideoPlayback()
        var playback = SceneRenderLoop.Playback()
        for (id, display) in displays {
            guard let view = display.view else { continue }
            SceneViewSnapshots.refresh(view)
            // Asleep or covered: by the window server's occlusion, or by windows tiling the
            // display, which the window server still counts as showing it (`isCovered`).
            let hidden = (view.window.map { !$0.occlusionState.contains(.visible) } ?? false)
                || wallpapers.isCovered(display.screenID)
            playback.displays[id] = SceneRenderLoop.DisplayState(plays: wallpapers.playback(onScreen: display.screenID).rendersFrames,
                                                                 hidden: hidden, refresh: Self.refreshRate(of: view))
        }
        playback.paused = wallpapers.playRate == 0 || !playback.displays.values.contains { $0.plays }
        // Scene video textures decode only while some display shows the wallpaper playing.
        let shown = playback.displays.values.contains { $0.plays && !$0.hidden }
        viewModel.setEmbeddedVideoRate(playback.paused || !shown ? 0 : wallpapers.playRate)
        let presentation = presentation
        let placement = wallpapers.wallpaperPlacement
        let sound = soundTarget
        let limits = frameLimits(environment.settings.effectiveSettings)
        // Thread boundary: main → render thread (applied before the playback, which reads the rate).
        renderLoop.perform { renderer in
            if let presentation { presentation.apply(to: renderer) } else { renderer.setPlacement(placement) }
            renderer.sounds.setTarget(level: sound.level, audible: sound.audible)
            renderer.framePacing.limits = limits
        }
        renderLoop.update(playback)
    }

    func loadContent() {
        viewModel.contentAsync { [weak self] content in
            guard let self else { return }
            // Thread boundary: main → render thread.
            let live = self.editorLiveValues()
            self.renderLoop.perform {
                $0.setContent(content)
                $0.setEditorLiveValues(live)
            }
            self.updateVideoPlayback()
            if let content { self.onContent?(content) }
        }
    }

    /// `videoStream` is only built inside `contentAsync`, so the first playback update after a
    /// video wallpaper starts finds none; called again once the content lands, so playback starts.
    private func updateVideoPlayback() {
        guard SceneContentLoader.isVideoType(viewModel.currentWallpaper.project.type),
              let wallpapers = environment.wallpapers else { return }
        // The wallpaper's own playback rate (WE's per-wallpaper option) scales the app's.
        let displayRate = wallpapers.displayPlaybackRate(of: viewModel.currentWallpaper)
        // Lent to the screen saver: the video plays for it (at the last speed while paused),
        // silent, whatever the rules say (the lock pauses the desktop).
        let lent = renderLoop.isLent
        let speed = lent && wallpapers.playRate <= 0 ? (wallpapers.lastPlayRate > 0 ? wallpapers.lastPlayRate : 1) : wallpapers.playRate
        let rendering = lent || wallpapers.playback(of: key).rendersFrames
        viewModel.updateVideoPlayback(playRate: rendering ? speed * displayRate : 0,
                                      audioRate: wallpapers.audioPlayRate * displayRate,
                                      audioLevel: WallpaperServices.shared.audioLevel,
                                      audioEnabled: !lent && wallpapers.playsAudio(for: key) && wallpapers.wallpaperPlayback(of: key).playsSound,
                                      volume: wallpapers.playVolume)
    }

    private var sceneMusicEnabled: Bool {
        let key = "SceneMusicEnabled.\(viewModel.currentWallpaper.wallpaperDirectory.path)"
        return UserDefaults.app.object(forKey: key) == nil ? true : UserDefaults.app.bool(forKey: key)
    }

    private var sceneMusicVolume: Float {
        let key = "SceneMusicVolume.\(viewModel.currentWallpaper.wallpaperDirectory.path)"
        guard UserDefaults.app.object(forKey: key) != nil else { return 1 }
        return Float(UserDefaults.app.double(forKey: key))
    }

    /// The wallpaper's sound (`SceneSoundLayers.setTarget`): its level, the app's volume times this
    /// wallpaper's music volume, which applies at once, and whether it is heard, which fades: not
    /// with the app's audio output off, or while muted, paused or with its music turned off, as
    /// WE's wallpaper volume fades to 0 then. A wallpaper running as several instances (displays
    /// with different properties) plays from one of them. The playback rules silence it only when
    /// every display showing the wallpaper is muted, paused or stopped.
    private struct SoundTarget {
        var level: Float
        var audible: Bool
    }

    private var soundTarget: SoundTarget {
        guard let wallpapers = environment.wallpapers else { return SoundTarget(level: 0, audible: false) }
        let level = wallpapers.playVolume * sceneMusicVolume
        let audible = !isPreviewOnly && wallpapers.playsAudio(for: key) && sceneMusicEnabled && wallpapers.playRate != 0
            && wallpapers.wallpaperPlayback(of: key).playsSound
        return SoundTarget(level: level, audible: audible)
    }

    // MARK: - Setup

    /// Sets the renderer up before any frame (no frame runs until a display attaches).
    private func configureRenderer(_ renderer: SceneMetalRenderer?) {
        guard let renderer else { return }
        renderer.runsInEditor = runsEditorDraft
        renderer.sounds.setTarget(level: soundTarget.level, audible: soundTarget.audible)
        renderer.scripts.onHalt = { [weak self] error in
            // Thread boundary: `take()` reports it from the renderer's draw, on the render thread.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.showScriptsHalted(error: error) } }
        }
        // The watchdog judges the wallpapers the displays show (`SafeRestart`'s session), so only
        // an instance a display can run reports to it. An isolated one (Scene Edit / Export's
        // iPhone & iPad, Android and Screen Saver previews, the Wallpaper Editor's draft) never
        // runs on a display: its frames, slow while it previews an export's framing, would
        // otherwise be blamed on the desktop's wallpapers.
        if !key.properties.isIsolated, let watchdog = environment.wallpapers?.renderWatchdog {
            // One frame time per rendered frame, however many displays show it (the watchdog locks).
            renderer.frameTimeObserver = { watchdog.recordFrame(duration: $0) }
        }
        // The quality settings (the user's, or the battery's): the renderer reads them per frame,
        // the content is built for them.
        let renderSettings = renderSettings(for: environment.settings.effectiveSettings)
        renderer.renderSettings = renderSettings
        sentRenderSettings = renderSettings
        viewModel.setRenderSettings(renderSettings)
    }

    /// `settings` for this scene's displays: WE's automatic texture resolution follows the largest
    /// and the scene's size.
    private func renderSettings(for settings: GlobalSettings) -> SceneRenderSettings {
        let largest = displays.values.reduce(SIMD2<Float>(repeating: 0)) { largest, display in
            guard let view = display.view else { return largest }
            return simd_max(largest, SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height)))
        }
        return SceneRenderSettings(settings, outputPixels: largest, sceneSize: viewModel.textureReductionSceneSize)
    }

    /// Applies `settings` when they differ from the renderer's, rebuilding the content only when
    /// it is built for what changed (`SceneRenderSettings.contentKey`); the rest apply per frame.
    private func applyRenderSettings(_ settings: SceneRenderSettings) {
        guard hasRenderer, settings != sentRenderSettings else { return }
        let rebuild = settings.contentKey != sentRenderSettings.contentKey
        sentRenderSettings = settings
        // Thread boundary: main → render thread.
        renderLoop.perform { $0.renderSettings = settings }
        viewModel.setRenderSettings(settings)
        if rebuild { scheduleSceneUpdate(.rebuildContent) }
    }

    private func observeChanges() {
        let center = NotificationCenter.default
        observeCursor()
        // A display falling asleep or being covered, or coming back, changes which displays draw.
        observers.append(center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main) { [weak self] notification in
            let window = notification.object as? NSWindow
            MainActor.assumeIsolated {
                guard let self, self.displays.values.contains(where: { $0.view?.window === window }) else { return }
                self.update()
            }
        })
        observers.append(center.addObserver(forName: .coveredScreensDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        })
        // N10: thermal state and Low Power Mode move the slider's effective stop.
        powerObserver = PowerPolicyMonitor.shared.observe { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.update() } }
        }
        observers.append(center.addObserver(forName: .sceneUserPropertiesDidChange, object: nil, queue: .main) { [weak self] notification in
            let keys = notification.userInfo?["keys"] as? [String] ?? []
            let store = notification.userInfo?["wallpaper"] as? String
            MainActor.assumeIsolated {
                // Another wallpaper's, or another display's, properties.
                guard let self, store == nil || store == self.viewModel.propertyStoreKey else { return }
                // Scripts get every change (`applyUserProperties`). The bindings that read the
                // properties (`UserPropertyBindingTable`) decide the rest: uniform and object values
                // apply in place under a new binding revision, a structural change rebuilds only its
                // object, and only the app's own keys and scene-wide structure rebuild the content.
                let changed = Set(keys)
                let update = self.viewModel.bindingUpdate(for: keys)
                self.renderLoop.perform { $0.userPropertiesDidChange(changed, owners: update.owners) }
                // The picture changes: the loading snapshots follow once it has shown a while.
                self.snapshotCapture?.rearm()
                self.wakePacing(.slow)
                if WallpaperServices.shared.propertyEditing.isActive, !update.isEmpty { self.appliedLive = true }
                if !update.rebuild.isEmpty { self.scheduleObjectRebuild(update.rebuild) }
                guard update.impact > .none else { return }
                self.scheduleSceneUpdate(update.impact)
            }
        })
        // Editing ended: a content that took changes while editing is rebuilt once, in the
        // background, to exactly what a fresh load of the current properties draws (the reconcile).
        observers.append(center.addObserver(forName: .scenePropertyEditingDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !WallpaperServices.shared.propertyEditing.isActive, self.appliedLive else { return }
                self.appliedLive = false
                self.scheduleSceneUpdate(.rebuildContent)
            }
        })
        observers.append(center.addObserver(forName: .workshopDependenciesDidInstall, object: nil, queue: .main) { [weak self] notification in
            let directory = notification.userInfo?["wallpaperDirectory"] as? URL
            MainActor.assumeIsolated {
                guard let self,
                      directory == self.viewModel.currentWallpaper.wallpaperDirectory.standardizedFileURL else { return }
                self.scheduleSceneUpdate(.reloadScene)
            }
        })
        // The Wallpaper Editor changed this wallpaper's overlay: a change of values the renderer
        // takes per frame is drawn live (`SceneEditLiveValues`); anything else reads the scene again
        // with it (`ScenePreparation`), through the same coalesced reload as an Inspector JSON edit.
        observers.append(center.addObserver(forName: .sceneEditOverlayDidChange, object: nil, queue: .main) { [weak self] notification in
            let info = notification.userInfo
            let directory = info?["wallpaperDirectory"] as? URL
            let overlay = info?["overlay"] as? SceneEditOverlay, base = info?["base"] as? SceneOutline
            let transient = info?["transient"] as? Bool ?? false
            let draft = info?["draft"] as? Bool ?? false
            MainActor.assumeIsolated {
                guard let self,
                      self.runsWallpaper(in: directory), self.runsEditorDraft == draft else { return }
                self.snapshotCapture?.rearm()
                self.wakePacing(.slow)
                if self.applyEditorEdits(overlay: overlay, base: base) { return }
                // A drag in progress the renderer can't draw live waits for its commit.
                guard !transient else { return }
                self.scheduleSceneUpdate(.reloadScene)
            }
        })
        // The particle editor changed documents particle systems read (or restarts one): only
        // the systems that read them are built again (`rebuildObjects`), the rest keeps running.
        observers.append(center.addObserver(forName: .sceneEditParticlesDidChange, object: nil, queue: .main) { [weak self] notification in
            let directory = notification.userInfo?["wallpaperDirectory"] as? URL
            let assets = notification.userInfo?["assets"] as? [String: Data] ?? [:]
            let paths = Set(notification.userInfo?["paths"] as? [String] ?? [])
            let objectIDs = Set(notification.userInfo?["objectIDs"] as? [Int] ?? [])
            let draft = notification.userInfo?["draft"] as? Bool ?? false
            MainActor.assumeIsolated {
                guard let self,
                      self.runsWallpaper(in: directory), self.runsEditorDraft == draft else { return }
                self.viewModel.setEditorAssets(assets)
                self.snapshotCapture?.rearm()
                self.wakePacing(.slow)
                if !objectIDs.isEmpty { self.scheduleObjectRebuild(objectIDs) }
                guard !paths.isEmpty else { return }
                self.viewModel.particleObjectIDsAsync(using: paths) { [weak self] ids in
                    MainActor.assumeIsolated {
                        guard let self, !ids.isEmpty else { return }
                        self.scheduleObjectRebuild(ids)
                    }
                }
            }
        })
        observers.append(center.addObserver(forName: .sceneMusicSettingsDidChange, object: nil, queue: .main) { [weak self] notification in
            let path = notification.userInfo?["path"] as? String
            MainActor.assumeIsolated {
                guard let self, path == nil || path == self.viewModel.currentWallpaper.wallpaperDirectory.path else { return }
                let sound = self.soundTarget
                self.renderLoop.perform { $0.sounds.setTarget(level: sound.level, audible: sound.audible) }
            }
        })
        // Zoom/tilt/saturation amounts are baked into the layer when content is built, so the
        // toggles do nothing until the content is rebuilt.
        observers.append(center.addObserver(forName: .videoMusicSyncSettingsDidChange, object: nil, queue: .main) { [weak self] notification in
            let path = notification.userInfo?["path"] as? String
            MainActor.assumeIsolated {
                guard let self, path == nil || path == self.viewModel.currentWallpaper.wallpaperDirectory.path else { return }
                self.viewModel.invalidateContent()
            }
        })
        // The settings, or the battery quality switching on or off: applied in place, the content
        // rebuilt only for what it is built for.
        environment.settings.$effectiveSettings
            .dropFirst()
            .sink { [weak self] settings in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.applyRenderSettings(self.renderSettings(for: settings))
                    let limits = self.frameLimits(settings)
                    // Thread boundary: main → render thread.
                    self.renderLoop.perform { $0.framePacing.limits = limits }
                }
            }
            .store(in: &cancellables)
        // A rebuilt content (a new revision) or a video that changed shape: the displays used to
        // pick it up through SwiftUI; the instance follows it itself, after the change lands.
        viewModel.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.update() } }
            .store(in: &cancellables)
    }

    /// Coalesces bursts of property changes (e.g. dragging a slider) into one rebuild,
    /// escalating to a full re-parse only when some key in the burst demands it.
    private func scheduleSceneUpdate(_ impact: SceneChangeImpact) {
        pendingImpact = Swift.max(pendingImpact, impact)
        pendingUpdate?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let resolved = self.pendingImpact
                self.pendingImpact = .none
                if resolved == .reloadScene {
                    // The reload runs in the background; its commit bumps the revision, and
                    // `update()` then builds the content. The current content stays until then.
                    self.viewModel.reloadCurrentScene()
                    return
                } else {
                    // Content is memoised against metalRevision, so without this the rebuild
                    // would just hand back the pre-change scene.
                    self.viewModel.invalidateContent()
                }
                self.metalRevision = self.viewModel.metalRevision
                self.loadContent()
            }
        }
        pendingUpdate = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    /// Coalesces a burst of structural property changes into one rebuild of the objects they touch,
    /// built on the content queue and swapped in by the renderer (`SceneObjectReplacement`). A
    /// whole-content update pending or landing meanwhile builds them too; objects that can't be
    /// rebuilt alone rebuild the content.
    private func scheduleObjectRebuild(_ ids: Set<Int>) {
        pendingObjects.formUnion(ids)
        pendingObjectRebuild?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let ids = self.pendingObjects
                self.pendingObjects.removeAll()
                guard self.pendingImpact == .none, !ids.isEmpty else { return }
                let revision = self.viewModel.metalRevision
                self.viewModel.rebuildObjectsAsync(ids) { [weak self] replacement in
                    MainActor.assumeIsolated {
                        guard let self, self.viewModel.metalRevision == revision else { return }
                        guard let replacement else { return self.scheduleSceneUpdate(.rebuildContent) }
                        self.renderLoop.perform { $0.replaceObjects(replacement) }
                    }
                }
            }
        }
        pendingObjectRebuild = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    // MARK: - Scripts halted

    /// The watchdog stopped this wallpaper's scripts (a script ran past WE's 15 s): the
    /// wallpaper keeps showing their last values. Says so without blocking, like SafeRestart;
    /// Retry reloads the wallpaper, which starts its scripts again.
    private func showScriptsHalted(error: SceneScriptError?) {
        let title = viewModel.currentWallpaper.project.title
        OWELog.error(.script, "\(title): scripts stopped by the watchdog\(error.map { " in \($0.scriptID)" } ?? "")")
        let message = String(localized: """
        The scripts of “\(title)” were stopped because one of them ran for too long. The wallpaper \
        keeps showing, without its scripted animations.
        """)
        scriptsNotice?.close()
        scriptsNotice = SafeRestartNotice(
            message: message,
            onRetry: { [weak self] in
                guard let self else { return }
                self.dismissScriptsNotice()
                // A new document signature is not needed: dropping the content stops the halted
                // scripts, and the reload starts new ones.
                self.renderLoop.perform { $0.releaseContent() }
                self.scheduleSceneUpdate(.reloadScene)
            },
            onDismiss: { [weak self] in self?.dismissScriptsNotice() })
        scriptsNotice?.show()
    }

    private func dismissScriptsNotice() {
        scriptsNotice?.close()
        scriptsNotice = nil
    }
}
