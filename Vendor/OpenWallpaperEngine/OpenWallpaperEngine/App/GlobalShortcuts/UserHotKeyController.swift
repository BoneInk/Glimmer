import AppKit
import Combine

/// Keeps the wallpapers' and display profiles' hotkeys (`UserHotKey`) registered with macOS and
/// loads the wallpaper or profile when one is pressed, whichever app is in front, as Wallpaper
/// Engine's "wallpaper" and "profile" hotkeys do.
///
/// A wallpaper's hotkey belongs to one display, the one selected when it was assigned (WE keeps
/// the monitor's `location` with it); a profile's applies the whole profile. A deleted profile's
/// hotkey goes with it.
@MainActor
final class UserHotKeyController: ObservableObject {
    @Published private(set) var hotKeys: [UserHotKey]
    /// Hotkeys macOS refused (another app holds the shortcut, or an error).
    @Published private(set) var unregistered: Set<UUID> = []

    /// Loads a pressed hotkey's wallpaper or profile. Set by the app delegate.
    var perform: (UserHotKey) -> Void = { _ in }
    /// The hotkey actions' shortcuts, which these mustn't repeat.
    weak var actionHotKeys: GlobalHotKeyController?

    private let viewModel: WallpaperViewModel
    private let registrar: HotKeyRegistering
    private let finder: GlobalShortcutConflictFinder
    private let defaults: UserDefaults
    private let openKeyboardSettings: () -> Void
    private var registered: [UUID: (shortcut: GlobalShortcut, id: UInt32)] = [:]
    private var nextID: UInt32 = 1
    private var isSuspended = false
    private var cancellable: AnyCancellable?

    /// The id used to try a shortcut out before it is saved.
    private static let probeID: UInt32 = 0
    /// "OWEu": the wallpapers' and profiles' hotkeys.
    static let signature: OSType = 0x4F57_4575

    /// `profileNames` publishes the saved profiles' names; a hotkey of a profile no longer among
    /// them is dropped.
    init(viewModel: WallpaperViewModel,
         profileNames: AnyPublisher<[String], Never>? = nil,
         registrar: HotKeyRegistering? = nil,
         finder: GlobalShortcutConflictFinder = GlobalShortcutConflictFinder(),
         defaults: UserDefaults = .app,
         openKeyboardSettings: @escaping () -> Void = {
             NSWorkspace.shared.open(PlaylistShortcutController.keyboardSettingsURL)
         }) {
        self.viewModel = viewModel
        let registrar = registrar ?? CarbonHotKeyRegistrar(signature: Self.signature)
        self.registrar = registrar
        self.finder = finder
        self.defaults = defaults
        self.openKeyboardSettings = openKeyboardSettings
        hotKeys = UserHotKeyStore.load(from: defaults)
        registrar.onPress = { [weak self] id in self?.handlePress(id: id) }
        sync()
        cancellable = profileNames?.sink { [weak self] names in self?.dropProfiles(notIn: names) }
    }

    // MARK: Lookup

    /// The hotkey of `wallpaper` on the display at `location`, if it has one.
    func hotKey(for wallpaper: WEWallpaper, location: String) -> UserHotKey? {
        hotKeys.first { $0.target == .wallpaper(wallpaper, location: location) }
    }

    /// The hotkey of the profile `name`, if it has one.
    func hotKey(forProfile name: String) -> UserHotKey? {
        hotKeys.first { $0.target == .profile(name: name) }
    }

    // MARK: Registration

    private func sync() {
        guard !isSuspended else { return }
        let wanted = Dictionary(hotKeys.map { ($0.id, $0.shortcut) }, uniquingKeysWith: { first, _ in first })
        for (hotKeyID, entry) in registered where wanted[hotKeyID] != entry.shortcut {
            registrar.unregister(id: entry.id)
            registered[hotKeyID] = nil
        }
        var refused = unregistered.filter { wanted[$0] != nil }
        for hotKey in hotKeys where registered[hotKey.id] == nil {
            let id = nextID
            nextID += 1
            switch registrar.register(hotKey.shortcut, id: id) {
            case .registered:
                registered[hotKey.id] = (hotKey.shortcut, id)
                refused.remove(hotKey.id)
            case .takenByAnotherApp:
                OWELog.info(.app, "Hotkey \(hotKey.shortcut.symbols) of \"\(hotKey.title)\" is held by another app")
                refused.insert(hotKey.id)
            case let .failed(status):
                OWELog.error(.app, "Registering hotkey \(hotKey.shortcut.symbols) of \"\(hotKey.title)\" failed: \(status)")
                refused.insert(hotKey.id)
            }
        }
        if refused != unregistered { unregistered = refused }
    }

