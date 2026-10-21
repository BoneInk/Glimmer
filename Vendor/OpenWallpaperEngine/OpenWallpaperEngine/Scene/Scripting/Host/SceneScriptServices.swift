import Foundation

/// The parts of SceneScript the whole app shares (docs/scenescript-plan.md WP11), passed to every
/// renderer that runs scripts: WE's prelude (read once, and again when the assets change), the one `localStorage` store (so two
/// screens showing one wallpaper share `'global'`), the one media session (MediaRemote registers
/// per process, SF14), the audio spectrum the renderer advances once per frame and the left button
/// as the wallpaper receives it (`DesktopClickMonitor`; nil: never pressed), and what opens the
/// user shortcuts scripts ask for (nil: none open, as in offscreen renders).
final class SceneScriptServices {
    // `preludeLock` owns `currentPrelude`: scripts read it from their own threads.
    private let preludeLock = NSLock()
    private var currentPrelude: SceneScriptPrelude
    var prelude: SceneScriptPrelude { preludeLock.withLock { currentPrelude } }
    let storage: SceneScriptStorage
    let media: MediaSessionSource
    /// The current frame's spectrum, without advancing it (`SystemAudioCapture.audioSpectrumSnapshot`).
    let spectrum: () -> AudioSpectrumSnapshot
    let configuration: SceneScriptRuntime.Configuration
    let clicks: DesktopClickMonitor?
    let userShortcuts: UserShortcutLauncher?

    init(prelude: SceneScriptPrelude, storage: SceneScriptStorage, media: MediaSessionSource,
         spectrum: @escaping () -> AudioSpectrumSnapshot,
         configuration: SceneScriptRuntime.Configuration = .standard, clicks: DesktopClickMonitor? = nil,
         userShortcuts: UserShortcutLauncher? = nil) {
        self.currentPrelude = prelude
        self.storage = storage
        self.media = media
        self.spectrum = spectrum
        self.configuration = configuration
        self.clicks = clicks
        self.userShortcuts = userShortcuts
    }

    /// Reads the prelude again, for scenes loaded after the assets were installed or changed.
    func reloadPrelude(_ prelude: SceneScriptPrelude = .load()) {
        preludeLock.withLock { currentPrelude = prelude }
    }
}
