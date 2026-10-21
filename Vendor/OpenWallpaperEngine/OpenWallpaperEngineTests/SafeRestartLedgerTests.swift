import XCTest
@testable import OpenWallpaperEngine

final class SafeRestartLedgerTests: XCTestCase {
    private func wallpaper(_ name: String) -> WEWallpaper {
        WEWallpaper(using: WEProject(file: "scene.json", preview: "preview.jpg", title: name, type: "scene"),
                    where: URL(fileURLWithPath: "/tmp/owe-safe-restart/\(name)"))
    }

    func testCleanExitLeavesNothingToSkip() {
        var ledger = SafeRestartLedger()
        ledger.sessionChanged(to: ["1": wallpaper("a")])
        ledger.cleanExit()
        XCTAssertNil(ledger.activeSession)
        XCTAssertTrue(ledger.beginLaunch().isEmpty)
    }

    func testUncleanExitNamesEveryScreenOfTheShowingWallpapers() {
        var ledger = SafeRestartLedger()
        ledger.sessionChanged(to: ["2": wallpaper("a"), "1": wallpaper("a"), "3": wallpaper("b")])
        let suspects = ledger.beginLaunch()
        XCTAssertEqual(suspects.map(\.wallpaper.project.title), ["a", "b"])
        XCTAssertEqual(suspects[0].screenIds, ["1", "2"])
        XCTAssertEqual(suspects[1].screenIds, ["3"])
        XCTAssertFalse(suspects.contains(where: \.isFlagged))
        XCTAssertNil(ledger.activeSession, "the sentinel is consumed at launch")
        XCTAssertTrue(ledger.beginLaunch().isEmpty)
    }

    func testSwitchingWallpaperMovesTheSentinel() {
        var ledger = SafeRestartLedger()
        ledger.sessionChanged(to: ["1": wallpaper("a")])
        ledger.sessionChanged(to: ["1": wallpaper("b")])
        XCTAssertEqual(ledger.beginLaunch().map(\.wallpaper.project.title), ["b"])
        XCTAssertFalse(ledger.isFlagged(wallpaper("a")))
    }

    func testNoWallpaperClearsTheSentinel() {
        var ledger = SafeRestartLedger()
        ledger.sessionChanged(to: ["1": wallpaper("a")])
        ledger.sessionChanged(to: [:])
        XCTAssertTrue(ledger.beginLaunch().isEmpty)
    }

    func testTwoUncleanExitsInARowFlag() {
        var ledger = SafeRestartLedger()
        ledger.sessionChanged(to: ["1": wallpaper("a")])
        XCTAssertFalse(ledger.beginLaunch()[0].isFlagged)
        ledger.sessionChanged(to: ["1": wallpaper("a")])
        XCTAssertTrue(ledger.beginLaunch()[0].isFlagged)
        XCTAssertTrue(ledger.isFlagged(wallpaper("a")))
        XCTAssertEqual(ledger.flaggedKeys, [SafeRestartLedger.key(for: wallpaper("a"))])
    }

    func testCleanExitBreaksTheRun() {
        var ledger = SafeRestartLedger()
        ledger.sessionChanged(to: ["1": wallpaper("a")])
        _ = ledger.beginLaunch()
        ledger.sessionChanged(to: ["1": wallpaper("a")])
        ledger.cleanExit()
        _ = ledger.beginLaunch()
        ledger.sessionChanged(to: ["1": wallpaper("a")])
        XCTAssertFalse(ledger.beginLaunch()[0].isFlagged)
    }

    func testStorePersistsTheLedger() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "owe-safe-restart-\(UUID().uuidString)/SafeRestart.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) } // Test cleanup.
        let store = SafeRestartStore(fileURL: url)
        var ledger = store.load()
        ledger.sessionChanged(to: ["1": wallpaper("a")])
        store.save(ledger)
        var reloaded = store.load()
        XCTAssertEqual(reloaded.beginLaunch().map(\.wallpaper.project.title), ["a"])
    }
}
