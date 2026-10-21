import XCTest
@testable import OpenWallpaperEngine

/// Choosing a steamcmd by hand makes only steamcmd itself executable.
final class SteamCmdCustomPathTests: XCTestCase {
    private var folder: URL!
    /// The chosen path is stored in the (isolated) app defaults; restored after each test.
    private var storedPath: Any?

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "SteamCmdCustomPath-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        storedPath = UserDefaults.app.object(forKey: SteamCmdLocator.customPathKey)
    }

    override func tearDownWithError() throws {
        UserDefaults.app.set(storedPath, forKey: SteamCmdLocator.customPathKey)
        try? FileManager.default.removeItem(at: folder) // Test scratch.
    }

    @MainActor
    private func choose(_ name: String) throws -> (SteamCmdService, String) {
        let file = folder.appending(path: name)
        try Data("#!/bin/sh\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        let steamCmd = SteamCmdService(account: SteamCmdAccountMemory(load: { nil }, save: { _ in }), restoresSession: false)
        steamCmd.setCustomPath(file.path)
        return (steamCmd, file.path)
    }

    @MainActor
    func testOnlySteamCmdIsMadeExecutable() throws {
        let (steamCmd, path) = try choose("steamcmd.sh")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: path))
        XCTAssertNil(steamCmd.pathError)

        let (other, otherPath) = try choose("notes.txt")
        XCTAssertFalse(FileManager.default.isExecutableFile(atPath: otherPath), "another file keeps its permissions")
        XCTAssertNotNil(other.pathError)
        XCTAssertNotEqual(other.steamCmdPath, otherPath)
    }
}
