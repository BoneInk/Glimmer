import XCTest
@testable import OpenWallpaperEngine

/// Importing a Workshop collection from Steam's keyless Web API, read from fixture JSON (no
/// network): the id the user pastes, the children, the items' details, and the checklist.
final class WorkshopCollectionImportTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: Fixtures.url("Workshop/api/\(name)"))
    }

    func testTheCollectionIDComesFromANumberOrASteamLink() {
        XCTAssertEqual(WorkshopCollection.collectionID(from: " 3000000001\n"), "3000000001")
        XCTAssertEqual(WorkshopCollection.collectionID(from: "https://steamcommunity.com/sharedfiles/filedetails/?id=3000000001"), "3000000001")
        XCTAssertEqual(WorkshopCollection.collectionID(from: "https://steamcommunity.com/workshop/filedetails/?l=german&id=42&searchtext="), "42")
        XCTAssertNil(WorkshopCollection.collectionID(from: "https://steamcommunity.com/sharedfiles/filedetails/?id=abc"))
        XCTAssertNil(WorkshopCollection.collectionID(from: "collection"))
        XCTAssertNil(WorkshopCollection.collectionID(from: ""))
        XCTAssertEqual(String(decoding: WorkshopCollection.detailsBody(collectionID: "42"), as: UTF8.self),
                       "collectioncount=1&publishedfileids[0]=42")
    }

    /// Children in Steam's sort order; nested collections are marked so they can be left out.
    func testChildrenParseInSortOrder() throws {
        let children = try XCTUnwrap(try WorkshopCollection.children(of: "3000000001", in: fixture("collection-details.json")))
        XCTAssertEqual(children.map(\.id), ["3000000011", "3000000012", "3000000013", "3000000099"])
        XCTAssertEqual(children.last?.type, .collection)
        XCTAssertEqual(children.first?.type, .item)
        XCTAssertNil(try WorkshopCollection.children(of: "3000000002", in: fixture("collection-details-private.json")))
        XCTAssertNil(try WorkshopCollection.children(of: "999", in: fixture("collection-details.json")))
    }

    /// Titles, previews, type and rating come from GetPublishedFileDetails' tags.
    func testItemDetailsBecomeCandidates() throws {
        let items = try WorkshopAPIService.parseItems(from: fixture("published-file-details.json"))
        let candidates = items.map { WorkshopImportCandidate(item: $0, isInLibrary: $0.id == "3000000011") }
        XCTAssertEqual(candidates.map(\.title), ["Quiet Lake", "Night Drive", "Desk Toy"])
        XCTAssertEqual(candidates.map(\.contentRating), ["Everyone", "Mature", "Everyone"])
        XCTAssertEqual(candidates.map(\.type), ["Scene", "Video", "Application"])
        XCTAssertEqual(candidates.first?.previewURL?.absoluteString, "https://example.invalid/lake.jpg")
        XCTAssertTrue(candidates[2].isApplication)
    }

    /// The rating filter starts at the app's (Everyone) and hides other items entirely; application
    /// items and items already in the library can't be checked.
    @MainActor
    func testTheChecklistRespectsTheRatingFilter() throws {
        let items = try WorkshopAPIService.parseItems(from: fixture("published-file-details.json"))
        var candidates = items.map { WorkshopImportCandidate(item: $0, isInLibrary: false) }
        candidates.append(WorkshopImportCandidate(id: "3000000014", title: "Unrated"))
        candidates.append(WorkshopImportCandidate(id: "3000000015", title: "Mine", contentRating: "Everyone", isInLibrary: true))
        let checklist = ImportChecklist(ratings: ["Everyone"])
        checklist.show(candidates)
        XCTAssertEqual(checklist.visible.map(\.id), ["3000000011", "3000000013", "3000000014", "3000000015"])
        XCTAssertEqual(checklist.hiddenCount, 1)
        XCTAssertEqual(checklist.selection.map(\.id), ["3000000011", "3000000014"])
        XCTAssertEqual(checklist.inLibrary.map(\.id), ["3000000015"])

        checklist.selectNone()
        XCTAssertEqual(checklist.selection, [])
        checklist.toggle(candidates[2])
        XCTAssertEqual(checklist.selection, [], "an application item can't be checked")

        checklist.ratings.insert("Mature")
        checklist.selectAll()
        XCTAssertEqual(checklist.selection.map(\.id), ["3000000011", "3000000012", "3000000014"])
        checklist.ratings.remove("Mature")
        XCTAssertEqual(checklist.selected, ["3000000011", "3000000014"], "a hidden item is unchecked")

        checklist.ratings = ["Mature"]
        XCTAssertEqual(checklist.visible.map(\.id), ["3000000012", "3000000014"], "an unrated item always shows, as in Installed")

        XCTAssertEqual(ImportChecklist(ratings: []).ratings, Set(WorkshopTags.ratings), "no filter shows every rating")
    }
}

