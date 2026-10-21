import XCTest
@testable import OpenWallpaperEngine

/// A wallpaper's size counts the allocated size of its regular files.
final class InstalledWallpaperSizeTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "WallpaperSize-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root.appending(path: "sub"), withIntermediateDirectories: true)
        try Data(count: 10_000).write(to: root.appending(path: "a.bin"))
        try Data(count: 50_000).write(to: root.appending(path: "sub/b.bin"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root) // Test scratch.
    }

    private func allocated(_ path: String) throws -> Int {
        try XCTUnwrap(root.appending(path: path).resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize)
    }

    func testCountsRegularFilesOnly() throws {
        let top = try allocated("a.bin")
        let nested = try allocated("sub/b.bin")
        XCTAssertEqual(try root.directoryTotalAllocatedSize(includingSubfolders: true), top + nested)
        XCTAssertEqual(try root.directoryTotalAllocatedSize(includingSubfolders: false), top,
                       "without subfolders only the top level's files count, not the folder itself")
        XCTAssertNil(try root.appending(path: "a.bin").directoryTotalAllocatedSize())
    }
}
