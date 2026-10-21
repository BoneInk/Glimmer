import AppKit
import XCTest
@testable import OpenWallpaperEngine

/// The Installed tab's folders: Wallpaper Engine's folder operations, where they are saved and by
/// which keys, and which wallpapers each place lists for the search and filters.
@MainActor
final class InstalledFolderTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suite = "owe-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func wallpaper(_ folder: String, title: String, workshopID: Int? = nil) -> WEWallpaper {
        var project = WEProject(file: "scene.json", title: title, type: "scene")
        project.workshopid = workshopID.map { .int($0) }
        return WEWallpaper(using: project, where: URL(fileURLWithPath: "/library/\(folder)"))
    }

    // MARK: Operations

    func testCreateRenameColourIconAndNest() throws {
        var tree = InstalledFolderTree()
        let games = try XCTUnwrap(tree.create(title: "  Games "))
        let retro = try XCTUnwrap(tree.create(title: "Retro", in: games))
        XCTAssertNil(tree.create(title: "Orphan", in: UUID()), "a parent that's gone")
        XCTAssertEqual(tree.folder(games)?.title, "Games", "trimmed")
        XCTAssertEqual(tree.path(to: retro).map(\.title), ["Games", "Retro"])
        XCTAssertEqual(tree.subfolders(of: games).map(\.id), [retro])

        XCTAssertTrue(tree.rename(retro, to: "Arcade"))
        XCTAssertTrue(tree.rename(retro, to: "   "), "blank changes nothing")
        XCTAssertEqual(tree.folder(retro)?.title, "Arcade")
        tree.setColor(.red, of: games)
        tree.setIcon(.gamepad, of: retro)
        XCTAssertEqual(tree.folder(games)?.color, .red)
        XCTAssertEqual(tree.folder(retro)?.icon, .gamepad)
        tree.setColor(nil, of: games)
        XCTAssertNil(tree.folder(games)?.color, "Default")
        XCTAssertEqual(tree.allFolders().map(\.path), ["Games", "Games / Arcade"])
    }

    /// As in WE, a wallpaper is in one folder: moving it takes it out of the last one.
    func testMovingFilesAWallpaperInOneFolder() throws {
        var tree = InstalledFolderTree()
        let a = try XCTUnwrap(tree.create(title: "A"))
        let b = try XCTUnwrap(tree.create(title: "B", in: a))
        XCTAssertTrue(tree.move(items: ["workshop-1", "workshop-2"], to: a))
        XCTAssertTrue(tree.move(items: ["workshop-2"], to: b))
        XCTAssertEqual(tree.folder(a)?.items, ["workshop-1"])
        XCTAssertEqual(tree.folder(b)?.items, ["workshop-2"])
        XCTAssertEqual(tree.folder(containing: "workshop-2")?.id, b)
        XCTAssertEqual(tree.keys(inside: a), ["workshop-1", "workshop-2"])

        XCTAssertFalse(tree.move(items: ["workshop-1"], to: UUID()), "a folder that's gone changes nothing")
        XCTAssertEqual(tree.folder(a)?.items, ["workshop-1"])
        XCTAssertTrue(tree.move(items: ["workshop-1"], to: nil))
        XCTAssertNil(tree.folder(containing: "workshop-1"), "back at the top level")
    }

    func testMovingFoldersNeverIntoThemselves() throws {
        var tree = InstalledFolderTree()
        let a = try XCTUnwrap(tree.create(title: "A"))
        let b = try XCTUnwrap(tree.create(title: "B", in: a))
        let c = try XCTUnwrap(tree.create(title: "C"))
        XCTAssertFalse(tree.move(folder: a, to: b), "into its own subfolder")
        XCTAssertFalse(tree.move(folder: a, to: a))
        XCTAssertTrue(tree.move(folder: c, to: b))
        XCTAssertEqual(tree.path(to: c).map(\.title), ["A", "B", "C"])
        XCTAssertTrue(tree.move(folder: b, to: nil))
        XCTAssertEqual(tree.folders.map(\.title), ["A", "B"])
        XCTAssertEqual(tree.path(to: c).map(\.title), ["B", "C"], "subfolders go with it")
    }

    /// Remove Folder removes its subfolders; their wallpapers go back to the top level, and no
    /// other folder loses anything.
    func testRemovingAFolderReturnsItsWallpapersToTheTopLevel() throws {
        var tree = InstalledFolderTree()
        let a = try XCTUnwrap(tree.create(title: "A"))
        let b = try XCTUnwrap(tree.create(title: "B", in: a))
        let other = try XCTUnwrap(tree.create(title: "Other"))
        tree.move(items: ["workshop-1"], to: a)
        tree.move(items: ["workshop-2"], to: b)
        tree.move(items: ["workshop-3"], to: other)
        let removed = tree.remove(a)
        XCTAssertEqual(removed?.title, "A")
        XCTAssertNil(tree.folder(b))
        XCTAssertEqual(tree.filedKeys, ["workshop-3"])
        XCTAssertNil(tree.remove(a), "gone already")
    }

    func testFoldersSortByTitleAsWEDoes() {
        let folders = ["beta", "Alpha", "Folder 10", "Folder 9"].map { InstalledFolder(title: $0) }
        XCTAssertEqual(InstalledFolderTree.sortedByTitle(folders).map(\.title), ["Alpha", "beta", "Folder 9", "Folder 10"])
    }

    // MARK: Persistence and keys

    func testStoreSavesEveryChangeAndReadsItBack() throws {
        let store = InstalledFolderStore(defaults: defaults)
        var changes = 0
        store.onChange = { changes += 1 }
        let id = try XCTUnwrap(store.update { $0.create(title: "Games") })
        store.update { $0.move(items: ["workshop-42"], to: id) }
        store.update { $0.setColor(.blue, of: id) }
        store.update { _ in }
        XCTAssertEqual(changes, 3, "an update that changes nothing isn't saved or announced")

        let again = InstalledFolderStore(defaults: defaults)
        XCTAssertEqual(again.tree, store.tree)
        XCTAssertEqual(again.tree.folder(id)?.color, .blue)
        XCTAssertNotNil(defaults.data(forKey: InstalledFolderStore.storageKey))
    }

    func testUnreadableStoredFoldersAreDropped() {
        defaults.set(Data("not json".utf8), forKey: InstalledFolderStore.storageKey)
        XCTAssertEqual(InstalledFolderStore(defaults: defaults).tree, InstalledFolderTree())
    }

    /// One folder that doesn't decode doesn't drop its siblings; an unknown colour is the default.
    func testDecodesFolderByFolder() throws {
        let json = """
        [{"id": "\(UUID().uuidString)", "title": "Good", "color": "browseFolderColorTeal", "items": ["workshop-1"], "subfolders": []},
         {"title": "No id"},
         {"id": "\(UUID().uuidString)", "title": "Also good", "icon": "fas fa-heart", "items": [], "subfolders": [{"bad": true}]}]
        """
        let tree = try JSONDecoder().decode(InstalledFolderTree.self, from: Data(json.utf8))
        XCTAssertEqual(tree.folders.map(\.title), ["Good", "Also good"])
        XCTAssertNil(tree.folders[0].color)
        XCTAssertEqual(tree.folders[1].icon, .heart)
        XCTAssertEqual(tree.folders[0].items, ["workshop-1"])
    }

    /// Wallpapers are filed by their favourites key: a Workshop item by `workshop-<id>`, so it is
    /// back in its folder when downloaded again, and a local one by its folder.
    func testWallpapersAreFiledByTheirFavouritesKey() throws {
        let workshop = wallpaper("1234", title: "Rain", workshopID: 1234)
        let local = wallpaper("my-scene", title: "Mine")
        XCTAssertEqual(FavoritesStore.key(for: workshop), "workshop-1234")
        XCTAssertEqual(FavoritesStore.key(for: local), "/library/my-scene")

        var tree = InstalledFolderTree()
        let id = try XCTUnwrap(tree.create(title: "Rainy"))
        tree.move(items: [FavoritesStore.key(for: workshop)], to: id)
        let redownloaded = wallpaper("1234", title: "Rain (updated)", workshopID: 1234)
        XCTAssertEqual(InstalledFolderScope.wallpapers([redownloaded, local], in: id, tree: tree).map(\.project.title), ["Rain (updated)"])
    }

    func testEverySymbolExists() {
        XCTAssertNotNil(NSImage(systemSymbolName: InstalledFolderIcon.defaultSystemImage, accessibilityDescription: nil))
        for icon in InstalledFolderIcon.allCases {
            XCTAssertNotNil(NSImage(systemSymbolName: icon.systemImage, accessibilityDescription: nil), icon.rawValue)
            XCTAssertNotNil(NSImage(systemSymbolName: icon.openSystemImage, accessibilityDescription: nil), icon.rawValue)
        }
    }

    /// WE's Change Icon grid (2.8.42's scripts.js): 30 icons in its order, the plain folder first.
    func testIconsAreWEsThirtyInWEsOrder() {
        let names = ["folder", "star", "heart", "gem", "car", "rocket", "snowflake", "thumbs-up", "gamepad-modern", "gift",
                     "music", "trash", "bug", "magic", "banana", "alien", "alien-8bit", "bat", "bomb", "boombox",
                     "candle-holder", "dragon", "fire", "meteor", "tree-palm", "skull-crossbones", "tree-christmas",
                     "tv-retro", "balloons", "bone"]
        XCTAssertEqual(InstalledFolderIcon.pickerOrder.map { $0?.rawValue ?? "fas fa-folder" }, names.map { "fas fa-\($0)" })
        let open = Dictionary(uniqueKeysWithValues: InstalledFolderIcon.allCases.compactMap { icon in icon.weOpenClass.map { (icon, $0) } })
        XCTAssertEqual(open, [.car: "fas fa-car-burst", .rocket: "fas fa-rocket-launch", .magic: "fas fa-wand-magic-sparkles",
                              .bomb: "fas fa-explosion", .balloons: "far fa-burst"])
    }

    /// An open folder (shown, or a drop target) draws WE's open variant where it has one.
    func testOpenVariant() {
        XCTAssertEqual(InstalledFolder(title: "A", icon: .rocket).systemImage(open: true), "airplane.departure")
        XCTAssertEqual(InstalledFolder(title: "A", icon: .rocket).systemImage(), "airplane")
        XCTAssertEqual(InstalledFolder(title: "A", icon: .star).systemImage(open: true), "star.fill", "no open variant")
        XCTAssertEqual(InstalledFolder(title: "A").systemImage(open: true), InstalledFolderIcon.defaultSystemImage)
    }

    /// Folders saved by earlier versions (icons by their WE class) still read.
    func testStoredIconsStillDecode() throws {
        for icon in InstalledFolderIcon.allCases {
            let json = #"[{"id": "\#(UUID().uuidString)", "title": "F", "icon": "\#(icon.rawValue)", "color": "browseFolderColorRed", "items": [], "subfolders": []}]"#
            let folder = try XCTUnwrap(JSONDecoder().decode(InstalledFolderTree.self, from: Data(json.utf8)).folders.first)
            XCTAssertEqual(folder.icon, icon)
            XCTAssertEqual(folder.color, .red)
            let again = try JSONDecoder().decode(InstalledFolderTree.self, from: JSONEncoder().encode(InstalledFolderTree(folders: [folder])))
            XCTAssertEqual(again.folders.first?.icon, icon, "written back as WE's class")
        }
    }

    // MARK: Search and filter scope

    /// As in WE, the top level lists the wallpapers in no folder and a folder only its own; the
    /// search then looks within that list only.
    func testSearchAndFiltersApplyWithinTheFolderShown() throws {
        let rain = wallpaper("1", title: "Rain", workshopID: 1)
        let rainyCity = wallpaper("2", title: "Rainy City", workshopID: 2)
        let forest = wallpaper("3", title: "Forest", workshopID: 3)
        let all = [rain, rainyCity, forest]
        var tree = InstalledFolderTree()
        let city = try XCTUnwrap(tree.create(title: "City"))
        let nested = try XCTUnwrap(tree.create(title: "Night", in: city))
        tree.move(items: ["workshop-2"], to: city)

        let top = InstalledFolderScope.wallpapers(all, in: nil, tree: tree)
        XCTAssertEqual(top.map(\.project.title), ["Rain", "Forest"])
        XCTAssertEqual(top.filter { InstalledLibraryModel.matchesSearch("rain", wallpaper: $0, tags: []) }.map(\.project.title),
                       ["Rain"], "a search at the top level doesn't reach into folders")
        let inCity = InstalledFolderScope.wallpapers(all, in: city, tree: tree)
        XCTAssertEqual(inCity.filter { InstalledLibraryModel.matchesSearch("rain", wallpaper: $0, tags: []) }.map(\.project.title),
                       ["Rainy City"])
        XCTAssertTrue(InstalledFolderScope.wallpapers(all, in: nested, tree: tree).isEmpty, "a subfolder lists only its own")
        XCTAssertEqual(InstalledFolderScope.wallpaperCount(of: try XCTUnwrap(tree.folder(city)),
                                                           installedKeys: ["workshop-1", "workshop-2", "workshop-3"]), 1)
        XCTAssertEqual(InstalledFolderScope.wallpapers(all, in: nil, tree: InstalledFolderTree()).count, 3, "no folders: everything")
    }

    /// New folders are numbered as Finder numbers them, among the folders beside them only.
    func testNewFolderTitlesAreUnique() throws {
        var tree = InstalledFolderTree()
        XCTAssertEqual(tree.uniqueTitle("New Folder", in: nil), "New Folder")
        let first = try XCTUnwrap(tree.create(title: "New Folder"))
        tree.create(title: "new folder 2")
        XCTAssertEqual(tree.uniqueTitle("New Folder", in: nil), "New Folder 3", "taken ignoring case")
        XCTAssertEqual(tree.uniqueTitle("New Folder", in: first), "New Folder", "another level")
    }

    private func library() -> InstalledLibraryModel {
        InstalledLibraryModel(filters: FilterResultsViewModel(), steamCmd: SteamCmdService(), presentation: ContentPresentation(),
                              folders: InstalledFolderStore(defaults: defaults))
    }

    /// A wallpaper's Create Folder: one change makes a numbered folder in the folder shown and
    /// moves the wallpapers into it, out of wherever they were.
    func testCreateFolderMovesTheWallpapersIn() throws {
        let library = library()
        let games = try XCTUnwrap(library.createFolder(named: "Games"))
        library.open(folder: games)
        library.folders.update { $0.create(title: "New Folder", in: games) }
        let other = try XCTUnwrap(library.folders.update { $0.create(title: "Other") })
        library.folders.update { $0.move(items: ["workshop-1"], to: other) }
        var changes = 0
        let onChange = library.folders.onChange
        library.folders.onChange = { changes += 1; onChange?() }

        let id = try XCTUnwrap(library.createFolder(moving: [wallpaper("1", title: "A", workshopID: 1),
                                                             wallpaper("mine", title: "B")]))
        XCTAssertEqual(changes, 1, "one change")
        let folder = try XCTUnwrap(library.folders.tree.folder(id))
        XCTAssertEqual(folder.title, "New Folder 2")
        XCTAssertEqual(folder.items, ["workshop-1", "/library/mine"])
        XCTAssertEqual(library.folders.tree.path(to: id).map(\.title), ["Games", "New Folder 2"], "in the folder shown")
        XCTAssertEqual(library.folders.tree.folder(other)?.items, [], "out of the last folder")
        XCTAssertEqual(library.newFolderTitle, "New Folder 3")
    }

    /// Drops: a selection's wallpapers move together, and a folder never into itself or below it.
    func testDropsMoveWallpapersAndFolders() throws {
        let library = library()
        let a = try XCTUnwrap(library.createFolder(named: "A"))
        let b = try XCTUnwrap(library.folders.update { $0.create(title: "B", in: a) })
        let c = try XCTUnwrap(library.createFolder(named: "C"))

        XCTAssertTrue(library.drop([InstalledDragPayload.wallpapers(["workshop-1", "workshop-2"]).text], into: b))
        XCTAssertEqual(library.folders.tree.folder(b)?.items, ["workshop-1", "workshop-2"])
        XCTAssertTrue(library.drop([InstalledDragPayload.wallpapers(["workshop-2"]).text], into: nil), "a breadcrumb: Home")
        XCTAssertEqual(library.folders.tree.filedKeys, ["workshop-1"])

        XCTAssertFalse(library.canDrop(.folder(a), into: a), "into itself")
        XCTAssertFalse(library.canDrop(.folder(a), into: b), "into its subfolder")
        XCTAssertFalse(library.drop([InstalledDragPayload.folder(a).text], into: b))
        XCTAssertEqual(library.folders.tree.path(to: b).map(\.title), ["A", "B"], "unchanged")
        XCTAssertTrue(library.canDrop(.folder(c), into: b))
        XCTAssertTrue(library.drop([InstalledDragPayload.folder(c).text], into: b))
        XCTAssertEqual(library.folders.tree.path(to: c).map(\.title), ["A", "B", "C"])
        XCTAssertTrue(library.drop([InstalledDragPayload.folder(c).text], into: nil))
        XCTAssertEqual(library.folders.tree.folders.map(\.title).sorted(), ["A", "C"])
        XCTAssertFalse(library.drop(["some text"], into: a), "not ours")
    }

    // MARK: Drags

    func testDragPayloadRoundTrips() {
        let id = UUID()
        for payload in [InstalledDragPayload.wallpapers(["workshop-1", "/library/my scene"]), .folder(id)] {
            XCTAssertEqual(InstalledDragPayload(text: payload.text), payload)
        }
        XCTAssertNil(InstalledDragPayload(text: "workshop-1"), "any other text")
        XCTAssertNil(InstalledDragPayload(text: "open-wallpaper-engine/installed-folder\nnot-a-uuid"))
    }
}
