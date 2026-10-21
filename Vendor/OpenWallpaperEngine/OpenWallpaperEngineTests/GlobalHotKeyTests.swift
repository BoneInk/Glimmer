import AppKit
import Carbon.HIToolbox
import XCTest
@testable import OpenWallpaperEngine

/// The hotkey actions (Settings › General › Hotkeys): conflicts with each other, the playlists,
/// the menus, macOS and other apps; registration, running an action and storage.
@MainActor
final class GlobalHotKeyTests: XCTestCase {
    private final class FakeRegistrar: HotKeyRegistering {
        var onPress: ((UInt32) -> Void)?
        var taken: Set<GlobalShortcut> = []
        var registered: [UInt32: GlobalShortcut] = [:]

        func register(_ shortcut: GlobalShortcut, id: UInt32) -> HotKeyRegistration {
            if taken.contains(shortcut) { return .takenByAnotherApp }
            registered[id] = shortcut
            return .registered
        }

        func unregister(id: UInt32) { registered[id] = nil }

        func press(_ shortcut: GlobalShortcut) {
            guard let id = registered.first(where: { $0.value == shortcut })?.key else { return }
            onPress?(id)
        }
    }

    private let ctrlOptS = GlobalShortcut(keyCode: UInt16(kVK_ANSI_S), key: "s", modifiers: [.control, .option])
    private let cmdOptP = GlobalShortcut(keyCode: UInt16(kVK_ANSI_P), key: "p", modifiers: [.command, .option])
    private let cmdShift1 = GlobalShortcut(keyCode: UInt16(kVK_ANSI_1), key: "1", modifiers: [.command, .shift])
    private let ctrlOpt9 = GlobalShortcut(keyCode: UInt16(kVK_ANSI_9), key: "9", modifiers: [.control, .option])

    private var defaults: UserDefaults!
    private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "owe-hotkey-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private let finder = GlobalShortcutConflictFinder(symbolicHotKeys: { [] }, standardShortcuts: [])

    private func playlist(_ name: String, shortcut: GlobalShortcut? = nil) -> WallpaperPlaylist {
        let wallpaper = WEWallpaper(using: WEProject(file: "scene.json", preview: "p.jpg", title: name, type: "scene"),
                                    where: URL(fileURLWithPath: "/tmp/owe-hotkey/\(name)"))
        return WallpaperPlaylist(name: name, items: [WallpaperPlaylistItem(wallpaper: wallpaper)], shortcut: shortcut)
    }

    private func controller(_ model: WallpaperViewModel, _ registrar: FakeRegistrar,
                            openedSettings: (() -> Void)? = nil) -> GlobalHotKeyController {
        GlobalHotKeyController(viewModel: model, registrar: registrar, finder: finder, defaults: defaults,
                               openKeyboardSettings: openedSettings ?? {})
    }

    // MARK: - Conflicts

    func testActionsConflictWithEachOtherAndThePlaylists() {
        let other = playlist("Other", shortcut: ctrlOptS)
        var bindings = GlobalHotKeyBindings()
        bindings[.screenshot] = ctrlOpt9
        XCTAssertEqual(finder.conflicts(for: ctrlOptS, action: .mute, playlists: [other], hotKeys: bindings),
                       [.playlist(id: other.id, name: "Other")])
        XCTAssertEqual(finder.conflicts(for: ctrlOpt9, action: .mute, playlists: [other], hotKeys: bindings),
                       [.action(.screenshot)])
        XCTAssertEqual(finder.conflicts(for: ctrlOpt9, action: .screenshot, playlists: [other], hotKeys: bindings), [],
                       "an action doesn't conflict with its own shortcut")
        // A playlist's shortcut is checked against the actions too.
        XCTAssertEqual(finder.conflicts(for: ctrlOpt9, playlistID: other.id, playlists: [other], hotKeys: bindings),
                       [.action(.screenshot)])
    }

