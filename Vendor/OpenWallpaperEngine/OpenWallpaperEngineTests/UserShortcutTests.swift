import XCTest
@testable import OpenWallpaperEngine

/// The `usershortcut` user property (WE 2.7): the stored binding WE's browse UI writes, what
/// scripts get from it, the launcher behind `engine.openUserShortcut`, and that only the user's
/// own value ever binds one (project.json and presets never do).
final class UserShortcutTests: XCTestCase {
    private let machineHash = "a1b2c3"

    // MARK: - Binding

    func testParsesWEsStoredForm() throws {
        let file = try XCTUnwrap(UserShortcutBinding(storedValue: "file:a1b2c3:/Applications/Steam.app|-silent -x"))
        XCTAssertEqual(file.kind, .file)
        XCTAssertEqual(file.systemHash, "a1b2c3")
        XCTAssertEqual(file.path, "/Applications/Steam.app")
        XCTAssertEqual(file.arguments, "-silent -x")
        XCTAssertEqual(file.displayName, "Steam.app")

        // Only the first two colons split, so a URL keeps its own.
        let web = try XCTUnwrap(UserShortcutBinding(storedValue: "web:a1b2c3:https://example.com:8080/a|b"))
        XCTAssertEqual(web.path, "https://example.com:8080/a|b", "only a file has arguments")
        XCTAssertEqual(web.displayName, "https://example.com:8080/a|b")
        XCTAssertEqual(UserShortcutBinding(storedValue: "cmd:a1b2c3:open -a Music")?.displayName, "open -a Music")
        XCTAssertEqual(UserShortcutBinding(storedValue: "directory:a1b2c3:/Users/me/Music")?.displayName, "Music")
        XCTAssertEqual(UserShortcutBinding(storedValue: "directory:a1b2c3:/Users/me/")?.displayName, "/Users/me/",
                       "a path ending in a slash shows whole, as wallpaper64.exe makes `file`")
    }

    func testRejectsWhatWEWouldNotRead() {
        for value in ["", "file", "file:a1b2c3", "file:a1b2c3:", "app:a1b2c3:/x", "file:abc:/x", "file:a1b2c3d:/x", "/Users/me/x"] {
            XCTAssertNil(UserShortcutBinding(storedValue: value), value)
        }
    }

    func testStoredValueRoundTripsAndAddsHTTPSToBareWebsites() {
        let file = UserShortcutBinding(kind: .file, systemHash: machineHash, path: "/a/b.app", arguments: "--x")
        XCTAssertEqual(file.storedValue, "file:a1b2c3:/a/b.app|--x")
        XCTAssertEqual(UserShortcutBinding(storedValue: file.storedValue), file)
        XCTAssertEqual(UserShortcutBinding(kind: .directory, systemHash: machineHash, path: "/a", arguments: "ignored").storedValue,
                       "directory:a1b2c3:/a")
        XCTAssertEqual(UserShortcutBinding(kind: .web, systemHash: machineHash, path: "example.com").storedValue,
                       "web:a1b2c3:https://example.com")
        for kept in ["http://a.b", "https://a.b", "www.a.b", "steam://run/1"] {
            XCTAssertEqual(UserShortcutBinding(kind: .web, systemHash: machineHash, path: kept).storedValue, "web:a1b2c3:" + kept)
        }
        XCTAssertEqual(UserShortcutBinding(kind: .cmd, systemHash: machineHash, path: "").storedValue, "", "no path unbinds")
    }

    func testScriptMembersAreWallpaper64s() {
        XCTAssertEqual(UserShortcutBinding.scriptMembers(storedValue: ""), ["isbound": .bool(false)])
        XCTAssertEqual(UserShortcutBinding.scriptMembers(storedValue: "web:zzzzzz:https://a.b"),
                       ["isbound": .bool(true), "commandtype": .string("website"), "file": .string("https://a.b")],
                       "a binding from another machine still reads as bound; only opening it is blocked")
        let types: [String] = UserShortcutBinding.Kind.allCases.map(\.commandType)
        XCTAssertEqual(types, ["file", "directory", "website", "command"])
    }

    func testTheSystemHashIsSixHexDigitsAndStable() {
        let first: String = UserShortcutSystemHash.current()
        XCTAssertEqual(first.count, UserShortcutBinding.systemHashLength)
        XCTAssertTrue(first.allSatisfy(\.isHexDigit))
        XCTAssertEqual(UserShortcutSystemHash.current(), first)
        XCTAssertNotEqual(UserShortcutSystemHash.hash(machineID: "one"), UserShortcutSystemHash.hash(machineID: "two"))
    }

    // MARK: - Launcher

    func testTheLauncherDispatchesEachKind() {
        let opener = RecordingUserShortcutOpener()
        let launcher = UserShortcutLauncher(opener: opener, systemHash: machineHash)
        XCTAssertTrue(launcher.open("file:a1b2c3:/Applications/Music.app|--a 'b c'"))
        XCTAssertTrue(launcher.open("directory:a1b2c3:/Users/me"))
        XCTAssertTrue(launcher.open("web:a1b2c3:www.example.com"))
        XCTAssertTrue(launcher.open("cmd:a1b2c3:say hi"))
        XCTAssertEqual(opener.calls, [
            "file /Applications/Music.app --a 'b c'", "directory /Users/me", "web https://www.example.com", "cmd say hi",
        ])
    }