    /// Unregisters every hotkey while a recorder field listens; `resume()` registers them again.
    func suspend() {
        guard !isSuspended else { return }
        for entry in registered.values { registrar.unregister(id: entry.id) }
        registered.removeAll()
        isSuspended = true
    }

    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        sync()
    }

    private func handlePress(id: UInt32) {
        guard let hotKeyID = registered.first(where: { $0.value.id == id })?.key,
              let hotKey = hotKeys.first(where: { $0.id == hotKeyID }) else { return }
        OWELog.info(.app, "Hotkey pressed: loading \"\(hotKey.title)\"")
        perform(hotKey)
    }

    // MARK: Assigning

    /// What already uses `shortcut`, for a hotkey of `target`: playlists, the hotkey actions, the
    /// other wallpapers' and profiles' hotkeys, this app's menus, macOS and, by trying to register
    /// it, other apps. The target's own hotkey is no conflict.
    func conflicts(for shortcut: GlobalShortcut, target: UserHotKey.Target) -> [GlobalShortcutConflict] {
        let own = hotKeys.first { $0.target == target }
        var conflicts = finder.conflicts(for: shortcut, userHotKey: own?.id, target: target,
                                         playlists: viewModel.playlists,
                                         hotKeys: actionHotKeys?.bindings ?? GlobalHotKeyBindings(),
                                         userHotKeys: hotKeys)
        let ownedHere = own.map { registered[$0.id]?.shortcut == shortcut } ?? false
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

    /// Saves `shortcut` as the hotkey of `target` (nil removes it), replacing the one it had. With
    /// conflicts the user chose Use Anyway for: playlists, hotkey actions and other hotkeys lose
    /// it, and for a macOS one Keyboard Shortcuts opens so the user can turn it off there.
    func assign(_ shortcut: GlobalShortcut?, to target: UserHotKey.Target,
                resolving conflicts: [GlobalShortcutConflict] = []) {
        var hotKeys = hotKeys
        var playlists = viewModel.playlists
        for conflict in conflicts {
            switch conflict {
            case let .playlist(id, _):
                if let index = playlists.firstIndex(where: { $0.id == id }) { playlists[index].shortcut = nil }
            case let .action(action):
                actionHotKeys?.clear(action)
            case let .userHotKey(id, _, _):
                hotKeys.removeAll { $0.id == id }
            default:
                break
            }
        }
        if playlists != viewModel.playlists { viewModel.playlists = playlists }
        if let index = hotKeys.firstIndex(where: { $0.target == target }) {
            if let shortcut { hotKeys[index].shortcut = shortcut } else { hotKeys.remove(at: index) }
        } else if let shortcut {
            hotKeys.append(UserHotKey(shortcut: shortcut, target: target))
        }
        setHotKeys(hotKeys)
        if conflicts.contains(where: { if case .macOS = $0 { return true } else { return false } }) {
            openKeyboardSettings()
        }
    }

    /// Removes the hotkey `id`: its Remove Hotkey, or another owner took its shortcut with Use Anyway.
    func remove(_ id: UUID) {
        setHotKeys(hotKeys.filter { $0.id != id })
    }

    private func dropProfiles(notIn names: [String]) {
        let kept = hotKeys.filter { hotKey in
            guard case let .profile(name) = hotKey.target else { return true }
            return names.contains(name)
        }
        if kept.count != hotKeys.count { setHotKeys(kept) }
    }

    private func setHotKeys(_ hotKeys: [UserHotKey]) {
        guard hotKeys != self.hotKeys else { return }
        self.hotKeys = hotKeys
        UserHotKeyStore.save(hotKeys, to: defaults)
        sync()
    }
}