    func testTheMenuCommandThatDoesTheSameIsNoConflict() {
        // ⌥⌘P is the menu's Pause or Resume: no conflict for the pause hotkey, one for any other.
        XCTAssertEqual(finder.conflicts(for: cmdOptP, action: .pause, playlists: [], hotKeys: GlobalHotKeyBindings()), [])
        XCTAssertEqual(finder.conflicts(for: cmdOptP, action: .mute, playlists: [], hotKeys: GlobalHotKeyBindings()),
                       [.appMenu(.pauseResume)])
        XCTAssertEqual(finder.conflicts(for: cmdShift1, action: .windowBrowser, playlists: [], hotKeys: GlobalHotKeyBindings()), [])
    }

    func testMacOSAndOtherAppsConflict() {
        let model = WallpaperViewModel(persistsWallpapers: false)
        let registrar = FakeRegistrar()
        registrar.taken = [ctrlOpt9]
        let screenshots = MacOSShortcut(name: "Screenshots", keyCode: UInt16(kVK_ANSI_4), key: nil, modifiers: [.command, .shift])
        let hotKeys = GlobalHotKeyController(
            viewModel: model, registrar: registrar,
            finder: GlobalShortcutConflictFinder(appShortcuts: [], symbolicHotKeys: { [screenshots] }, standardShortcuts: []),
            defaults: defaults, openKeyboardSettings: {})
        let cmdShift4 = GlobalShortcut(keyCode: UInt16(kVK_ANSI_4), key: "4", modifiers: [.command, .shift])
        XCTAssertEqual(hotKeys.conflicts(for: cmdShift4, action: .screenshot), [.macOS(name: "Screenshots")])
        XCTAssertEqual(hotKeys.conflicts(for: ctrlOpt9, action: .screenshot), [.anotherApp])
        XCTAssertEqual(hotKeys.conflicts(for: ctrlOptS, action: .screenshot), [])
        XCTAssertTrue(registrar.registered.isEmpty, "the probe is unregistered again")
    }

    // MARK: - Assigning, registering, running

    func testAssignResolvesConflictsRegistersAndRuns() {
        let model = WallpaperViewModel(persistsWallpapers: false)
        model.playlists = [playlist("P", shortcut: ctrlOptS)]
        let registrar = FakeRegistrar()
        var opened = 0
        let hotKeys = controller(model, registrar, openedSettings: { opened += 1 })
        var performed: [GlobalHotKeyAction] = []
        hotKeys.perform = { performed.append($0) }

        // Use Anyway on a playlist's shortcut takes it from the playlist.
        let conflicts = hotKeys.conflicts(for: ctrlOptS, action: .screenshot)
        XCTAssertEqual(conflicts, [.playlist(id: model.playlists[0].id, name: "P")])
        hotKeys.assign(ctrlOptS, to: .screenshot, resolving: conflicts)
        XCTAssertNil(model.playlists[0].shortcut)
        XCTAssertEqual(hotKeys.bindings[.screenshot], ctrlOptS)
        XCTAssertEqual(Array(registrar.registered.values), [ctrlOptS])

        registrar.press(ctrlOptS)
        XCTAssertEqual(performed, [.screenshot])

        // Use Anyway on another action's moves it; on a macOS one opens Keyboard Shortcuts.
        hotKeys.assign(ctrlOptS, to: .mute, resolving: hotKeys.conflicts(for: ctrlOptS, action: .mute))
        XCTAssertNil(hotKeys.bindings[.screenshot])
        XCTAssertEqual(hotKeys.bindings[.mute], ctrlOptS)
        hotKeys.assign(cmdShift1, to: .pause, resolving: [.macOS(name: nil)])
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(Set(registrar.registered.values), [ctrlOptS, cmdShift1])

        // Clearing unregisters; suspending stops them all until resumed.
        hotKeys.assign(nil, to: .pause)
        XCTAssertEqual(Array(registrar.registered.values), [ctrlOptS])
        hotKeys.suspend()
        XCTAssertTrue(registrar.registered.isEmpty)
        hotKeys.resume()
        XCTAssertEqual(Array(registrar.registered.values), [ctrlOptS])
    }

