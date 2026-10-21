import XCTest
@testable import OpenWallpaperEngine

/// The Downloads tab's groups, its speed and time-left estimate, and the service's Clear
/// Completed.
final class DownloadSectionsTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    func testGroupsByState() {
        let sections = DownloadSections(
            progress: ["run": .downloading(status: "Downloading…"), "q1": .downloading(status: "Queued"),
                       "q2": .downloading(status: "Queued"), "bad": .failed("ERROR! Download item failed"),
                       "ok": .completed],
            activeId: "run", queuedIds: ["run", "q2", "q1"], startedAt: [:])
        XCTAssertEqual(sections.inProgress, ["run"])
        XCTAssertEqual(sections.queued, ["q2", "q1"], "the queue keeps steamcmd's order")
        XCTAssertEqual(sections.failed, ["bad"])
        XCTAssertEqual(sections.completed, ["ok"])
        XCTAssertFalse(sections.isEmpty)
    }

    func testFinishedOnesAreNewestFirstThenById() {
        let sections = DownloadSections(
            progress: ["old": .completed, "new": .completed, "b": .completed, "a": .completed],
            activeId: nil, queuedIds: [],
            startedAt: ["old": now, "new": now.addingTimeInterval(60)])
        XCTAssertEqual(sections.completed, ["new", "old", "a", "b"])
    }

    func testARetriedDownloadLeavesTheFailedGroup() {
        let sections = DownloadSections(progress: ["x": .downloading(status: "Queued")], activeId: nil,
                                        queuedIds: ["x"], startedAt: [:])
        XCTAssertEqual(sections.queued, ["x"])
        XCTAssertEqual(sections.failed, [])
    }

    func testNothingTrackedIsEmpty() {
        XCTAssertTrue(DownloadSections(progress: [:], activeId: nil, queuedIds: [], startedAt: [:]).isEmpty)
    }

    func testRateEstimate() throws {
        let estimate = try XCTUnwrap(DownloadRateEstimate(fraction: 0.25, fileSize: 100_000_000,
                                                          startedAt: now.addingTimeInterval(-10), now: now))
        XCTAssertEqual(estimate.bytesPerSecond, 2_500_000, accuracy: 0.5)
        XCTAssertEqual(estimate.remaining, 30, accuracy: 0.001)
    }

    func testNoEstimateWithoutEnoughToGoOn() {
        let started = now.addingTimeInterval(-10)
        XCTAssertNil(DownloadRateEstimate(fraction: nil, fileSize: 100, startedAt: started, now: now))
        XCTAssertNil(DownloadRateEstimate(fraction: 0.5, fileSize: 0, startedAt: started, now: now), "size unknown")
        XCTAssertNil(DownloadRateEstimate(fraction: 0.001, fileSize: 100, startedAt: started, now: now), "no progress yet")
        XCTAssertNil(DownloadRateEstimate(fraction: 1, fileSize: 100, startedAt: started, now: now), "finished")
        XCTAssertNil(DownloadRateEstimate(fraction: 0.5, fileSize: 100, startedAt: now.addingTimeInterval(-1), now: now))
        XCTAssertNil(DownloadRateEstimate(fraction: 0.5, fileSize: 100, startedAt: nil, now: now))
    }

    func testClearCompletedKeepsTheOthers() {
        let service = SteamCmdService(account: SteamCmdAccountMemory(load: { nil }, save: { _ in }), restoresSession: false)
        service.downloadProgress = ["ok": .completed, "bad": .failed("no"), "run": .downloading(status: "…")]
        service.downloadFolders = ["ok": URL(fileURLWithPath: "/tmp/ok")]
        service.clearCompletedDownloads()
        XCTAssertEqual(Set(service.downloadProgress.keys), ["bad", "run"])
        XCTAssertNil(service.downloadFolders["ok"])
    }

    func testRetryNeedsAFailedDownload() {
        let service = SteamCmdService(account: SteamCmdAccountMemory(load: { nil }, save: { _ in }), restoresSession: false)
        service.downloadProgress = ["ok": .completed]
        service.retryDownload("ok")
        XCTAssertEqual(service.downloadProgress["ok"], .completed)
        XCTAssertEqual(service.queuedDownloadIds, [])
    }
}
