import XCTest
import Metal
@testable import OpenWallpaperEngine

/// Risk #14: a removed script clone's state is freed only after the GPU finished the frames that
/// drew it, and never when a clone came back under the same id.
final class SceneDeferredReleasesTests: XCTestCase {
    func testWaitsForTheLastFrameThenFreesOnlyDeadIds() {
        var releases = SceneDeferredReleases()
        var gpuDone = false
        var freed: [String] = []
        releases.enqueue(["a", "b"]) { gpuDone }
        releases.drain(live: []) { freed.append($0) }
        XCTAssertEqual(freed, [], "the frame that drew them is still on the GPU")
        XCTAssertEqual(releases.count, 1)

        gpuDone = true
        releases.drain(live: ["b"]) { freed.append($0) }
        XCTAssertEqual(freed, ["a"], "b was re-created under the same id and keeps its new state")
        XCTAssertEqual(releases.count, 0)
    }

    func testManyClonesDrainToNothing() {
        var releases = SceneDeferredReleases()
        var freed = Set<String>()
        for batch in 0..<10 {
            releases.enqueue((0..<10).map { "clone\(batch * 10 + $0)" }) { true }
        }
        releases.enqueue([]) { false }
        releases.drain(live: []) { freed.insert($0) }
        XCTAssertEqual(freed.count, 100)
        XCTAssertEqual(releases.count, 0, "an empty removal queues nothing")
    }

    func testCommandBufferGatesTheRelease() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let buffer = try XCTUnwrap(queue.makeCommandBuffer())
        var releases = SceneDeferredReleases()
        var freed: [String] = []
        releases.enqueue(["clone"], after: buffer)
        releases.drain(live: []) { freed.append($0) }
        XCTAssertEqual(freed, [], "not yet committed")
        buffer.commit()
        buffer.waitUntilCompleted()
        releases.drain(live: []) { freed.append($0) }
        XCTAssertEqual(freed, ["clone"])
        releases.enqueue(["first-frame"], after: nil)
        releases.drain(live: []) { freed.append($0) }
        XCTAssertEqual(freed.last, "first-frame", "nothing drawn yet: free at once")
    }
}