    func testTheLauncherOpensNothingUnboundOrFromAnotherMachine() {
        let opener = RecordingUserShortcutOpener()
        let launcher = UserShortcutLauncher(opener: opener, systemHash: machineHash)
        XCTAssertFalse(launcher.open(""))
        XCTAssertFalse(launcher.open("cmd:ffffff:say hi"), "bound elsewhere: WE's \"User shortcut blocked.\"")
        XCTAssertEqual(opener.calls, [])
    }

    func testTheLauncherReturnsWhetherTheOpenStarted() {
        let opener = RecordingUserShortcutOpener()
        opener.result = false
        XCTAssertFalse(UserShortcutLauncher(opener: opener, systemHash: machineHash).open("cmd:a1b2c3:false"))
        XCTAssertEqual(opener.calls, ["cmd false"])
    }

    func testArgumentsSplitLikeAShellWithoutExpansion() {
        let words: [String] = WorkspaceUserShortcutOpener.splitArguments(#"  -a "b c" 'd e' f"" $HOME "#)
        XCTAssertEqual(words, ["-a", "b c", "d e", "f", "$HOME"])
        XCTAssertEqual(WorkspaceUserShortcutOpener.splitArguments(#""""#), [""])
    }

    // MARK: - Only the user binds

    func testScriptsIgnoreWhatProjectJSONSays() throws {
        var properties = SceneScriptUserProperties(project: try SceneScriptSiteBuilder.document(from: Data(#"""
            {"general": {"properties": {"go": {"type": "usershortcut", "text": "Go",
             "value": "cmd:a1b2c3:rm -rf ~", "isbound": true, "commandtype": "command", "file": "rm -rf ~"}}}}
            """#.utf8)))
        XCTAssertEqual(properties.userShortcutBindings, ["go": ""], "the authored value never binds")
        var entry = try XCTUnwrap(properties.payload()["go"] as? [String: Any])
        XCTAssertEqual(Set(entry.keys), ["type", "isbound"])
        XCTAssertEqual(entry["isbound"] as? Bool, false)

        properties.setStoredValues(["go": "directory:a1b2c3:/Users/me/Music"])
        XCTAssertEqual(properties.userShortcutBindings, ["go": "directory:a1b2c3:/Users/me/Music"])
        entry = try XCTUnwrap(properties.payload()["go"] as? [String: Any])
        XCTAssertEqual(Set(entry.keys), ["type", "isbound", "commandtype", "file"], "scripts never get the stored binding")
        XCTAssertEqual(entry["isbound"] as? Bool, true)
        XCTAssertEqual(entry["commandtype"] as? String, "directory")
        XCTAssertEqual(entry["file"] as? String, "Music")
    }

    func testTheSidebarStartsUnbound() {
        let definition = UserPropertyDefinition(key: "go", raw: ["type": "usershortcut", "value": "cmd:a1b2c3:say hi"])
        XCTAssertEqual(definition.defaultValue, "")
    }

    func testTheBindingIsSavedWithTheOtherPropertiesAndReadBack() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "owe-user-shortcut-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            Fixtures.removeStoredSettings(for: directory)
            try? FileManager.default.removeItem(at: directory) // test scratch folder
        }
        let json = #"""
            {"file": "index.html", "title": "Shortcut fixture", "type": "web", "general": {"properties": {
             "go": {"order": 1, "text": "Go", "type": "usershortcut", "value": "cmd:a1b2c3:say authored"},
             "speed": {"order": 2, "text": "Speed", "type": "slider", "value": 0.5}}}}
            """#
        try Data(json.utf8).write(to: directory.appending(path: "project.json"))
        let project = try JSONDecoder().decode(WEProject.self, from: Data(json.utf8))
        let wallpaper = WEWallpaper(using: project, where: directory)

        let model = SceneUserPropertiesModel(wallpaper: wallpaper, scopes: [.shared])
        XCTAssertEqual(model.values["go"], "", "the authored value isn't the user's")
        let bound = "web:\(machineHash):https://example.com"
        model.set(bound, forID: "go")
        model.saveNow()

        let stored = WallpaperPropertyTargets(wallpaper: wallpaper, scopes: [.shared]).storedValues
        XCTAssertEqual(stored["go"], bound)
        XCTAssertEqual(SceneUserPropertiesModel(wallpaper: wallpaper, scopes: [.shared]).values["go"], bound)
    }
}

/// Records what a launcher asked to open, and answers `result`. Called from script threads.
final class RecordingUserShortcutOpener: UserShortcutOpening, @unchecked Sendable {
    // `lock` owns `recorded` and `result`.
    private let lock = NSLock()
    private var recorded: [String] = []
    private var answer = true

    var calls: [String] { lock.withLock { recorded } }
    var result: Bool {
        get { lock.withLock { answer } }
        set { lock.withLock { answer = newValue } }
    }

    func openFile(_ url: URL, arguments: String) -> Bool { record("file \(url.path) \(arguments)") }
    func openDirectory(_ url: URL) -> Bool { record("directory \(url.path)") }
    func openWebsite(_ url: URL) -> Bool { record("web \(url.absoluteString)") }
    func runCommand(_ command: String) -> Bool { record("cmd \(command)") }

    private func record(_ call: String) -> Bool {
        lock.withLock {
            recorded.append(call)
            return answer
        }
    }
}
