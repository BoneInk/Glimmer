import XCTest
@testable import OpenWallpaperEngine

/// Importing the Workshop items of an existing Steam install from a synthetic `steamapps` tree:
/// the manifest, the checklist's items, and the copy into the storage folder.
final class SteamLibraryImportTests: XCTestCase {
    private var root: URL!
    private var steamapps: URL!
    private var storage: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "owe-steam-library-\(UUID().uuidString)", directoryHint: .isDirectory)
        steamapps = root.appending(path: "Steam/steamapps", directoryHint: .isDirectory)
        storage = root.appending(path: "Storage", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        // The shape of a real appworkshop_431960.acf (Steam on Windows, WE 2.8): header values,
        // then both item blocks with every field Steam writes; ids and values are made up.
        try write("""
        "AppWorkshop"
        {
        	"appid"		"431960"
        	"SizeOnDisk"		"5000"
        	"NeedsUpdate"		"0"
        	"NeedsDownload"		"0"
        	"TimeLastUpdated"		"1790000000"
        	"TimeLastFullCheck"		"1790000001"
        	"TimeLastAppRan"		"1790000002"
        	"LastBuildID"		"100"
        	"WorkshopItemsInstalled"
        	{
        		"101"
        		{
        			"size"		"1000"
        			"timeupdated"		"1500000000"
        			"manifest"		"9000000000000000000"
        		}
        		"102"
        		{
        			"size"		"1001"
        			"timeupdated"		"1500000001"
        			"manifest"		"9000000000000000001"
        		}
        		"103"
        		{
        			"size"		"1002"
        			"timeupdated"		"1500000002"
        			"manifest"		"9000000000000000002"
        		}
        		"104"
        		{
        			"size"		"1003"
        			"timeupdated"		"1500000003"
        			"manifest"		"9000000000000000003"
        		}
        		"105"
        		{
        			"size"		"1004"
        			"timeupdated"		"1500000004"
        			"manifest"		"9000000000000000004"
        		}
        	}
        	"WorkshopItemDetails"
        	{
        		"101"
        		{
        			"manifest"		"9000000000000000000"
        			"timeupdated"		"1500000000"
        			"timetouched"		"1790000000"
        			"subscribedby"		"76561190000000001"
        			"latest_timeupdated"		"1500000000"
        			"latest_manifest"		"9000000000000000000"
        		}
        		"102"
        		{
        			"manifest"		"9000000000000000001"
        			"timeupdated"		"1500000001"
        			"timetouched"		"1790000000"
        			"subscribedby"		"76561190000000001"
        			"latest_timeupdated"		"1500000001"
        			"latest_manifest"		"9000000000000000001"
        		}
        		"106"
        		{
        			"manifest"		"9000000000000000002"
        			"timeupdated"		"1500000002"
        			"timetouched"		"1790000000"
        			"subscribedby"		"76561190000000001"
        			"latest_timeupdated"		"1500000002"
        			"latest_manifest"		"9000000000000000002"
        		}
        	}
        }
        """, to: "Steam/steamapps/workshop/appworkshop_431960.acf")
        let content = "Steam/steamapps/workshop/content/431960"
        try write(#"{"title":"Lake","file":"scene.json","type":"scene","preview":"preview.jpg","contentrating":"Everyone"}"#,
                  to: "\(content)/101/project.json")
        try write("jpg", to: "\(content)/101/preview.jpg")
        try write("{}", to: "\(content)/101/scene.json")
        try write(#"{"title":"Clip","file":"clip.mp4","type":"video","tags":["Mature"]}"#, to: "\(content)/102/project.json")
        try write(#"{"title":"Game","file":"game.exe","type":"application"}"#, to: "\(content)/103/project.json")
        try write(#"{"title":"Taken","file":"index.html","type":"web"}"#, to: "\(content)/104/project.json")
        try write("not json", to: "\(content)/105/project.json")
        try write(#"{"title":"Loose","file":"scene.json"}"#, to: "\(content)/107/project.json")
        try write("mine", to: "Storage/104/project.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root) // scratch cleanup
    }

    private func write(_ text: String, to path: String) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func testTheManifestListsSubscribedAndInstalledIDs() throws {
        let ids = SteamLibraryImport.manifestIDs(try ValveKeyValues.parse(contentsOf: SteamLibraryImport.manifest(in: steamapps)))
        XCTAssertEqual(ids.subscribed, ["101", "102", "106"])
        XCTAssertEqual(ids.installed, ["101", "102", "103", "104", "105"])
    }

    /// Whatever the user picks inside the install leads to its `steamapps`.
    func testTheLibraryIsFoundFromTheFolderTheUserChose() {
        let expected = steamapps.standardizedFileURL.path
        for chosen in ["Steam", "Steam/steamapps", "Steam/steamapps/workshop", "Steam/steamapps/workshop/content/431960"] {
            XCTAssertEqual(SteamLibraryImport.steamapps(from: root.appending(path: chosen))?.path, expected, chosen)
        }
        XCTAssertNil(SteamLibraryImport.steamapps(from: storage))
    }

    /// Items with a folder on disk, manifest order first, then loose folders; unreadable ones left out.
    func testItemsCarryTitleTypePreviewAndRating() throws {
        let items = try SteamLibraryImport.items(in: steamapps)
        XCTAssertEqual(items.map(\.id), ["101", "102", "103", "104", "107"])
        let lake = try XCTUnwrap(items.first)
        XCTAssertEqual(lake.title, "Lake")
        XCTAssertEqual(lake.type, "scene")
        XCTAssertEqual(lake.contentRating, "Everyone")
        XCTAssertEqual(lake.preview?.lastPathComponent, "preview.jpg")
        XCTAssertTrue(lake.isSubscribed)
        XCTAssertEqual(items[1].contentRating, "Mature", "read from the tags when contentrating is missing")
        XCTAssertFalse(items[2].isImportable)
        XCTAssertFalse(items[4].isSubscribed)
        XCTAssertThrowsError(try SteamLibraryImport.items(in: storage))
    }

    /// Copies, never moves; skips application items and ids the storage folder has.
    func testCopySkipsApplicationsAndExistingItemsAndKeepsTheOriginals() throws {
        let items = try SteamLibraryImport.items(in: steamapps)
        let result = SteamLibraryImport.copy(items, into: storage)
        XCTAssertEqual(result.copied, ["101", "102", "107"])
        XCTAssertEqual(result.existing, ["104"])
        XCTAssertEqual(result.unsupported, ["103"])
        XCTAssertEqual(result.failed, [])
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: storage.appending(path: "101/preview.jpg").path))
        XCTAssertTrue(fm.fileExists(atPath: items[0].folder.appending(path: "project.json").path), "the original stays")
        XCTAssertFalse(fm.fileExists(atPath: storage.appending(path: "103").path))
        XCTAssertEqual(try String(contentsOf: storage.appending(path: "104/project.json"), encoding: .utf8), "mine")
        let leftovers = try fm.contentsOfDirectory(atPath: storage.path).filter { $0.hasPrefix(".owe-import") }
        XCTAssertEqual(leftovers, [])

        let again = SteamLibraryImport.copy(items, into: storage)
        XCTAssertEqual(again.copied, [])
        XCTAssertEqual(again.existing, ["101", "102", "104", "107"])
    }

    /// CrossOver bottles under the given home, with the libraries `libraryfolders.vdf` adds.
    func testCrossOverBottlesAreFound() throws {
        let bottle = "Library/Application Support/CrossOver/Bottles/Steam Bottle/drive_c"
        try write("", to: "\(bottle)/Program Files (x86)/Steam/steamapps/workshop/appworkshop_431960.acf")
        try write("""
        "libraryfolders"
        {
            "0" { "path" "C:\\\\Program Files (x86)\\\\Steam" }
            "1" { "path" "C:\\\\Games\\\\SteamLibrary" }
            "2" { "path" "D:\\\\Elsewhere" }
        }
        """, to: "\(bottle)/Program Files (x86)/Steam/steamapps/libraryfolders.vdf")
        try FileManager.default.createDirectory(at: root.appending(path: "\(bottle)/Games/SteamLibrary/steamapps/workshop/content/431960"),
                                                withIntermediateDirectories: true)
        try write("", to: "Library/Application Support/CrossOver/Bottles/Empty/drive_c/readme.txt")
        let found = SteamLibraryImport.crossOverLibraries(home: root).map { $0.path(percentEncoded: false) }
        XCTAssertEqual(found.count, 2)
        XCTAssertTrue(found[0].hasSuffix("Program Files (x86)/Steam/steamapps/"))
        XCTAssertTrue(found[1].hasSuffix("Games/SteamLibrary/steamapps/"))
        XCTAssertEqual(SteamLibraryImport.crossOverLibraries(home: storage), [])
    }
}
