import XCTest
@testable import OpenWallpaperEngine

/// Arrived wallpapers are prepared once, one helper run at a time, as library jobs that wait on
/// the power policy.
final class LibraryPreparationSchedulerTests: XCTestCase {
    private func wallpaper(_ name: String, type: String = "scene") -> WEWallpaper {
        WEWallpaper(using: WEProject(file: "scene.json", preview: "", title: name, type: type),
                    where: URL(filePath: "/tmp/owe-prep-\(name)", directoryHint: .isDirectory))
    }

    func testPreparesScenesOnceAndWaitsForTheGate() {
        let pool = PreparationPool(maxWorkers: 2)
        let gate = Gate()
        pool.setLibraryGate { gate.open }
        let ran = Recorder()
        let scheduler = LibraryPreparationScheduler(pool: pool) { ran.add($0) }
        scheduler.prepare(wallpaper("a"))
        scheduler.prepare(wallpaper("a"))
        scheduler.prepare(wallpaper("v", type: "video"))
        let idle = expectation(description: "idle")
        pool.whenIdle { idle.fulfill() }
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertTrue(ran.batches.isEmpty, "deferred while the power policy says no")
        gate.open = true
        pool.reevaluate()
        wait(for: [idle], timeout: 5)
        scheduler.prepare(wallpaper("b"))
        let done = expectation(description: "b")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { pool.whenIdle { done.fulfill() } }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(ran.batches.map { $0.map(\.lastPathComponent) }, [["owe-prep-a"], ["owe-prep-b"]])
    }

    private final class Gate: @unchecked Sendable {
        private let lock = NSLock(); private var value = false
        var open: Bool { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock(); private var value: [[URL]] = []
        var batches: [[URL]] { lock.withLock { value } }
        func add(_ batch: [URL]) { lock.withLock { value.append(batch) } }
    }
}
