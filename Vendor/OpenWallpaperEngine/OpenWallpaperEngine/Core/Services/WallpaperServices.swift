import Cocoa

extension Notification.Name {
    static let sceneUserPropertiesDidChange = Notification.Name("SceneUserPropertiesDidChange")
    static let audioCapturePermissionMissing = Notification.Name("AudioCapturePermissionMissing")
    static let videoMusicSyncAudioLevelDidChange = Notification.Name("VideoMusicSyncAudioLevelDidChange")
    static let videoMusicSyncSettingsDidChange = Notification.Name("VideoMusicSyncSettingsDidChange")
    static let sceneMusicSettingsDidChange = Notification.Name("SceneMusicSettingsDidChange")
}

/// The app's system audio capture and the user properties of every running wallpaper instance,
/// shared by scene, video and web wallpapers. SceneScript itself runs per wallpaper instance in a
/// `SceneScriptRuntime` (docs/scenescript-plan.md WP11).
final class WallpaperServices {
    static let shared = WallpaperServices()

    /// System audio capture: the level and WE's spectrum analyzer.
    let audioCapture: SystemAudioCapture
    /// Per-wallpaper user properties and their music-synced modulation.
    let propertyService: SceneUserPropertyService
    /// Whether a window that edits wallpaper properties is open.
    @MainActor let propertyEditing = ScenePropertyEditing()
    /// Where wallpaper sound plays: the default output device without its inputs, so playing
    /// never asks for the microphone (`OutputOnlyAudioDevice`). Video players use it in unit
    /// tests too: a test host is the app, so a player there on a headset's output asked for the
    /// microphone, again for every freshly signed build. Nil without an output device (logged).
    let soundOutput: OutputOnlyAudioDevice?
    /// The app process's scene output; the helper's is made only on the user's explicit intent
    /// (`enableBackendSceneSoundOutput`), so a preload or export stays silent.
    private let appSceneSoundOutput: OutputOnlyAudioDevice?
    private let backendSoundLock = NSLock()
    private var backendSceneSoundOutput: OutputOnlyAudioDevice?

    private init() {
        let capture = SystemAudioCapture()
        audioCapture = capture
        propertyService = SceneUserPropertyService(audioLevel: { capture.audioLevel })
        let output = SceneBackendRuntimeContext.isActive ? nil : OutputOnlyAudioDevice()
        soundOutput = output
        appSceneSoundOutput = AppHostContext.current.isTestHost ? nil : output
    }

    /// Where scene sound layers play live (`SceneSoundMixer`): the app's output, or the helper's
    /// output once the user asked for scene sound. Nil keeps the layers silent.
    var sceneSoundOutput: OutputOnlyAudioDevice? {
        if SceneBackendRuntimeContext.isActive {
            backendSoundLock.lock(); defer { backendSoundLock.unlock() }
            return backendSceneSoundOutput
        }
        return appSceneSoundOutput
    }

    /// The helper's opt-in: called by the backend facade only after the app forwards the user's
    /// explicit scene-music intent. Output-only, so it never asks for microphone access.
    func enableBackendSceneSoundOutput() {
        guard SceneBackendRuntimeContext.isActive else { return }
        backendSoundLock.lock()
        if backendSceneSoundOutput == nil { backendSceneSoundOutput = OutputOnlyAudioDevice() }
        backendSoundLock.unlock()
    }

    /// Starts capture if a capture permission was granted since the last check. Never prompts, so it is
    /// safe to call whenever the app activates or the Permissions page appears.
    @MainActor
    func recheckCapturePermission() {
        audioCapture.recheckCapturePermission()
    }

    /// Sets the user properties of one wallpaper instance (keyed by its directory path). With
    /// `replacing`, properties missing from `values` are dropped, so nothing from a previous
    /// configuration of that wallpaper lingers.
    func setUserProperties(_ values: [String: String], wallpaper: String, replacing: Bool) {
        propertyService.setUserProperties(values, wallpaper: wallpaper, replacing: replacing)
    }

    // MARK: - Frame snapshot

    /// Starts a frame of `wallpaper` (its directory path): reads until `endFrame` see that
    /// wallpaper's user properties, so per-layer reads stop contending with the audio thread.
    func beginFrame(wallpaper: String) {
        OWEFrameMetrics.countLockAcquisition()
        propertyService.beginFrame(wallpaper: wallpaper)
    }

    func endFrame() {
        propertyService.endFrame()
    }

    func userPropertyValue(_ key: String, fallback: Float) -> Float {
        propertyService.userPropertyValue(key, fallback: fallback)
    }

    func isMusicSynced(_ key: String) -> Bool {
        propertyService.isMusicSynced(key)
    }

    func userPropertyString(_ key: String) -> String? {
        propertyService.userPropertyString(key)
    }

    /// One wallpaper instance's property, independent of which wallpaper is being rendered.
    func userPropertyString(_ key: String, wallpaper: String) -> String? {
        propertyService.userPropertyString(key, wallpaper: wallpaper)
    }

    /// Every user property of one wallpaper instance.
    func userProperties(wallpaper: String) -> [String: String] {
        propertyService.userProperties(wallpaper: wallpaper)
    }

    // MARK: - Audio

    /// Holds system audio capture on while the lease lives (`AudioCaptureDemand`). Every consumer
    /// of the level or spectrum takes one: capture is off while nothing holds one.
    func acquireAudioCapture() -> AudioCaptureLease {
        audioCapture.demand.acquire()
    }

    var audioLevel: Double {
        if let level = propertyService.frameAudioLevel { return level }
        OWEFrameMetrics.countLockAcquisition()
        return audioCapture.audioLevel
    }

    /// The latest frame a scene's spectrum clock advanced to, without advancing anything
    /// (SceneScript's `registerAudioBuffers`).
    var audioSpectrumSnapshot: AudioSpectrumSnapshot { audioCapture.audioSpectrumSnapshot }

    /// A consumer's own WE spectrum smoothing: each scene renderer and each web page steps one
    /// by its own frames. `publishes`: its frames become `audioSpectrumSnapshot` (scenes).
    func makeAudioSpectrumClock(publishes: Bool) -> AudioSpectrumClock {
        audioCapture.makeAudioSpectrumClock(publishes: publishes)
    }
}