    func testStopRegistersRunsAndConflicts() {
        XCTAssertEqual(GlobalHotKeyAction(rawValue: "stop"), .stop, "WE's action name")
        XCTAssertEqual(GlobalHotKeyAction.stop.group, .playback)
        XCTAssertNil(GlobalHotKeyAction.stop.menuCommand, "the menus' Stop has no shortcut")
        // The menu's ⌥⌘P is Pause's, so it is one for Stop.
        XCTAssertEqual(finder.conflicts(for: cmdOptP, action: .stop, playlists: [], hotKeys: GlobalHotKeyBindings()),
                       [.appMenu(.pauseResume)])

        let model = WallpaperViewModel(persistsWallpapers: false)
        let registrar = FakeRegistrar()
        let hotKeys = controller(model, registrar)
        var performed: [GlobalHotKeyAction] = []
        hotKeys.perform = { performed.append($0) }
        XCTAssertEqual(hotKeys.conflicts(for: ctrlOpt9, action: .stop), [])
        hotKeys.assign(ctrlOpt9, to: .stop, resolving: [])
        XCTAssertEqual(Array(registrar.registered.values), [ctrlOpt9])
        registrar.press(ctrlOpt9)
        XCTAssertEqual(performed, [.stop])
        XCTAssertEqual(hotKeys.conflicts(for: ctrlOpt9, action: .pause), [.action(.stop)])
        XCTAssertEqual(GlobalHotKeyBindings.load(from: defaults)[.stop], ctrlOpt9, "stored under WE's name")
    }

    func testAPlaylistTakingAnActionsShortcutClearsTheAction() {
        let model = WallpaperViewModel(persistsWallpapers: false)
        let mine = playlist("Mine")
        model.playlists = [mine]
        let registrar = FakeRegistrar()
        let hotKeys = controller(model, registrar)
        hotKeys.assign(ctrlOptS, to: .nextWallpaper)
        let playlists = PlaylistShortcutController(viewModel: model, registrar: FakeRegistrar(), finder: finder,
                                                   openKeyboardSettings: {})
        playlists.hotKeys = hotKeys
        let conflicts = playlists.conflicts(for: ctrlOptS, playlistID: mine.id)
        XCTAssertEqual(conflicts, [.action(.nextWallpaper)])
        playlists.assign(ctrlOptS, to: mine.id, resolving: conflicts)
        XCTAssertNil(hotKeys.bindings[.nextWallpaper])
        XCTAssertEqual(model.playlists[0].shortcut, ctrlOptS)
    }

    func testAnotherAppHoldingAStoredShortcutIsReported() {
        let model = WallpaperViewModel(persistsWallpapers: false)
        var stored = GlobalHotKeyBindings()
        stored[.toggleIcons] = ctrlOpt9
        stored.save(to: defaults)
        let registrar = FakeRegistrar()
        registrar.taken = [ctrlOpt9]
        let hotKeys = controller(model, registrar)
        XCTAssertEqual(hotKeys.unregisteredActions, [.toggleIcons])
    }

    // MARK: - Storage

    func testBindingsRoundTripAndUnknownEntriesAreDropped() throws {
        var bindings = GlobalHotKeyBindings()
        bindings[.pause] = cmdOptP
        bindings[.windowSettings] = ctrlOptS
        bindings.save(to: defaults)
        XCTAssertEqual(GlobalHotKeyBindings.load(from: defaults), bindings)

        // WE's own action names are the keys; an unknown action or a broken shortcut is dropped.
        let json = """
        {"screenshot": {"keyCode": 1, "key": "s", "modifierFlags": 1572864}, "profile": {"keyCode": 2, "key": "d", "modifierFlags": 1048576}, "mute": 5}
        """
        defaults.set(Data(json.utf8), forKey: GlobalHotKeyBindings.defaultsKey)
        let loaded = GlobalHotKeyBindings.load(from: defaults)
        XCTAssertEqual(loaded.shortcuts.count, 1)
        XCTAssertEqual(loaded[.screenshot]?.keyCode, 1)
        XCTAssertEqual(GlobalHotKeyAction.toggleRecording.rawValue, "togglerecord")
    }

    func testEveryActionIsInOneOfWEsGroups() {
        let grouped = GlobalHotKeyAction.Group.allCases.flatMap(\.actions)
        XCTAssertEqual(Set(grouped), Set(GlobalHotKeyAction.allCases))
        XCTAssertEqual(grouped.count, GlobalHotKeyAction.allCases.count)
    }
}