/// "Download my subscriptions": best effort, so Steam's empty answer is its own outcome.
final class WorkshopSubscriptionsTests: XCTestCase {
    func testAnEmptyResponseMeansSteamReturnedNothing() throws {
        let empty = try Data(contentsOf: Fixtures.url("Workshop/api/user-files-empty.json"))
        XCTAssertEqual(try WorkshopSubscriptions.outcome(from: empty), .empty)
        XCTAssertEqual(try WorkshopSubscriptions.outcome(from: Data(#"{"response":{"total":0,"publishedfiledetails":[]}}"#.utf8)), .empty)
        XCTAssertEqual(try WorkshopSubscriptions.outcome(from: Data("{}".utf8)), .empty)
        let found = try Data(contentsOf: Fixtures.url("Workshop/api/user-files-subscribed.json"))
        XCTAssertEqual(try WorkshopSubscriptions.outcome(from: found), .items(["3000000011", "3000000012"]))
        XCTAssertThrowsError(try WorkshopSubscriptions.outcome(from: Data("<html>".utf8)))
    }

    /// The query names the account and asks for subscriptions; the key is never in it.
    func testTheQueryAsksForSubscribedItemsWithoutTheKey() {
        let query = WorkshopSubscriptions.queryItems(steamID: "76561190000000001", page: 2)
        let values = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(values["type"], "mysubscriptions")
        XCTAssertEqual(values["appid"], "431960")
        XCTAssertEqual(values["steamid"], "76561190000000001")
        XCTAssertEqual(values["page"], "2")
        XCTAssertNil(values["key"])
    }

    /// The logged-in account's SteamID64 from Steam's own files.
    func testTheSteamIDComesFromSteamsFiles() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "owe-steam-root-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) } // scratch cleanup
        let other = root.appending(path: "other", directoryHint: .isDirectory)
        let steam = root.appending(path: "steam", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: other.appending(path: "config"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: steam.appending(path: "config"), withIntermediateDirectories: true)
        try Data("""
        "users"
        {
            "76561190000000002" { "AccountName" "someoneelse" }
            "76561190000000001" { "AccountName" "Player" "PersonaName" "P" }
        }
        """.utf8).write(to: steam.appending(path: "config/loginusers.vdf"))
        try Data("""
        "InstallConfigStore" { "Software" { "Valve" { "Steam" { "Accounts" { "cfguser" { "SteamID" "76561190000000003" } } } } } }
        """.utf8).write(to: other.appending(path: "config/config.vdf"))
        XCTAssertEqual(WorkshopSubscriptions.steamID64(forAccount: "player", steamRoots: [other, steam]), "76561190000000001")
        XCTAssertEqual(WorkshopSubscriptions.steamID64(forAccount: "cfguser", steamRoots: [steam, other]), "76561190000000003")
        XCTAssertNil(WorkshopSubscriptions.steamID64(forAccount: "nobody", steamRoots: [steam, other]))
        XCTAssertNil(WorkshopSubscriptions.steamID64(forAccount: "", steamRoots: [steam]))
        XCTAssertTrue(WorkshopSubscriptions.isSteamID64("76561190000000001"))
        XCTAssertFalse(WorkshopSubscriptions.isSteamID64("12345"))
    }
}
