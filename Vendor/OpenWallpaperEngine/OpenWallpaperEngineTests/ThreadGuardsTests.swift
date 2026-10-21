import XCTest
@testable import OpenWallpaperEngine

final class ThreadGuardsTests: XCTestCase {
    func testGuardsFireOnTheMainAndRenderThreads() {
        XCTAssertTrue(Thread.isMainThread)
        let hits = expectThreadGuardViolations {
            ThreadGuards.assertNotMainThread("heavy on main")
            ThreadGuards.assertRenderThread("frame work off the render thread")
            ThreadGuards.renderFrame {
                ThreadGuards.assertRenderThread("frame work")        // fine
                ThreadGuards.assertNotRenderThread("heavy in frame")
            }
            let off = expectation(description: "background")
            DispatchQueue.global().async {
                ThreadGuards.assertBackground("heavy in background") // fine
                off.fulfill()
            }
            wait(for: [off], timeout: 5)
        }
        XCTAssertEqual(hits.map(\.kind), [.onMainThread, .offRenderThread, .onRenderThread])
    }

    func testTEXDecodeOnTheMainThreadIsReported() {
        let hits = expectThreadGuardViolations {
            _ = TEXParser(data: Data("TEXV0005".utf8)).extractImage()
        }
        XCTAssertEqual(hits.map(\.what), ["TEXParser.extractContainerImage"])
    }

    /// Each violation carries its call site, thread, time and the caller's frames, not the guard's.
    func testViolationIsAttributedToItsCaller() throws {
        let before = Date()
        let line: UInt = #line + 1
        let hits = expectThreadGuardViolations { ThreadGuards.assertNotMainThread("Attribution.probe") }
        let hit = try XCTUnwrap(hits.first)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hit.kind, .onMainThread)
        XCTAssertEqual(hit.what, "Attribution.probe")
        XCTAssertEqual(hit.file, "OpenWallpaperEngineTests/ThreadGuardsTests.swift")
        XCTAssertEqual(hit.line, line)
        XCTAssertEqual(hit.thread, "main")
        XCTAssertGreaterThanOrEqual(hit.timestamp, before)
        XCTAssertFalse(hit.stack.isEmpty)
        XCTAssertLessThanOrEqual(hit.stack.count, ThreadGuards.stackDepth)
        XCTAssertFalse(hit.stack[0].contains(ThreadGuards.ownSymbol), hit.stack[0])
    }

    func testBackgroundThreadIsNamed() throws {
        let thread = Thread {
            ThreadGuards.renderFrame { ThreadGuards.assertNotRenderThread("named") }
        }
        thread.name = "owe.test.render"
        let hits = expectThreadGuardViolations {
            let done = expectation(description: "thread")
            let watcher = Thread { while !thread.isFinished { usleep(1000) }; done.fulfill() }
            thread.start()
            watcher.start()
            wait(for: [done], timeout: 5)
        }
        XCTAssertEqual(hits.map(\.thread), ["owe.test.render"])
    }

    func testViolationsAreRecordedPerCallSite() {
        let sitesBefore = ThreadGuards.store.sites
        _ = expectThreadGuardViolations {
            for _ in 0..<3 { ThreadGuards.assertNotMainThread("PerSite.probe") }
        }
        let site = ThreadGuards.store.sites.first { $0.first.what == "PerSite.probe" }
        XCTAssertEqual(site?.count, 3 + (sitesBefore.first { $0.first.what == "PerSite.probe" }?.count ?? 0))
    }

    func testMessageFormat() {
        let violation = ThreadGuards.Violation(
            kind: .onMainThread, what: "TEXParser.decode", file: "OpenWallpaperEngine/TEXParser.swift", line: 42,
            thread: "main", stack: ["0 a", "1 b", "2 c"], timestamp: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(violation.summary, "TEXParser.decode ran on the main thread")
        XCTAssertEqual(violation.message(frames: 2), """
            TEXParser.decode ran on the main thread (OpenWallpaperEngine/TEXParser.swift:42, thread main)
                0 a
                1 b
            """)
        let off = ThreadGuards.Violation(kind: .offRenderThread, what: "draw", file: "f", line: 1, thread: "t",
                                         stack: [], timestamp: Date())
        XCTAssertEqual(off.summary, "draw ran off the render thread")
        let issue = ThreadGuardTestObserver.issue(for: violation)
        XCTAssertEqual(issue.compactDescription, "Thread guard: TEXParser.decode ran on the main thread")
        XCTAssertEqual(issue.detailedDescription, violation.message())
    }
}
