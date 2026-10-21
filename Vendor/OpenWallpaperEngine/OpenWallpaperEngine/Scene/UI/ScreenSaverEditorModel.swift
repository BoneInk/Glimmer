import Combine
import Foundation

/// Scene Edit / Export's Screen Saver mode: the wallpaper's screen saver version in the mode's
/// private instance (`IsolatedSceneEditSession`), its layer and property choices, and setting it
/// as the screen saver, drawn live with them.
///
/// The session starts from the screen saver's saved choices for this wallpaper
/// (`ScreenSaverSettingsStore`) when it has any, else from the wallpaper's own values. What the
/// mode changes is saved back there as it changes (and when the mode closes), never to the
/// wallpaper's own stores, so the live screen saver draws it with them.
@MainActor
final class ScreenSaverEditorModel: ObservableObject {
    /// The isolated session's purpose (`WallpaperPropertyScope.isolated`).
    static let purpose = "screen-saver"

    let session: IsolatedSceneEditSession
    let wallpaper: WEWallpaper
    let selectionService: ScreenSaverSelectionService
    private let store: ScreenSaverSettingsStore
    private let defaults: UserDefaults
    private let identity: WallpaperSettingsIdentity
    /// The stores the session was seeded from: the wallpaper's own values, which the screen saver
    /// follows until its choices first differ.
    private let seedScopes: [WallpaperPropertyScope]
    private var subscriptions: Set<AnyCancellable> = []

    /// `defaults` holds the stores (the session's too); `store` the screen saver's own settings.
    init(session: IsolatedSceneEditSession, seededFrom seedScopes: [WallpaperPropertyScope],
         selectionService: ScreenSaverSelectionService, store: ScreenSaverSettingsStore, defaults: UserDefaults = .app) {
        self.seedScopes = seedScopes
        self.session = session
        wallpaper = session.wallpaper
        self.selectionService = selectionService
        self.store = store
        self.defaults = defaults
        identity = session.targets.identity
        if let saved = store.values(for: identity) { session.replaceValues(saved) }
        selectionService.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        // The editor's models write the session's store directly; its changes are saved as they settle.
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification, object: defaults)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.persist() } }
            .store(in: &subscriptions)
    }

    /// Only scenes are adjusted here (a video plays as it is, `VideoScreenSaverModel`).
    static func isEligible(_ wallpaper: WEWallpaper) -> Bool { ScreenSaverPlugin.isScene(wallpaper) }

    /// Saves the session's values as the screen saver's choices for this wallpaper, when they changed.
    func persist() {
        guard !session.isEnded else { return }
        let values = session.values
        guard store.values(for: identity) != values else { return }
        // The first change makes the choices the screen saver's own; until then it follows the wallpaper.
        if store.values(for: identity) == nil, values == IsolatedSceneEditSession.seed(of: wallpaper, from: seedScopes, defaults: defaults) {
            return
        }
        store.setValues(values, for: identity)
    }

    /// Whether this wallpaper is the screen saver.
    var isScreenSaver: Bool { selectionService.isSelected(wallpaper) }

    /// Makes this version the screen saver, drawn live with the mode's values.
    func setAsScreenSaver() {
        persist()
        selectionService.pick(wallpaper, values: session.values)
    }

    func stopUsingAsScreenSaver() {
        selectionService.stopUsingSelection()
    }

    /// The mode closes: its last changes are saved.
    func close() {
        persist()
    }
}
