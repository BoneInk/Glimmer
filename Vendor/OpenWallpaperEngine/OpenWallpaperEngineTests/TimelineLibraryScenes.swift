import XCTest
@testable import OpenWallpaperEngine

/// The library's scenes that animate (docs/timeline-plan.md T6): every scene item with a property
/// timeline (`Timeline/library-expected.json`) or an animated `.tex` (`Library/texs-frames.json`),
/// found in the library roots (`TimelineLibrarySweepTests.roots`). Empty when the library is
/// absent (CI). `OWE_TIMELINE_ITEMS` (ids separated by ',') keeps only those items.
enum TimelineLibraryScenes {
    struct Item {
        var id: String
        var directory: URL
        var project: WEProject
    }

    static func items() throws -> [Item] {
        var ids = Set<String>()
        let expected = try TimelineOracle.load(Fixtures.url("Timeline/library-expected.json"))
        for group in expected[oracle: "groups"]?.oracleArray ?? [] {
            if let item = group[oracle: "item"]?.oracleString { ids.insert(item) }
        }
        struct Texture: Decodable { let item: String }
        for texture in try JSONDecoder().decode([Texture].self, from: Fixtures.data("Library/texs-frames.json")) {
            ids.insert(texture.item)
        }
        if let only = ProcessInfo.processInfo.environment["OWE_TIMELINE_ITEMS"] {
            ids.formIntersection(only.split(separator: ",").map(String.init))
        }
        var items: [Item] = []
        for id in ids.sorted() {
            for root in TimelineLibrarySweepTests.roots {
                let directory = root.appending(path: id, directoryHint: .isDirectory)
                let file = directory.appending(path: "project.json")
                guard FileManager.default.fileExists(atPath: file.path) else { continue }
                // Optional: asset packs have no `type` and are drawn by the scenes that use them.
                if let project = try? JSONDecoder().decode(WEProject.self, from: Data(contentsOf: file)),
                   project.type.lowercased() == "scene" {
                    items.append(Item(id: id, directory: directory, project: project))
                }
                break
            }
        }
        return items
    }

    /// The item's content as the app builds it (`SceneContentLoader`, the real loader).
    static func content(of item: Item) throws -> SceneMetalContent {
        let model = SceneContentLoader(wallpaper: WEWallpaper(using: item.project, where: item.directory))
        return try XCTUnwrap(model.metalContent(), "\(item.id): no content")
    }
}
