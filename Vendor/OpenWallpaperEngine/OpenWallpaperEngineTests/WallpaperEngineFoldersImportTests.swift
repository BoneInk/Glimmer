import XCTest
@testable import OpenWallpaperEngine

/// Importing Wallpaper Engine's Installed folders from its `config.json`
/// (`<account>.general.browser.folders`), from a fixture written to that structure.
@MainActor
final class WallpaperEngineFoldersImportTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suite = "owe-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private var configURL: URL { Fixtures.url("Library/we-folders/config.json") }

    /// The installed local wallpaper the fixture's `pixel-town` path names.
    private let localKeys = ["pixel-town": "/Library/pixel-town"]

    func testParsesWEsFolders() throws {
        let folders = try WallpaperEngineFolders.folders(inConfig: Data(contentsOf: configURL))
        XCTAssertEqual(folders.map(\.title), ["Games", "Calm"], "a folder without a title is skipped")
        let games = folders[0]
        XCTAssertEqual(games.color, .red)
        XCTAssertEqual(games.icon, .gamepad)
        XCTAssertEqual(games.items, ["1000000001", "1000000002"])
        XCTAssertEqual(games.subfolders.map(\.title), ["Retro"])
        XCTAssertEqual(games.subfolders[0].icon, .rocket, "the closed icon; the open one is WE's hover")
        XCTAssertNil(folders[1].color, "an unknown colour is the default")
    }

    /// WE stores the colour's class and the icon's Font Awesome classes; a missing key is the default.
    func testParsesWEsColourAndIconClasses() throws {
        func folder(_ fields: String) throws -> InstalledFolder {
            let json = #"{"u": {"general": {"browser": {"folders": [{"type": "folder", "title": "F", "items": {}, "subfolders": []"#
                + fields + "}]}}}}"
            return try XCTUnwrap(WallpaperEngineFolders.folders(inConfig: Data(json.utf8)).first)
        }
        let plain = try folder("")
        XCTAssertNil(plain.color, "no folderColor: Default")
        XCTAssertNil(plain.icon, "no folderIcon: the plain folder")
        for color in InstalledFolderColor.allCases {
            XCTAssertEqual(try folder(#", "folderColor": "\#(color.rawValue)""#).color, color)
        }
        XCTAssertEqual(try folder(#", "folderColor": "fas fa-square browseFolderColorDarkGreen""#).color, .darkGreen,
                       "the class among the picker's other classes")
        for icon in InstalledFolderIcon.allCases {
            var fields = #", "folderIcon": "\#(icon.rawValue)""#
            if let open = icon.weOpenClass { fields += #", "folderIconOpen": "\#(open)""# }
            XCTAssertEqual(try folder(fields).icon, icon, icon.rawValue)
        }
        XCTAssertNil(try folder(#", "folderIcon": "fas fa-folder""#).icon, "WE's plain folder is the default")
        XCTAssertEqual(try folder(#", "folderIcon": "fa fa-star""#).icon, .star, "the old `fa` style WE renders as `fas`")
        XCTAssertEqual(try folder(#", "folderIcon": "far fa-snowflake""#).icon, .snowflake, "the picker's outline snowflake")
        XCTAssertEqual(try folder(#", "folderIconOpen": "far fa-burst""#).icon, .balloons, "only the open variant")
        XCTAssertNil(try folder(#", "folderIcon": "fas fa-unicorn""#).icon, "an unknown icon is the default")
    }

    func testMapsItemsToKeysHere() {
        XCTAssertEqual(WallpaperEngineFolders.key(forItem: "1000000001", localKeys: [:]), "workshop-1000000001")
        XCTAssertEqual(WallpaperEngineFolders.key(forItem: "C:/Users/a/My Wallpapers/pixel-town/project.json", localKeys: localKeys),
                       "/Library/pixel-town")
        XCTAssertEqual(WallpaperEngineFolders.key(forItem: #"D:\SteamLibrary\steamapps\workshop\content\431960\777\scene.pkg"#, localKeys: [:]),
                       "workshop-777", "a Workshop item's file names its id")
        XCTAssertNil(WallpaperEngineFolders.key(forItem: "C:/x/not-installed/scene.json", localKeys: localKeys))
        XCTAssertNil(WallpaperEngineFolders.key(forItem: "https://example.com/", localKeys: localKeys))
    }

    func testFindsTheConfigBesideTheChosenFolder() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "we-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) } // Cleanup only.
        try FileManager.default.createDirectory(at: root.appending(path: "assets"), withIntermediateDirectories: true)
        XCTAssertNil(WallpaperEngineFolders.configURL(chosenFolder: root.path), "no config.json: nothing to offer")
        try Data("{}".utf8).write(to: root.appending(path: "config.json"))
        XCTAssertEqual(WallpaperEngineFolders.configURL(chosenFolder: root.path)?.lastPathComponent, "config.json")
        XCTAssertEqual(WallpaperEngineFolders.configURL(chosenFolder: root.appending(path: "assets").path)?.standardizedFileURL,
                       root.appending(path: "config.json").standardizedFileURL, "the assets folder's install")
        XCTAssertNil(WallpaperEngineFolders.configURL(chosenFolder: nil))
    }

    /// Importing merges: existing folders and filings stay, and importing again adds nothing.
    func testImportMergesAndIsIdempotent() async throws {
        let store = InstalledFolderStore(defaults: defaults)
        let mine = try XCTUnwrap(store.update { $0.create(title: "games") })
        store.update { $0.setColor(.blue, of: mine) }
        store.update { $0.move(items: ["workshop-1000000002"], to: nil) }
        let elsewhere = try XCTUnwrap(store.update { $0.create(title: "Elsewhere") })
        store.update { $0.move(items: ["workshop-1000000002"], to: elsewhere) }

        let model = WallpaperEngineFoldersImportModel(store: store, findConfig: { self.configURL }, localKeys: { self.localKeys })
        XCTAssertTrue(model.isSourceAvailable)
        await model.check()
        XCTAssertEqual(model.phase, .asking(folders: 2, wallpapers: 2), "Retro and Calm; 1000000001 and pixel-town")
        XCTAssertTrue(model.isAsking)
        model.importPending()
        XCTAssertEqual(model.phase, .imported(folders: 2, wallpapers: 2))

        let tree = store.tree
        XCTAssertEqual(tree.folders.map(\.title), ["games", "Elsewhere", "Calm"], "Games is the same folder as games")
        XCTAssertEqual(tree.folder(mine)?.color, .blue, "a colour set here stays")
        XCTAssertEqual(tree.folder(mine)?.icon, .gamepad, "an icon not set here comes from WE")
        XCTAssertEqual(tree.folder(mine)?.items, ["workshop-1000000001"])
        XCTAssertEqual(tree.folder(containing: "workshop-1000000002")?.id, elsewhere, "a wallpaper filed here stays where it is")
        XCTAssertEqual(tree.folder(containing: "/Library/pixel-town")?.title, "Retro")

        await model.check()
        XCTAssertEqual(model.phase, .upToDate, "nothing new: no question")
        XCTAssertFalse(model.isAsking)
        XCTAssertEqual(store.tree, tree)
    }

    func testDecliningChangesNothing() async throws {
        let store = InstalledFolderStore(defaults: defaults)
        let model = WallpaperEngineFoldersImportModel(store: store, findConfig: { self.configURL }, localKeys: { [:] })
        await model.check()
        model.decline()
        XCTAssertEqual(model.phase, .idle)
        XCTAssertTrue(store.tree.folders.isEmpty)
    }

    func testAConfigWithoutFolders() async throws {
        let store = InstalledFolderStore(defaults: defaults)
        let model = WallpaperEngineFoldersImportModel(store: store, findConfig: { URL(fileURLWithPath: "/config.json") },
                                                      localKeys: { [:] },
                                                      read: { _ in Data(#"{"user": {"general": {"browser": {"folders": []}}}}"#.utf8) })
        await model.check()
        XCTAssertEqual(model.phase, .noFolders)

        let broken = WallpaperEngineFoldersImportModel(store: store, findConfig: { URL(fileURLWithPath: "/config.json") },
                                                       localKeys: { [:] }, read: { _ in Data("not json".utf8) })
        await broken.check()
        guard case .failed = broken.phase else { return XCTFail("\(broken.phase)") }
    }
}
