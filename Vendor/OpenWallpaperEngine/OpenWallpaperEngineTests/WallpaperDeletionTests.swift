import XCTest
@testable import OpenWallpaperEngine

/// Deleting wallpapers reports the ones that couldn't be deleted, and the Details panel finds a
/// scene's sounds; both off the main thread.
final class WallpaperDeletionTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "owe-deletion-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    private func makeWallpaper(_ name: String, files: [String: Data] = ["project.json": Data("{}".utf8)]) throws -> URL {
        let directory = folder.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (file, data) in files { try data.write(to: directory.appending(path: file)) }
        return directory
    }

    func testDeletingReportsTheWallpapersThatCouldNotBeDeleted() async throws {
        let present = try makeWallpaper("present")
        let missing = folder.appending(path: "missing", directoryHint: .isDirectory)
        let result: (deleted: [URL], failure: WallpaperDeletion.Failure?) = await Task.detached {
            WallpaperDeletion.delete([present, missing], toTrash: false)
        }.value
        XCTAssertEqual(result.deleted, [present])
        XCTAssertFalse(FileManager.default.fileExists(atPath: present.path))
        let failure = try XCTUnwrap(result.failure)
        XCTAssertEqual(failure.reasons.count, 1)
        XCTAssertFalse(failure.errorDescription?.isEmpty ?? true)
    }

    func testDeletingEveryWallpaperHasNoFailure() async throws {
        let first = try makeWallpaper("first")
        let second = try makeWallpaper("second")
        let result: (deleted: [URL], failure: WallpaperDeletion.Failure?) = await Task.detached {
            WallpaperDeletion.delete([first, second], toTrash: false)
        }.value
        XCTAssertEqual(result.deleted, [first, second])
        XCTAssertNil(result.failure)
    }

    func testSceneSoundsAreFoundLooseOrInThePackage() async throws {
        let silent = try makeWallpaper("silent", files: [
            "scene.pkg": MDLParseTests.package(["scene.json": Data("{}".utf8)]),
        ])
        let loose = try makeWallpaper("loose", files: ["sounds.ogg": Data()])
        let packaged = try makeWallpaper("packaged", files: [
            "scene.pkg": MDLParseTests.package(["scene.json": Data("{}".utf8), "sounds/music.MP3": Data()]),
        ])
        let found: [Bool] = await Task.detached {
            [silent, loose, packaged].map { SceneAudioPresence.hasAudio(in: $0) }
        }.value
        XCTAssertEqual(found, [false, true, true])
    }
}
