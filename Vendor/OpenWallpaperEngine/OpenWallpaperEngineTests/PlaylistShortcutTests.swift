import AppKit
import Carbon.HIToolbox
import XCTest
@testable import OpenWallpaperEngine

/// Playlist global shortcuts: conflict detection, registration, starting a playlist and storage.
@MainActor
final class PlaylistShortcutTests: XCTestCase {
    /// Records registrations; `taken` shortcuts answer as another app's.
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

    private let cmdShift1 = GlobalShortcut(keyCode: UInt16(kVK_ANSI_1), key: "1", modifiers: [.command, .shift])
    private let cmdOptP = GlobalShortcut(keyCode: UInt16(kVK_ANSI_P), key: "p", modifiers: [.command, .option])
    private let ctrlUp = GlobalShortcut(keyCode: UInt16(kVK_UpArrow), key: "\u{F700}", modifiers: .control)
    private let ctrlOpt9 = GlobalShortcut(keyCode: UInt16(kVK_ANSI_9), key: "9", modifiers: [.control, .option])

    /// A `com.apple.symbolichotkeys.plist` as macOS writes it: Mission Control on ⌃↑ (with the
    /// fn flag arrows carry), screenshots on ⇧⌘4, a disabled entry and an id this app can't name.
    private static let fixture = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>AppleSymbolicHotKeys</key>
        <dict>
            <key>32</key>
            <dict>
                <key>enabled</key><true/>
                <key>value</key>
                <dict>
                    <key>parameters</key><array><integer>65535</integer><integer>126</integer><integer>8650752</integer></array>
                    <key>type</key><string>standard</string>
                </dict>
            </dict>
            <key>30</key>
            <dict>
                <key>enabled</key><true/>
                <key>value</key>
                <dict>
                    <key>parameters</key><array><integer>52</integer><integer>21</integer><integer>1179648</integer></array>
                    <key>type</key><string>standard</string>
                </dict>
            </dict>
            <key>64</key>
            <dict>
                <key>enabled</key><false/>
                <key>value</key>
                <dict>
                    <key>parameters</key><array><integer>112</integer><integer>35</integer><integer>1572864</integer></array>
                    <key>type</key><string>standard</string>
                </dict>
            </dict>
            <key>9999</key>
            <dict>
                <key>enabled</key><true/>
                <key>value</key>
                <dict>
                    <key>parameters</key><array><integer>57</integer><integer>25</integer><integer>786432</integer></array>
                    <key>type</key><string>standard</string>
                </dict>
            </dict>
            <key>65</key>
            <dict>
                <key>enabled</key><true/>
                <key>value</key>
                <dict>
                    <key>parameters</key><array><integer>65535</integer><integer>65535</integer><integer>0</integer></array>
                    <key>type</key><string>standard</string>
                </dict>
            </dict>
        </dict>
    </dict>
    </plist>
    """

    private func fixtureHotKeys() throws -> [MacOSShortcut] {
        let url = FileManager.default.temporaryDirectory.appending(path: "owe-symbolichotkeys-\(UUID()).plist")
        try Data(Self.fixture.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return MacOSShortcuts.symbolicHotKeys(at: url)
    }

    private func wallpaper(_ title: String) -> WEWallpaper {
        WEWallpaper(using: WEProject(file: "scene.json", preview: "p.jpg", title: title, type: "scene"),
                    where: URL(fileURLWithPath: "/tmp/owe-shortcut/\(title)"))
    }

    private func playlist(_ name: String, _ titles: [String], shortcut: GlobalShortcut? = nil) -> WallpaperPlaylist {
        WallpaperPlaylist(name: name, items: titles.map { WallpaperPlaylistItem(wallpaper: wallpaper($0)) },
                          shortcut: shortcut)
    }

    // MARK: - Shortcuts

    func testShortcutNeedsAModifierOtherThanShift() {
        XCTAssertFalse(GlobalShortcut(keyCode: 0, key: "a", modifiers: []).isValid)
        XCTAssertFalse(GlobalShortcut(keyCode: 0, key: "a", modifiers: .shift).isValid)
        XCTAssertTrue(cmdShift1.isValid)
        XCTAssertTrue(ctrlUp.isValid)
        XCTAssertEqual(cmdShift1.symbols, "⇧⌘1")
        XCTAssertEqual(ctrlUp.symbols, "⌃↑")
        XCTAssertEqual(cmdShift1.carbonModifiers, UInt32(cmdKey | shiftKey))
    }

    // MARK: - Conflicts

    func testSymbolicHotKeysFixtureListsOnlyEnabledAssignedEntries() throws {
        let hotKeys = try fixtureHotKeys()
        XCTAssertEqual(hotKeys.count, 3)
        XCTAssertTrue(hotKeys.contains { $0.matches(ctrlUp) && $0.name?.key == "Mission Control" })
        let screenshot = GlobalShortcut(keyCode: 21, key: "4", modifiers: [.command, .shift])
        XCTAssertTrue(hotKeys.contains { $0.matches(screenshot) && $0.name?.key == "Screenshots" })
        // Spotlight (64) is disabled; 65 has no key.
        XCTAssertFalse(hotKeys.contains { $0.name?.key == "Spotlight" })
    }

    func testMacOSConflictsAreNamedWhenKnown() throws {
        let hotKeys = try fixtureHotKeys()
        let finder = GlobalShortcutConflictFinder(appShortcuts: [], symbolicHotKeys: { hotKeys }, standardShortcuts: [])
        XCTAssertEqual(finder.conflicts(for: ctrlUp, playlistID: UUID(), playlists: []),
                       [.macOS(name: "Mission Control")])
        XCTAssertEqual(finder.conflicts(for: ctrlOpt9, playlistID: UUID(), playlists: []),
                       [.macOS(name: nil)])
        XCTAssertEqual(finder.conflicts(for: cmdShift1, playlistID: UUID(), playlists: []), [])
    }

    func testStandardMenuShortcutsConflict() {
        let finder = GlobalShortcutConflictFinder(appShortcuts: [], symbolicHotKeys: { [] })
        let quit = GlobalShortcut(keyCode: UInt16(kVK_ANSI_Q), key: "q", modifiers: .command)
        XCTAssertEqual(finder.conflicts(for: quit, playlistID: UUID(), playlists: []), [.macOS(name: "Quit")])
        let switchApps = GlobalShortcut(keyCode: UInt16(kVK_Tab), key: "\t", modifiers: .command)
        XCTAssertEqual(finder.conflicts(for: switchApps, playlistID: UUID(), playlists: []), [.macOS(name: "Switch Apps")])
    }

    func testInAppConflicts() {
        let finder = GlobalShortcutConflictFinder(symbolicHotKeys: { [] }, standardShortcuts: [])
        let other = playlist("Other", ["a"], shortcut: cmdShift1)
        let mine = playlist("Mine", ["b"])
        // ⌥⌘P is Pause or Resume; ⇧⌘1 is the Wallpaper Explorer and another playlist's.
        XCTAssertEqual(finder.conflicts(for: cmdOptP, playlistID: mine.id, playlists: [other, mine]),
                       [.appMenu(.pauseResume)])
        XCTAssertEqual(finder.conflicts(for: cmdShift1, playlistID: mine.id, playlists: [other, mine]),
                       [.playlist(id: other.id, name: "Other"), .appMenu(.wallpaperExplorer)])
        // A playlist doesn't conflict with its own shortcut.
        XCTAssertEqual(finder.conflicts(for: cmdShift1, playlistID: other.id, playlists: [other, mine]),
                       [.appMenu(.wallpaperExplorer)])
    }

    func testAnotherAppHoldingTheShortcutIsAConflict() {
        let model = WallpaperViewModel(persistsWallpapers: false)
        let mine = playlist("Mine", ["a"])
        model.playlists = [mine]
        let registrar = FakeRegistrar()
        registrar.taken = [ctrlOpt9]
        let controller = PlaylistShortcutController(
            viewModel: model, registrar: registrar,
            finder: GlobalShortcutConflictFinder(appShortcuts: [], symbolicHotKeys: { [] }, standardShortcuts: []),
            openKeyboardSettings: {})
        XCTAssertEqual(controller.conflicts(for: ctrlOpt9, playlistID: mine.id), [.anotherApp])
        XCTAssertEqual(controller.conflicts(for: cmdShift1, playlistID: mine.id), [])
        XCTAssertTrue(registrar.registered.isEmpty, "the probe is unregistered again")
    }

    // MARK: - Assigning and registering

    func testAssignRegistersReplacesAndClears() {
        let model = WallpaperViewModel(persistsWallpapers: false)
        let first = playlist("First", ["a"], shortcut: cmdShift1)
        let second = playlist("Second", ["b"])
        model.playlists = [first, second]
        let registrar = FakeRegistrar()
        var openedSettings = 0
        let controller = PlaylistShortcutController(viewModel: model, registrar: registrar,
                                                    finder: GlobalShortcutConflictFinder(symbolicHotKeys: { [] }),
                                                    openKeyboardSettings: { openedSettings += 1 })
        XCTAssertEqual(Array(registrar.registered.values), [cmdShift1])

        // Use Anyway on another playlist's shortcut moves it.
        let conflicts = controller.conflicts(for: cmdShift1, playlistID: second.id)
        controller.assign(cmdShift1, to: second.id, resolving: conflicts)
        XCTAssertNil(model.playlists[0].shortcut)
        XCTAssertEqual(model.playlists[1].shortcut, cmdShift1)
        XCTAssertEqual(Array(registrar.registered.values), [cmdShift1])
        XCTAssertEqual(openedSettings, 0)

        // Use Anyway on a macOS shortcut opens Keyboard Shortcuts.
        controller.assign(ctrlUp, to: second.id, resolving: [.macOS(name: "Mission Control")])
        XCTAssertEqual(openedSettings, 1)
        XCTAssertEqual(Array(registrar.registered.values), [ctrlUp])

        // Clearing and deleting unregister.
        controller.assign(nil, to: second.id)
        XCTAssertTrue(registrar.registered.isEmpty)
        controller.assign(cmdOptP, to: first.id)
        XCTAssertEqual(registrar.registered.count, 1)
        model.deletePlaylist(model.playlists[0])
        XCTAssertTrue(registrar.registered.isEmpty)
        withExtendedLifetime(controller) {}
    }

    func testSuspendStopsShortcutsUntilResumed() {
        let model = WallpaperViewModel(persistsWallpapers: false)
        model.playlists = [playlist("P", ["a"], shortcut: cmdShift1)]
        let registrar = FakeRegistrar()
        let controller = PlaylistShortcutController(viewModel: model, registrar: registrar, openKeyboardSettings: {})
        controller.suspend()
        XCTAssertTrue(registrar.registered.isEmpty)
        controller.resume()
        XCTAssertEqual(Array(registrar.registered.values), [cmdShift1])
    }

    // MARK: - Starting a playlist

    func testPressingTheShortcutStartsThePlaylist() {
        let model = WallpaperViewModel(persistsWallpapers: false)
        model.connectedScreenIds = { ["preview"] }
        let other = playlist("Other", ["o0", "o1"])
        let target = playlist("Target", ["t0", "t1", "t2"], shortcut: cmdShift1)
        model.playlists = [other, target]
        model.activePlaylistID = other.id
        model.playlistEnabled = false
        let registrar = FakeRegistrar()
        let controller = PlaylistShortcutController(viewModel: model, registrar: registrar, openKeyboardSettings: {})

        registrar.press(cmdShift1)
        XCTAssertEqual(model.activePlaylistID, target.id)
        XCTAssertTrue(model.playlistEnabled)
        XCTAssertEqual(model.currentWallpaper.project.title, "t0")
        XCTAssertEqual(model.playlists[1].displays, ["preview"])

        // It continues where it left off after another playlist ran.
        model.nextPlaylistWallpaper()
        XCTAssertEqual(model.currentWallpaper.project.title, "t1")
        model.activePlaylistID = other.id
        model.nextPlaylistWallpaper()
        XCTAssertEqual(model.currentWallpaper.project.title, "o1")
        registrar.press(cmdShift1)
        XCTAssertEqual(model.currentWallpaper.project.title, "t1")
        withExtendedLifetime(controller) {}
    }

    func testStartUsesThePlaylistsConnectedDisplays() {
        let model = WallpaperViewModel(persistsWallpapers: false)
        model.connectedScreenIds = { ["1", "2"] }
        model.selectedScreenIds = ["1", "2"]
        var list = playlist("P", ["a"])
        list.displays = ["2", "3"]
        model.playlists = [list]
        model.startPlaylist(id: list.id)
        XCTAssertEqual(model.selectedScreenIds, ["2"])
        XCTAssertEqual(model.wallpaper(for: "2").project.title, "a")
        XCTAssertNotEqual(model.wallpaper(for: "1").project.title, "a")
    }

    // MARK: - Storage

    func testShortcutSurvivesEncoding() throws {
        var list = playlist("P", ["a"], shortcut: ctrlUp)
        list.displays = ["7"]
        let decoded = try JSONDecoder().decode([WallpaperPlaylist].self, from: JSONEncoder().encode([list]))
        XCTAssertEqual(decoded.first?.shortcut, ctrlUp)
        XCTAssertEqual(decoded.first?.displays, ["7"])
    }

    func testPlaylistsSavedBeforeShortcutsStillLoad() throws {
        let json = """
        [{"id":"\(UUID().uuidString)","name":"Old","items":[],"duration":60}]
        """
        let decoded = try JSONDecoder().decode([WallpaperPlaylist].self, from: Data(json.utf8))
        XCTAssertNil(decoded.first?.shortcut)
        XCTAssertNil(decoded.first?.displays)
    }
}
