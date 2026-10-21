import XCTest
@testable import OpenWallpaperEngine

final class InstalledLibraryFileTests: XCTestCase {
    func testAStrayFileIsNotListedButAFolderWithoutProjectIs() throws {
        let library = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: library) }
        try FileManager.default.createDirectory(at: library.appending(path: "broken"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: library.appending(path: "default.profraw"))
        let listed = InstalledLibrary.wallpapers(in: library, hiding: [])
        XCTAssertEqual(listed.map(\.wallpaperDirectory.lastPathComponent), ["broken"])
        XCTAssertEqual(InstalledLibraryCache().wallpapers(in: library, hiding: []).count, 1)
    }
}
