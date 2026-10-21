import XCTest
@testable import OpenWallpaperEngine

/// Dropping files on the Installed tab imports every wallpaper among them and names what wasn't.
final class FolderImportDropTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "FolderImportDrop-\(UUID().uuidString)", directoryHint: .isDirectory)
        for folder in ["dropped/one", "dropped/two", "dropped/empty", "library/two"] {
            try FileManager.default.createDirectory(at: root.appending(path: folder), withIntermediateDirectories: true)
        }
        for wallpaper in ["dropped/one", "dropped/two", "library/two"] {
            try Data(#"{"file": "a.mp4", "title": "T", "type": "video"}"#.utf8)
                .write(to: root.appending(path: "\(wallpaper)/project.json"))
        }
        try Data("notes".utf8).write(to: root.appending(path: "dropped/notes.txt"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root) // Test scratch.
    }

    func testImportsEveryDroppedWallpaperAndReportsTheRest() {
        let dropped = ["one", "two", "empty", "notes.txt", "clip.mov"].map { root.appending(path: "dropped/\($0)") }
        let library = root.appending(path: "library")
        XCTAssertEqual(DroppedFileImport.videos(in: dropped).map(\.lastPathComponent), ["clip.mov"])

        let problems = DroppedFileImport.importWallpapers(dropped, into: library, prepare: { _ in })
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.appending(path: "one/project.json").path))
        XCTAssertEqual(Set(problems.map(\.message)), Set([
            DroppedFileImport.Problem.noWallpaper(name: "empty"),
            .unsupported(name: "notes.txt"),
            .alreadyInLibrary(name: "two"),
        ].map(\.message)))
        XCTAssertNotNil(DroppedFileImport.error(for: problems))
        XCTAssertNil(DroppedFileImport.error(for: []))
    }
}
