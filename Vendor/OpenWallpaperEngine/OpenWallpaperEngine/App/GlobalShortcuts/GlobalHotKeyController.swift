import AppKit

/// Keeps the hotkey actions' shortcuts (Settings › General › Hotkeys, `GlobalHotKeyAction`)
/// registered with macOS and runs the action when one is pressed, whichever app is in front.
/// Carbon's `RegisterEventHotKey` needs no Accessibility permission.
@MainActor
final class GlobalHotKeyController: ObservableObject {
    @Published private(set) var bindings: GlobalHotKeyBindings
    /// Actions whose shortcut macOS refused (another app holds it, or an error).
    @Published private(set) var unregisteredActions: Set<GlobalHotKeyAction> = []

    /// Runs an action. Set by the app delegate.
    var perform: (GlobalHotKeyAction) -> Void = { _ in }
    /// The playlists' shortcuts, suspended with these while a recorder listens.
    weak var playlistShortcuts: PlaylistShortcutController?
    /// The wallpapers' and profiles' hotkeys, suspended with these too.
    weak var userHotKeys: UserHotKeyController?

    private let viewModel: WallpaperViewModel
    private let registrar: HotKeyRegistering
    private let finder: GlobalShortcutConflictFinder
    private let defaults: UserDefaults
    private let openKeyboardSettings: () -> Void
    private var registered: [GlobalHotKeyAction: GlobalShortcut] = [:]
    private var isSuspended = false

    /// The id used to try a shortcut out before it is saved; the actions use 1….
    private static let probeID: UInt32 = 0

    init(viewModel: WallpaperViewModel,
         registrar: HotKeyRegistering? = nil,
         finder: GlobalShortcutConflictFinder = GlobalShortcutConflictFinder(),
         defaults: UserDefaults = .app,
         openKeyboardSettings: @escaping () -> Void = {
             NSWorkspace.shared.open(PlaylistShortcutController.keyboardSettingsURL)
         }) {
        self.viewModel = viewModel
        let registrar = registrar ?? CarbonHotKeyRegistrar(signature: CarbonHotKeyRegistrar.actionSignature)
        self.registrar = registrar
        self.finder = finder
        self.defaults = defaults
        self.openKeyboardSettings = openKeyboardSettings
        bindings = GlobalHotKeyBindings.load(from: defaults)
        registrar.onPress = { [weak self] id in self?.handlePress(id: id) }
        sync()
    }

    private static func id(of action: GlobalHotKeyAction) -> UInt32 {
        UInt32(GlobalHotKeyAction.allCases.firstIndex(of: action)! + 1)
    }

    // MARK: Registration

    private func sync() {
        guard !isSuspended else { return }
        for (action, shortcut) in registered where bindings[action] != shortcut {
            registrar.unregister(id: Self.id(of: action))
            registered[action] = nil
        }
        var unregistered = unregisteredActions.filter { bindings[$0] != nil }
        for action in GlobalHotKeyAction.allCases {
            guard let shortcut = bindings[action], registered[action] == nil else { continue }
            switch registrar.register(shortcut, id: Self.id(of: action)) {
            case .registered:
                registered[action] = shortcut
                unregistered.remove(action)
            case .takenByAnotherApp:
                OWELog.info(.app, "Hotkey \(shortcut.symbols) for \(action.rawValue) is held by another app")
                unregistered.insert(action)
            case let .failed(status):
                OWELog.error(.app, "Registering hotkey \(shortcut.symbols) for \(action.rawValue) failed: \(status)")
                unregistered.insert(action)
            }
        }
        if unregistered != unregisteredActions { unregisteredActions = unregistered }
    }

    /// Unregisters every hotkey, and the playlists', wallpapers' and profiles' shortcuts, while a
    /// recorder field listens.
    func suspend() {
        playlistShortcuts?.suspend()
        userHotKeys?.suspend()
        guard !isSuspended else { return }
        for action in registered.keys { registrar.unregister(id: Self.id(of: action)) }
        registered.removeAll()
        isSuspended = true
    }

    func resume() {
        playlistShortcuts?.resume()
        userHotKeys?.resume()
        guard isSuspended else { return }
        isSuspended = false
        sync()
    }

    private func handlePress(id: UInt32) {
        guard let action = registered.keys.first(where: { Self.id(of: $0) == id }) else { return }
        OWELog.info(.app, "Hotkey pressed: \(action.rawValue)")
        perform(action)
    }

    // MARK: Assigning

    /// What already uses `shortcut`: playlists, other actions, this app's menus, macOS and, by
    /// trying to register it, other apps.
    func conflicts(for shortcut: GlobalShortcut, action: GlobalHotKeyAction) -> [GlobalShortcutConflict] {
        var conflicts = finder.conflicts(for: shortcut, action: action, playlists: viewModel.playlists, hotKeys: bindings,
                                         userHotKeys: userHotKeys?.hotKeys ?? [])
        let ownedHere = registered[action] == shortcut
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

    /// Saves `shortcut` (nil clears it) as `action`'s. With conflicts the user chose Use Anyway
    /// for: playlists and other actions lose it, and for a macOS one Keyboard Shortcuts opens so the
    /// user can turn it off there (nothing of macOS or other apps is changed here).
    func assign(_ shortcut: GlobalShortcut?, to action: GlobalHotKeyAction,
                resolving conflicts: [GlobalShortcutConflict] = []) {
        var bindings = bindings
        var playlists = viewModel.playlists
        for conflict in conflicts {
            switch conflict {
            case let .playlist(id, _):
                if let index = playlists.firstIndex(where: { $0.id == id }) { playlists[index].shortcut = nil }
            case let .action(other):
                bindings[other] = nil
            case let .userHotKey(id, _, _):
                userHotKeys?.remove(id)
            default:
                break
            }
        }
        if playlists != viewModel.playlists { viewModel.playlists = playlists }
        bindings[action] = shortcut
        setBindings(bindings)
        if conflicts.contains(where: { if case .macOS = $0 { return true } else { return false } }) {
            openKeyboardSettings()
        }
    }

    /// Clears `action`'s hotkey: another owner took its shortcut with Use Anyway.
    func clear(_ action: GlobalHotKeyAction) {
        var bindings = bindings
        bindings[action] = nil
        setBindings(bindings)
    }

    private func setBindings(_ bindings: GlobalHotKeyBindings) {
        guard bindings != self.bindings else { return }
        self.bindings = bindings
        bindings.save(to: defaults)
        sync()
    }
}
