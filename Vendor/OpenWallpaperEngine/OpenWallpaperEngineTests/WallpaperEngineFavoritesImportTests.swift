import XCTest
@testable import OpenWallpaperEngine

/// Wallpaper Engine's favourites (the Steam account's favourited Workshop items) read with
/// GetUserFiles, mapped to `workshop-<id>` and merged into a favourites store on fixture defaults.
@MainActor
final class WallpaperEngineFavoritesImportTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var scratch: URL!

    override func setUpWithError() throws {
        suiteName = "app.openwallpaperengine.isolated.tests.we-favorites-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        scratch = FileManager.default.temporaryDirectory
            .appending(path: "owe-we-favorites-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        if FileManager.default.fileExists(atPath: scratch.path) {
            try FileManager.default.removeItem(at: scratch)
        }
    }

    private func favoritesFixture() throws -> Data {
        try Data(contentsOf: Fixtures.url("Workshop/api/user-files-favorites.json"))
    }

    // MARK: Reading and mapping

    func testTheQueryAsksForFavouritesWithoutTheKey() {
        let query = WorkshopSubscriptions.queryItems(steamID: "76561190000000001", page: 1, list: .favorites)
        let values = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(values["type"], "myfavorites")
        XCTAssertEqual(values["appid"], "431960")
        XCTAssertEqual(values["steamid"], "76561190000000001")
        XCTAssertNil(values["key"])
    }

    func testFavouritesMapToWorkshopKeysOnce() throws {
        guard case .items(let ids) = try WorkshopSubscriptions.outcome(from: try favoritesFixture()) else {
            return XCTFail("the fixture lists favourites")
        }
        XCTAssertEqual(WallpaperEngineFavorites.keys(forWorkshopIDs: ids), ["workshop-3000000021", "workshop-3000000022"])
        XCTAssertEqual(WallpaperEngineFavorites.keys(forWorkshopIDs: ["12", "", "abc", "12"]), ["workshop-12"])
    }

    // MARK: Merging

    func testMergingKeepsExistingFavouritesAndIsIdempotent() {
        defaults.set(["workshop-1", "/Users/me/Wallpapers/local"], forKey: "FavoriteWallpaperIds")
        let store = FavoritesStore(defaults: defaults)
        XCTAssertEqual(store.merge(["workshop-1", "workshop-2", "workshop-3"]), 2)
        XCTAssertEqual(store.ids, ["workshop-1", "workshop-2", "workshop-3", "/Users/me/Wallpapers/local"])
        XCTAssertEqual(store.merge(["workshop-2", "workshop-3"]), 0)
        XCTAssertEqual(Set(defaults.stringArray(forKey: "FavoriteWallpaperIds") ?? []), store.ids)
        XCTAssertEqual(FavoritesStore(defaults: defaults).ids, store.ids, "the merge is saved")
    }

    // MARK: Asking

    private func model(store: FavoritesStore, hasKey: Bool = true, steamID: String? = "76561190000000001",
                       answer: @escaping () throws -> WorkshopSubscriptions.Outcome) -> WallpaperEngineFavoritesImportModel {
        WallpaperEngineFavoritesImportModel(store: store, fetch: { _ in try answer() },
                                            findSteamID: { steamID }, hasAPIKey: { hasKey })
    }

    func testNoSourceWithoutAKeyOrAnAccount() async {
        let store = FavoritesStore(defaults: defaults)
        var asked = false
        for import_ in [model(store: store, hasKey: false) { asked = true; return .items(["5"]) },
                        model(store: store, steamID: nil) { asked = true; return .items(["5"]) }] {
            XCTAssertFalse(import_.isSourceAvailable)
            await import_.check()
            XCTAssertEqual(import_.phase, .idle)
            XCTAssertFalse(import_.isAsking)
        }
        XCTAssertFalse(asked, "Steam isn't asked without a source")
    }

    func testNoQuestionWhenSteamHasNoFavourites() async {
        let import_ = model(store: FavoritesStore(defaults: defaults)) { .empty }
        XCTAssertTrue(import_.isSourceAvailable)
        await import_.check()
        XCTAssertEqual(import_.phase, .noFavorites)
        XCTAssertFalse(import_.isAsking)
    }

    func testAsksForTheNewFavouritesThenMergesThemOnce() async throws {
        defaults.set(["workshop-3000000021", "workshop-9"], forKey: "FavoriteWallpaperIds")
        let store = FavoritesStore(defaults: defaults)
        let data = try favoritesFixture()
        let import_ = model(store: store) { try WorkshopSubscriptions.outcome(from: data) }

        await import_.check()
        XCTAssertEqual(import_.phase, .asking(count: 1))
        XCTAssertTrue(import_.isAsking)
        import_.importPending()
        XCTAssertEqual(import_.phase, .imported(count: 1))
        XCTAssertFalse(import_.isAsking)
        XCTAssertEqual(store.ids, ["workshop-3000000021", "workshop-3000000022", "workshop-9"])

        await import_.check()
        XCTAssertEqual(import_.phase, .upToDate, "importing again finds nothing new and doesn't ask")
        XCTAssertFalse(import_.isAsking)
        XCTAssertEqual(store.ids.count, 3)
    }

    func testDecliningChangesNothing() async throws {
        let store = FavoritesStore(defaults: defaults)
        let data = try favoritesFixture()
        let import_ = model(store: store) { try WorkshopSubscriptions.outcome(from: data) }
        await import_.check()
        XCTAssertEqual(import_.phase, .asking(count: 2))
        import_.decline()
        XCTAssertEqual(import_.phase, .idle)
        XCTAssertTrue(store.ids.isEmpty)
        XCTAssertNil(defaults.stringArray(forKey: "FavoriteWallpaperIds"))
    }

    func testAFailedRequestDoesNotAsk() async {
        let import_ = model(store: FavoritesStore(defaults: defaults)) { throw WorkshopAPIError.requestFailed }
        await import_.check()
        guard case .failed = import_.phase else { return XCTFail("expected a failure, got \(import_.phase)") }
        XCTAssertFalse(import_.isAsking)
    }

    // MARK: Which account

    private func writeLoginUsers(_ text: String, steamRoot: URL) throws {
        try FileManager.default.createDirectory(at: steamRoot.appending(path: "config"), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: steamRoot.appending(path: "config/loginusers.vdf"))
    }

    /// A chosen install inside a Steam folder (here a CrossOver-style bottle) gives the account
    /// Steam last logged in with there; the SteamCMD account wins when it is listed.
    func testTheAccountComesFromSteamCmdOrTheChosenInstallsSteamFolder() throws {
        let steam = scratch.appending(path: "drive_c/Program Files (x86)/Steam", directoryHint: .isDirectory)
        let install = steam.appending(path: "steamapps/common/wallpaper_engine", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: install.appending(path: "assets"), withIntermediateDirectories: true)
        try writeLoginUsers("""
        "users"
        {
            "76561190000000004" { "AccountName" "older" "MostRecent" "0" }
            "76561190000000005" { "AccountName" "Player" "MostRecent" "1" }
        }
        """, steamRoot: steam)
        let home = scratch.appending(path: "home", directoryHint: .isDirectory)

        XCTAssertEqual(WorkshopSubscriptions.steamRoot(containing: install.appending(path: "assets"))?.standardizedFileURL.path,
                       steam.standardizedFileURL.path)
        XCTAssertNil(WorkshopSubscriptions.steamRoot(containing: scratch))
        XCTAssertEqual(WallpaperEngineFavorites.steamID(steamCmdAccount: nil, steamCmdPath: nil,
                                                        chosenFolder: install.path, home: home), "76561190000000005")
        XCTAssertEqual(WallpaperEngineFavorites.steamID(steamCmdAccount: "older", steamCmdPath: nil,
                                                        chosenFolder: install.appending(path: "assets").path, home: home),
                       "76561190000000004")
        XCTAssertNil(WallpaperEngineFavorites.steamID(steamCmdAccount: nil, steamCmdPath: nil, chosenFolder: nil, home: home),
                     "a SteamCMD download alone names no account until SteamCMD is logged in")
    }

    func testTheOnlyListedUserCountsAsTheMostRecent() throws {
        let steam = scratch.appending(path: "Steam", directoryHint: .isDirectory)
        try writeLoginUsers(#""users" { "76561190000000006" { "AccountName" "solo" } }"#, steamRoot: steam)
        XCTAssertEqual(WorkshopSubscriptions.mostRecentSteamID64(steamRoots: [steam]), "76561190000000006")
        try writeLoginUsers(#""users" { "76561190000000006" { "AccountName" "a" } "76561190000000007" { "AccountName" "b" } }"#,
                            steamRoot: steam)
        XCTAssertNil(WorkshopSubscriptions.mostRecentSteamID64(steamRoots: [steam]), "two accounts and no MostRecent: no guess")
    }
}
