import XCTest
@testable import OpenWallpaperEngine

/// Import › From Folder's work, which the MCP Server plugin's import_wallpaper shares.
final class FolderImportTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "FolderImport-\(UUID().uuidString)", directoryHint: .isDirectory)
        for folder in ["chosen/one", "chosen/two", "chosen/notes", "library/two"] {
            try FileManager.default.createDirectory(at: root.appending(path: folder), withIntermediateDirectories: true)
        }
        for wallpaper in ["chosen/one", "chosen/two", "library/two"] {
            try Data(#"{"file": "a.mp4", "title": "T", "type": "video"}"#.utf8)
                .write(to: root.appending(path: "\(wallpaper)/project.json"))
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root) // Test scratch.
    }

    func testFindsWallpapersAndSkipsWhatTheLibraryHas() {
        let chosen = root.appending(path: "chosen")
        let sources = FolderImport.sources(in: [chosen])
        XCTAssertEqual(Set(sources.folders.map(\.lastPathComponent)), ["one", "two"], "a folder of wallpapers counts as its wallpapers")
        XCTAssertEqual(FolderImport.sources(in: [chosen.appending(path: "one")]).folders.map(\.lastPathComponent), ["one"])
        XCTAssertTrue(FolderImport.sources(in: [chosen.appending(path: "notes")]).isEmpty)

        let library = root.appending(path: "library")
        let outcome = FolderImport.importWallpapers(sources, into: library, prepare: { _ in })
        XCTAssertEqual(outcome.imported.map(\.lastPathComponent), ["one"])
        XCTAssertEqual(outcome.skipped.map(\.reason), [.alreadyInLibrary])
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.appending(path: "one/project.json").path))
    }
}
