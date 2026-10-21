import XCTest
@testable import OpenWallpaperEngine

/// Report and Open in Workshop open the item's page (the user reports it there themselves), and
/// Related Wallpapers lists an item's presets through QueryFiles.
@MainActor
final class WorkshopPageLinkTests: XCTestCase {
    func testOpensTheSteamClientWhenItIsInstalled() {
        XCTAssertEqual(WorkshopPageLink.url(for: "3100000001", steamClientInstalled: true),
                       URL(string: "steam://url/CommunityFilePage/3100000001"))
    }

    func testOpensTheWebPageOtherwise() {
        XCTAssertEqual(WorkshopPageLink.url(for: "3100000001", steamClientInstalled: false),
                       URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=3100000001"))
    }

    func testOpensNothingForSomethingThatIsntAWorkshopId() {
        XCTAssertNil(WorkshopPageLink.url(for: "My Scene", steamClientInstalled: true))
        XCTAssertNil(WorkshopPageLink.url(for: "1&action=report", steamClientInstalled: false))
    }

    func testBrowsePresetsAsksForTheItemsThatRequireTheBase() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "owe-page-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) } // cleanup of a temp folder; nothing to report
        let steamCmd = SteamCmdService(dependencyIndex: WorkshopDependencyIndex(libraryDirectory: { root }),
                                       storageDirectory: { root }, previewCacheRoot: root,
                                       presentPreview: { _ in }, restoresSession: false)
        let model = WorkshopViewModel(steamCmd: steamCmd, searchPage: { _, _, _, _, _ in [] })
        let items = try WorkshopAPIService.parseItems(from: Data(contentsOf: Fixtures.url("Workshop/api/query-files.json")))

        let scene = try XCTUnwrap(items.first { $0.id == "3100000001" })
        XCTAssertEqual(model.presetBase(for: scene), WorkshopPresetBase(id: "3100000001", title: "Aurora Lake"))
        let preset = try XCTUnwrap(items.first { $0.id == "3100000002" })
        XCTAssertEqual(model.presetBase(for: preset)?.id, "3100000001", "a preset browses its base's presets")
        let video = try XCTUnwrap(items.first { $0.id == "3100000003" })
        XCTAssertNil(model.presetBase(for: video), "WE offers presets for scenes and web wallpapers")

        model.showPresets(of: WorkshopPresetBase(id: "3100000001", title: "Aurora Lake"))
        let query = model.browseQuery
        XCTAssertEqual(query.childOf, "3100000001")
        XCTAssertTrue(query.excludedTags.contains("Wallpaper"))
        let request = WorkshopAPIService.queryItems(text: "", filter: query, sortOrder: .default, page: 1, perPage: 50)
        XCTAssertTrue(request.contains(URLQueryItem(name: "child_publishedfileid", value: "3100000001")))
        model.clearPresetFilter()
        XCTAssertNil(model.browseQuery.childOf)
    }
}
