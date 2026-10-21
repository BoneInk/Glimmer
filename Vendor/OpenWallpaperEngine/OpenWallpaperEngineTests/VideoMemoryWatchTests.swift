import Metal
import XCTest
@testable import OpenWallpaperEngine

/// "Pause when VRAM is exhausted": `VideoMemoryGauge`'s thresholds and hysteresis, and
/// `VideoMemoryWatch` pausing and resuming every display through `DisplayPlaybackMonitor`.
@MainActor
final class VideoMemoryWatchTests: XCTestCase {
    private typealias Sample = VideoMemoryGauge.Sample
    private let gb: UInt64 = 1 << 30

    // MARK: Gauge

    func testFullBudgetExhaustsAndEightyFivePercentClears() {
        var gauge = VideoMemoryGauge()
        XCTAssertFalse(gauge.update(Sample(allocated: 9 * gb / 10, budget: gb), now: 0))
        XCTAssertTrue(gauge.update(Sample(allocated: gb, budget: gb), now: 1))
        XCTAssertTrue(gauge.exhausted)
        // Below the budget but above 85%: still exhausted (hysteresis).
        XCTAssertFalse(gauge.update(Sample(allocated: 9 * gb / 10, budget: gb), now: 10))
        XCTAssertTrue(gauge.exhausted)
        XCTAssertTrue(gauge.update(Sample(allocated: 8 * gb / 10, budget: gb), now: 11))
        XCTAssertFalse(gauge.exhausted)
    }

    func testAStateIsHeldForTheMinimumTime() {
        var gauge = VideoMemoryGauge()
        gauge.update(Sample(allocated: gb, budget: gb), now: 100)
        XCTAssertFalse(gauge.update(Sample(allocated: 0, budget: gb), now: 102))
        XCTAssertTrue(gauge.exhausted)
        XCTAssertTrue(gauge.update(Sample(allocated: 0, budget: gb), now: 100 + VideoMemoryGauge.minimumHold))
        // Recovered just now: a new spike waits out the hold too.
        XCTAssertFalse(gauge.update(Sample(allocated: gb, budget: gb), now: 106))
        XCTAssertTrue(gauge.update(Sample(allocated: gb, budget: gb), now: 110))
    }

    func testPressureAndOutOfMemoryErrorsExhaustAndHoldIt() {
        var gauge = VideoMemoryGauge()
        XCTAssertTrue(gauge.update(Sample(allocated: 0, budget: gb, criticalPressure: true), now: 0))
        XCTAssertFalse(gauge.update(Sample(allocated: 0, budget: gb, criticalPressure: true), now: 10))
        XCTAssertTrue(gauge.update(Sample(allocated: 0, budget: gb), now: 11))
        XCTAssertTrue(gauge.update(Sample(allocated: 0, budget: gb, outOfMemoryError: true), now: 20))
    }

    func testNoBudgetNeverExhausts() {
        var gauge = VideoMemoryGauge()
        XCTAssertFalse(gauge.update(Sample(allocated: gb, budget: 0), now: 0))
    }

    func testOutOfMemoryCommandBufferErrorsAreRecognized() {
        XCTAssertTrue(VideoMemoryWatch.isOutOfMemory(MTLCommandBufferError(.outOfMemory)))
        XCTAssertFalse(VideoMemoryWatch.isOutOfMemory(MTLCommandBufferError(.timeout)))
        XCTAssertFalse(VideoMemoryWatch.isOutOfMemory(nil))
    }

    // MARK: Watch through the playback monitor

    private final class FakeGPU {
        var allocated: UInt64 = 0
        var budget: UInt64 = 1 << 30
        var unified = true
        var clock: TimeInterval = 0
    }

    private var gpu = FakeGPU()
    private var applied: [[String: DisplayPlayback]] = []
    private var monitor: DisplayPlaybackMonitor!
    private var watch: VideoMemoryWatch!

