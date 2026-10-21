import XCTest
@testable import OpenWallpaperEngine

/// Installed wallpapers' tags: project.json's merged with the Workshop item's, which are read from
/// Steam once (in batches, only with an API key) and stored with the installed ids. Steam is a
/// fixture; nothing touches the network or the keychain.
@MainActor
final class InstalledWorkshopTagsTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var index: DownloadedWallpaperIndex!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "owe-installed-tags-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suiteName = "owe-installed-tags-tests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let root = root!
        index = DownloadedWallpaperIndex(defaults: defaults, libraryDirectory: { root })
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try FileManager.default.removeItem(at: root)
    }

    private func wallpaper(_ folder: String, tags: [String]?, workshopId: String? = nil) -> WEWallpaper {
        let project = WEProject(file: "scene.json", tags: tags, title: "Wallpaper \(folder)",
                                workshopid: workshopId.map { .string($0) }, type: "scene")
        return WEWallpaper(using: project, where: root.appending(path: folder))
    }

    private func item(_ id: String, tags: [String], timeUpdated: Int?) -> WorkshopItem {
        WorkshopItem(id: id, title: "Item \(id)", previewURL: nil, tags: tags, subscriptions: 0, fileSize: 0,
                     creatorAppId: nil, creatorId: nil, description: nil, votesUp: 0, votesDown: 0,
                     timeUpdated: timeUpdated)
    }

    // MARK: Merging

    func testMergeKeepsProjectOrderThenAddsSteamsWithoutDuplicatesOrWallpaper() {
        let merged = InstalledWorkshopTags.merged(
            project: ["Anime", " Music ", "wallpaper", ""],
            workshop: ["Abstract", "anime", "Everyone", "Wallpaper", "Music", "1920 x 1080"])
        XCTAssertEqual(merged, ["Anime", "Music", "Abstract", "Everyone", "1920 x 1080"])
        XCTAssertEqual(InstalledWorkshopTags.merged(project: nil, workshop: nil), [])
        XCTAssertEqual(InstalledWorkshopTags.merged(project: ["Scene"], workshop: nil), ["Scene"])
    }

    func testOnlyProjectsWithAtMostOneTagNeedSteamsTags() {
        XCTAssertTrue(InstalledWorkshopTags.projectNeedsWorkshopTags(wallpaper("1", tags: nil).project))
        XCTAssertTrue(InstalledWorkshopTags.projectNeedsWorkshopTags(wallpaper("1", tags: ["Anime"]).project))
        XCTAssertTrue(InstalledWorkshopTags.projectNeedsWorkshopTags(wallpaper("1", tags: ["Wallpaper", "Anime"]).project))
        XCTAssertFalse(InstalledWorkshopTags.projectNeedsWorkshopTags(wallpaper("1", tags: ["Anime", "Girls"]).project))
    }

    func testWorkshopIdComesFromTheProjectOrANumericFolder() {
        XCTAssertEqual(InstalledWorkshopTags.workshopId(of: wallpaper("123", tags: nil)), "123")
        XCTAssertEqual(InstalledWorkshopTags.workshopId(of: wallpaper("My Scene", tags: nil, workshopId: "456")), "456")
        XCTAssertNil(InstalledWorkshopTags.workshopId(of: wallpaper("My Scene", tags: nil)))
    }

    func testTheShownTagsIncludeTheStoredOnes() {
        index.setWorkshopTags(["123": InstalledWorkshopTags(tags: ["Anime", "Girls", "Mature"], timeUpdated: 5)])
        XCTAssertEqual(InstalledWorkshopTags.tags(of: wallpaper("123", tags: ["Anime"]), in: index),
                       ["Anime", "Girls", "Mature"])
        XCTAssertEqual(InstalledWorkshopTags.tags(of: wallpaper("999", tags: ["Anime"]), in: index), ["Anime"])
    }

    // MARK: Response

    /// GetPublishedFileDetails' shape, as read live once: `time_updated` is an integer, tags are
    /// `[{"tag": …}]` and start with "Wallpaper", `file_size` is a string.
    func testParsesTimeUpdatedFromGetPublishedFileDetails() throws {
        let response = """
        {"response":{"result":1,"resultcount":2,"publishedfiledetails":[
          {"publishedfileid":"1081733658","result":1,"title":"Visualizer","file_size":"3645971",
           "time_created":1500465293,"time_updated":1671716441,
           "tags":[{"tag":"Wallpaper"},{"tag":"Web"},{"tag":"Audio responsive"},{"tag":"Everyone"},{"tag":"Abstract"}]},
          {"publishedfileid":"2","result":9}
        ]}}
        """
        let items = try WorkshopAPIService.parseItems(from: Data(response.utf8))
        XCTAssertEqual(items.map(\.id), ["1081733658"], "a missing item isn't an item")
        XCTAssertEqual(items[0].timeUpdated, 1671716441)
        XCTAssertEqual(items[0].fileSize, 3645971, "a 64-bit field arrives as a string")
        XCTAssertEqual(items[0].tags, ["Abstract", "Audio responsive", "Everyone", "Wallpaper", "Web"])
        XCTAssertEqual(InstalledWorkshopTags.merged(project: ["Music"], workshop: items[0].tags),
                       ["Music", "Abstract", "Audio responsive", "Everyone", "Web"])
    }

    // MARK: Store

    func testStoredTagsPersistWithTheInstalledIdsAndGoWithTheWallpaper() throws {
        index.setWorkshopTags(["123": InstalledWorkshopTags(tags: ["Anime"], timeUpdated: 10),
                               "456": InstalledWorkshopTags(tags: [], timeUpdated: nil)])
        let root = root!
        let reopened = DownloadedWallpaperIndex(defaults: defaults, libraryDirectory: { root })
        XCTAssertEqual(reopened.workshopTags(for: "123"), InstalledWorkshopTags(tags: ["Anime"], timeUpdated: 10))
        XCTAssertEqual(reopened.workshopTags(for: "456"), InstalledWorkshopTags(tags: [], timeUpdated: nil))

        reopened.remove(directory: root.appending(path: "123"))
        let again = DownloadedWallpaperIndex(defaults: defaults, libraryDirectory: { root })
        XCTAssertNil(again.workshopTags(for: "123"))
        XCTAssertNotNil(again.workshopTags(for: "456"))
    }

    // MARK: Refresh policy

    func testReadsOnceAndRefreshesOnlyWhenTimeUpdatedMovesOn() {
        let stored = InstalledWorkshopTags(tags: ["Anime"], timeUpdated: 100)
        typealias Plan = InstalledWorkshopTagSync.Plan
        XCTAssertEqual(InstalledWorkshopTagSync.plan(stored: nil, known: nil), Plan.fetch)
        XCTAssertEqual(InstalledWorkshopTagSync.plan(stored: stored, known: nil), Plan.upToDate)
        XCTAssertEqual(InstalledWorkshopTagSync.plan(stored: stored, known: item("1", tags: ["Anime", "Girls"], timeUpdated: 100)),
                       Plan.upToDate, "same time_updated: no refresh")
        XCTAssertEqual(InstalledWorkshopTagSync.plan(stored: stored, known: item("1", tags: ["Girls"], timeUpdated: 90)),
                       Plan.upToDate, "an older response doesn't win")
        XCTAssertEqual(InstalledWorkshopTagSync.plan(stored: stored, known: item("1", tags: ["Girls"], timeUpdated: nil)),
                       Plan.upToDate, "a response stored before time_updated was read says nothing")
        XCTAssertEqual(InstalledWorkshopTagSync.plan(stored: stored, known: item("1", tags: ["Anime", "Girls"], timeUpdated: 200)),
                       Plan.adopt(InstalledWorkshopTags(tags: ["Anime", "Girls"], timeUpdated: 200)))
        XCTAssertEqual(InstalledWorkshopTagSync.plan(stored: nil, known: item("1", tags: ["Music"], timeUpdated: 7)),
                       Plan.adopt(InstalledWorkshopTags(tags: ["Music"], timeUpdated: 7)), "a response at hand saves a request")
        var old = stored
        old.revision = 0
        XCTAssertEqual(InstalledWorkshopTagSync.plan(stored: old, known: nil), Plan.fetch, "another revision is read again")
    }

    // MARK: Sync

    private final class FakeSteam {
        var batches: [[String]] = []
        var fail = false
        /// Items Steam knows, by id; others come back missing.
        var catalogue: [String: WorkshopItem] = [:]

        func fetch(_ ids: [String]) async throws -> [WorkshopItem] {
            batches.append(ids)
            if fail { throw WorkshopAPIError.requestFailed }
            return ids.compactMap { catalogue[$0] }
        }
    }

    private final class Counter { var count = 0 }

    private func makeSync(_ steam: FakeSteam, key: String? = "KEY", known: [String: WorkshopItem] = [:],
                          keyChecks: Counter = Counter()) -> InstalledWorkshopTagSync {
        InstalledWorkshopTagSync(index: index,
                                 apiKey: { keyChecks.count += 1; return key },
                                 knownItem: { known[$0] },
                                 fetch: steam.fetch,
                                 throttle: .zero, retryDelay: 600, keyRecheckDelay: 30)
    }

    func testFetchesInBatchesOnlyWhatsMissingAndStoresIt() async {
        let steam = FakeSteam()
        var wallpapers: [WEWallpaper] = []
        for i in 1...120 {
            let id = "\(1000 + i)"
            wallpapers.append(wallpaper(id, tags: i % 2 == 0 ? ["Anime"] : nil))
            steam.catalogue[id] = item(id, tags: ["Wallpaper", "Scene", "Girls"], timeUpdated: i)
        }
        wallpapers.append(wallpaper("2000", tags: ["Anime", "Girls"]))   // enough tags: not read
        wallpapers.append(wallpaper("Local", tags: nil))                   // no Workshop id
        wallpapers.append(wallpaper("1001", tags: nil))                    // the same item twice
        let sync = makeSync(steam)
        sync.update(for: wallpapers)
        await sync.waitUntilIdle()

        XCTAssertEqual(steam.batches.map(\.count), [50, 50, 20], "batches of \(InstalledWorkshopTagSync.batchSize), one after another")
        XCTAssertEqual(Set(steam.batches.joined()), Set((1...120).map { "\(1000 + $0)" }))
        XCTAssertEqual(index.workshopTags(for: "1002"), InstalledWorkshopTags(tags: ["Wallpaper", "Scene", "Girls"], timeUpdated: 2))
        XCTAssertEqual(InstalledWorkshopTags.tags(of: wallpapers[1], in: index), ["Anime", "Scene", "Girls"])

        sync.update(for: wallpapers)
        await sync.waitUntilIdle()
        XCTAssertEqual(steam.batches.count, 3, "read once")
    }

    func testAnItemSteamDoesntReturnIsStoredEmptyAndNotAskedForAgain() async {
        let steam = FakeSteam()
        let sync = makeSync(steam)
        sync.update(for: [wallpaper("42", tags: nil)])
        await sync.waitUntilIdle()
        XCTAssertEqual(index.workshopTags(for: "42"), InstalledWorkshopTags(tags: [], timeUpdated: nil))
        sync.update(for: [wallpaper("42", tags: nil)])
        await sync.waitUntilIdle()
        XCTAssertEqual(steam.batches.count, 1)
    }

    func testNoKeyMeansNoRequestAndNothingStored() async {
        let steam = FakeSteam()
        let checks = Counter()
        let sync = makeSync(steam, key: nil, keyChecks: checks)
        let now = Date()
        sync.update(for: [wallpaper("42", tags: nil)], now: now)
        sync.update(for: [wallpaper("43", tags: nil)], now: now.addingTimeInterval(1))
        await sync.waitUntilIdle()
        XCTAssertTrue(steam.batches.isEmpty)
        XCTAssertNil(index.workshopTags(for: "42"))
        XCTAssertEqual(checks.count, 1, "the keychain isn't read on every redraw")
    }

    func testARefreshAtHandIsStoredWithoutARequest() async {
        let steam = FakeSteam()
        index.setWorkshopTags(["42": InstalledWorkshopTags(tags: ["Anime"], timeUpdated: 1)])
        let sync = makeSync(steam, known: ["42": item("42", tags: ["Anime", "Mature"], timeUpdated: 2)])
        sync.update(for: [wallpaper("42", tags: nil)])
        await sync.waitUntilIdle()
        XCTAssertTrue(steam.batches.isEmpty)
        XCTAssertEqual(index.workshopTags(for: "42"), InstalledWorkshopTags(tags: ["Anime", "Mature"], timeUpdated: 2))
    }

    func testAFailedRequestIsRetriedLaterNotOnEveryRedraw() async {
        let steam = FakeSteam()
        steam.fail = true
        let sync = makeSync(steam)
        let now = Date()
        sync.update(for: [wallpaper("42", tags: nil)], now: now)
        await sync.waitUntilIdle()
        sync.update(for: [wallpaper("42", tags: nil)], now: Date())
        await sync.waitUntilIdle()
        XCTAssertEqual(steam.batches.count, 1)
        XCTAssertNil(index.workshopTags(for: "42"), "offline: nothing stored, the old tags stay")

        steam.fail = false
        steam.catalogue["42"] = item("42", tags: ["Girls"], timeUpdated: 3)
        sync.update(for: [wallpaper("42", tags: nil)], now: Date().addingTimeInterval(601))
        await sync.waitUntilIdle()
        XCTAssertEqual(steam.batches.count, 2)
        XCTAssertEqual(index.workshopTags(for: "42")?.tags, ["Girls"])
    }

    // MARK: Filters

    func testGenreOptionsAreWEsGenreTagsInOrder() {
        XCTAssertEqual(FRTag.optionKeys.count, WorkshopTags.genres.count)
        XCTAssertEqual(InstalledTagFilter.genreTags([.pixelArt, .unspecifiedGenre, .anime]), ["Anime", "Pixel art", "Unspecified"])
    }

    func testFiltersUseTheMergedTags() {
        index.setWorkshopTags(["7": InstalledWorkshopTags(tags: ["Girls", "Mature", "1920 x 1080", "Scene"], timeUpdated: 1)])
        let tags = InstalledWorkshopTags.tags(of: wallpaper("7", tags: ["Anime"]), in: index)

        XCTAssertTrue(InstalledTagFilter.matchesGenres(tags, checked: .all))
        XCTAssertTrue(InstalledTagFilter.matchesGenres(tags, checked: [.girls]), "a genre only Steam lists")
        XCTAssertTrue(InstalledTagFilter.matchesGenres(tags, checked: [.anime, .music]))
        XCTAssertFalse(InstalledTagFilter.matchesGenres(tags, checked: [.music]))
        XCTAssertFalse(InstalledTagFilter.matchesGenres(tags, checked: .none), "None matches nothing, as before")

        XCTAssertTrue(InstalledTagFilter.matchesResolutions(tags, checked: Set(WEResolutionTags.all)))
        XCTAssertTrue(InstalledTagFilter.matchesResolutions(tags, checked: ["1920 x 1080", "3840 x 2160"]))
        XCTAssertFalse(InstalledTagFilter.matchesResolutions(tags, checked: ["3840 x 2160"]))
        XCTAssertEqual(InstalledTagFilter.checked(FRWidescreenResolution([.resolution1920x1080, .resolution1366x768])),
                       ["1920 x 1080", "1366 x 768"])

        XCTAssertEqual(InstalledWorkshopTags.contentRating(in: tags), "Mature", "the rating when project.json has none")
    }
}
