import AppKit
import Combine

/// Keeps every playlist's global shortcut registered with macOS and starts the playlist when its
/// shortcut is pressed, whichever app is in front.
///
/// Registration follows `WallpaperViewModel.playlists`: a new or changed shortcut is
/// (re)registered, a cleared one or a deleted playlist's is unregistered.
@MainActor
final class PlaylistShortcutController: ObservableObject {
    /// Playlists whose shortcut macOS refused (another app holds it, or an error), so the
    /// Playlists view can say it may not work.
    @Published private(set) var unregisteredPlaylists: Set<UUID> = []
    /// The hotkey actions' shortcuts (`GlobalHotKeyController`), which a playlist's mustn't repeat.
    weak var hotKeys: GlobalHotKeyController?
    /// The wallpapers' and profiles' hotkeys, which a playlist's mustn't repeat either.
    weak var userHotKeys: UserHotKeyController?

    private let viewModel: WallpaperViewModel
    private let registrar: HotKeyRegistering
    private let finder: GlobalShortcutConflictFinder
    /// Opens System Settings › Keyboard so the user can turn a macOS shortcut off there.
    private let openKeyboardSettings: () -> Void
    private var registered: [UUID: (shortcut: GlobalShortcut, id: UInt32)] = [:]
    private var nextID: UInt32 = 1
    /// While a recorder field listens, no shortcut fires, so it can record one already in use.
    private var isSuspended = false
    private var cancellable: AnyCancellable?

    /// The id used to try a shortcut out before it is saved.
    private static let probeID: UInt32 = 0

    static let keyboardSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!

    init(viewModel: WallpaperViewModel,
         registrar: HotKeyRegistering? = nil,
         finder: GlobalShortcutConflictFinder = GlobalShortcutConflictFinder(),
         openKeyboardSettings: @escaping () -> Void = {
             NSWorkspace.shared.open(PlaylistShortcutController.keyboardSettingsURL)
         }) {
        self.viewModel = viewModel
        let registrar = registrar ?? CarbonHotKeyRegistrar()
        self.registrar = registrar
        self.finder = finder
        self.openKeyboardSettings = openKeyboardSettings
        registrar.onPress = { [weak self] id in self?.handlePress(id: id) }
        cancellable = viewModel.$playlists.sink { [weak self] playlists in
            self?.sync(playlists)
        }
    }

    // MARK: Registration

    private func sync(_ playlists: [WallpaperPlaylist]) {
        guard !isSuspended else { return }
        let wanted = Dictionary(playlists.compactMap { playlist in playlist.shortcut.map { (playlist.id, $0) } },
                                uniquingKeysWith: { first, _ in first })
        for (playlistID, entry) in registered where wanted[playlistID] != entry.shortcut {
            registrar.unregister(id: entry.id)
            registered[playlistID] = nil
        }
        var unregistered = unregisteredPlaylists.filter { wanted[$0] != nil }
        for playlist in playlists {
            guard let shortcut = wanted[playlist.id], registered[playlist.id] == nil else { continue }
            let id = nextID
            nextID += 1
            switch registrar.register(shortcut, id: id) {
            case .registered:
                registered[playlist.id] = (shortcut, id)
                unregistered.remove(playlist.id)
            case .takenByAnotherApp:
                OWELog.info(.app, "Playlist \"\(playlist.name)\" shortcut \(shortcut.symbols) is held by another app")
                unregistered.insert(playlist.id)
            case let .failed(status):
                OWELog.error(.app, "Registering playlist \"\(playlist.name)\" shortcut \(shortcut.symbols) failed: \(status)")
                unregistered.insert(playlist.id)
            }
        }
        if unregistered != unregisteredPlaylists { unregisteredPlaylists = unregistered }
    }

    /// Unregisters every shortcut while a recorder field listens; `resume()` registers them again.
    func suspend() {
        guard !isSuspended else { return }
        for entry in registered.values { registrar.unregister(id: entry.id) }
        registered.removeAll()
        isSuspended = true
    }

    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        sync(viewModel.playlists)
    }

    private func handlePress(id: UInt32) {
        guard let playlistID = registered.first(where: { $0.value.id == id })?.key else { return }
        OWELog.info(.app, "Playlist shortcut pressed: starting playlist \(playlistID)")
        viewModel.startPlaylist(id: playlistID)
    }

    // MARK: Assigning

    /// What already uses `shortcut`: other playlists, the hotkey actions, this app's menus, macOS
    /// and, by trying to register it, other apps.
    func conflicts(for shortcut: GlobalShortcut, playlistID: UUID) -> [GlobalShortcutConflict] {
        var conflicts = finder.conflicts(for: shortcut, playlistID: playlistID, playlists: viewModel.playlists,
                                         hotKeys: hotKeys?.bindings ?? GlobalHotKeyBindings(),
                                         userHotKeys: userHotKeys?.hotKeys ?? [])
        let ownedHere = registered[playlistID]?.shortcut == shortcut
        let ownedInApp = conflicts.contains {
            switch $0 {
            case .playlist, .action, .userHotKey: return true
            default: return false
            }
        }
        if !ownedHere, !ownedInApp {
            // Ours are unregistered while recording, so an "exists" answer is another app's.
            switch registrar.register(shortcut, id: Self.probeID) {
            case .registered: registrar.unregister(id: Self.probeID)
            case .takenByAnotherApp: conflicts.append(.anotherApp)
            case .failed: break
            }
        }
        return conflicts
    }

    /// Saves `shortcut` (nil clears it) as the playlist's. With conflicts the user chose Use
    /// Anyway for: other playlists lose it, and for a macOS one Keyboard Shortcuts opens so the
    /// user can turn it off there (nothing of macOS or other apps is changed here).
    func assign(_ shortcut: GlobalShortcut?, to playlistID: UUID, resolving conflicts: [GlobalShortcutConflict] = []) {
        var playlists = viewModel.playlists
        for conflict in conflicts {
            switch conflict {
            case let .playlist(otherID, _):
                if let index = playlists.firstIndex(where: { $0.id == otherID }) { playlists[index].shortcut = nil }
            case let .action(action):
                hotKeys?.clear(action)
            case let .userHotKey(id, _, _):
                userHotKeys?.remove(id)
            default:
                break
            }
        }
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[index].shortcut = shortcut
        viewModel.playlists = playlists
        if conflicts.contains(where: { if case .macOS = $0 { return true } else { return false } }) {
            openKeyboardSettings()
        }
    }
}