    override func setUp() {
        super.setUp()
        gpu = FakeGPU()
        applied = []
        let display = DesktopDisplay(id: "1", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                     visibleFrame: CGRect(x: 0, y: 25, width: 1920, height: 1055))
        let sources = DisplayPlaybackSources(windows: { [] }, displays: { [display] }, frontmostPID: { nil }, ownPID: 1,
                                             otherApplicationPlayingAudio: { _ in false }, onBattery: { false })
        monitor = DisplayPlaybackMonitor(sources: sources, scanQueue: nil) { [weak self] in self?.applied.append($0) }
        let gpu = gpu
        let device = VideoMemoryWatch.Device(allocated: { gpu.allocated }, budget: { gpu.budget },
                                             hasUnifiedMemory: gpu.unified)
        watch = VideoMemoryWatch(device: device, schedules: false, now: { gpu.clock }) { [weak self] in
            self?.monitor.setVideoMemoryExhausted($0)
        }
        monitor.evaluate()
    }

    override func tearDown() {
        watch.setEnabled(false)
        monitor.stop()
        super.tearDown()
    }

    func testExhaustionPausesAndRecoveryResumes() {
        watch.setEnabled(true)
        gpu.clock = 10
        gpu.allocated = gpu.budget
        watch.sample()
        XCTAssertEqual(applied.last, ["1": .pause])
        gpu.allocated = gpu.budget / 2
        gpu.clock = 12
        watch.sample()
        XCTAssertEqual(applied.last, ["1": .pause], "held for the minimum time")
        gpu.clock = 16
        watch.sample()
        XCTAssertEqual(applied.last, ["1": .run])
    }

    func testSettingOffChangesNothing() {
        gpu.allocated = gpu.budget * 2
        watch.sample()
        watch.setCriticalPressure(true)
        watch.noteOutOfMemory()
        XCTAssertEqual(applied, [["1": .run]])
    }

    func testTurningTheSettingOffResumes() {
        watch.setEnabled(true)
        gpu.allocated = gpu.budget
        watch.sample()
        XCTAssertEqual(applied.last, ["1": .pause])
        watch.setEnabled(false)
        XCTAssertEqual(applied.last, ["1": .run])
    }

    func testManualResumeLiftsThePauseAndHoldsIt() {
        watch.setEnabled(true)
        gpu.allocated = gpu.budget
        watch.sample()
        gpu.clock = 1
        watch.userResumed()
        XCTAssertEqual(applied.last, ["1": .run])
        gpu.clock = 3
        watch.sample()
        XCTAssertEqual(applied.last, ["1": .run], "no pause within the hold after a manual resume")
        gpu.clock = 7
        watch.sample()
        XCTAssertEqual(applied.last, ["1": .pause])
    }

    func testCriticalPressureCountsOnlyWithUnifiedMemory() {
        watch.setEnabled(true)
        watch.setCriticalPressure(true)
        XCTAssertEqual(applied.last, ["1": .pause])

        var reported: [Bool] = []
        let discrete = VideoMemoryWatch(device: .init(allocated: { 0 }, budget: { 1 << 30 }, hasUnifiedMemory: false),
                                        schedules: false, now: { 0 }) { reported.append($0) }
        discrete.setEnabled(true)
        discrete.setCriticalPressure(true)
        XCTAssertEqual(reported, [])
    }

    func testAnOutOfMemoryCommandBufferPauses() {
        watch.setEnabled(true)
        watch.noteOutOfMemory()
        XCTAssertEqual(applied.last, ["1": .pause])
    }

    func testRulesPauseEveryDisplayWhenVideoMemoryIsExhausted() {
        let result = PlaybackRules(focused: .mute).playback(
            displays: ["1", "2"], conditions: ["1": DisplayConditions(focused: true)],
            system: SystemPlaybackConditions(videoMemoryExhausted: true))
        XCTAssertEqual(result, ["1": .pause, "2": .pause])
    }
}
