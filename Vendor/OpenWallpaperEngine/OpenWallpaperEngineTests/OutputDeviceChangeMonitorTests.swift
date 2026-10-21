import CoreAudio
import XCTest
@testable import OpenWallpaperEngine

final class OutputDeviceChangeMonitorTests: XCTestCase {
    private final class FakeDeviceSource: OutputDeviceSource {
        var device: AudioObjectID = 10
        var onChange: (() -> Void)?

        func currentDeviceID() -> AudioObjectID { device }
        func startObserving(_ onChange: @escaping () -> Void) { self.onChange = onChange }
        func stopObserving() { onChange = nil }

        func switchTo(_ id: AudioObjectID) {
            device = id
            onChange?()
        }
    }

    /// Runs scheduled work only when `advance` reaches it.
    private final class ManualClock {
        var now: TimeInterval = 0
        var pending: [(TimeInterval, () -> Void)] = []

        func schedule(_ delay: TimeInterval, _ work: @escaping () -> Void) {
            pending.append((now + delay, work))
        }

        /// Runs due work in time order, at its own time, so work it schedules lands inside the
        /// same advance when due.
        func advance(by seconds: TimeInterval) {
            let end = now + seconds
            while let next = pending.enumerated().filter({ $0.element.0 <= end }).min(by: { $0.element.0 < $1.element.0 }) {
                pending.remove(at: next.offset)
                now = max(now, next.element.0)
                next.element.1()
            }
            now = end
        }
    }

    private var source: FakeDeviceSource!
    private var clock: ManualClock!
    private var reloadEnabled = true
    private var captureRestarts = 0
    private var reloads = 0

    private func makeMonitor() -> OutputDeviceChangeMonitor {
        source = FakeDeviceSource()
        clock = ManualClock()
        let monitor = OutputDeviceChangeMonitor(
            source: source, debounce: 0.5,
            schedule: { [unowned self] in self.clock.schedule($0, $1) },
            reloadEnabled: { [unowned self] in self.reloadEnabled },
            restartCapture: { [unowned self] in self.captureRestarts += 1 },
            reloadWallpapers: { [unowned self] in self.reloads += 1 })
        monitor.start()
        return monitor
    }

    func testBurstOfChangesActsOnce() {
        let monitor = makeMonitor()
        source.switchTo(11)
        clock.advance(by: 0.2)
        source.switchTo(12)
        clock.advance(by: 0.2)
        source.switchTo(13)
        clock.advance(by: 0.4)
        XCTAssertEqual(reloads, 0, "still inside the debounce window")
        clock.advance(by: 0.6)
        XCTAssertEqual(reloads, 1)
        XCTAssertEqual(captureRestarts, 1)
        withExtendedLifetime(monitor) {}
    }

    func testSameDeviceIsNoOp() {
        let monitor = makeMonitor()
        source.switchTo(10)
        clock.advance(by: 1)
        XCTAssertEqual(reloads, 0)
        XCTAssertEqual(captureRestarts, 0)

        // Away and back within one burst settles on the same device.
        source.switchTo(20)
        source.switchTo(10)
        clock.advance(by: 1)
        XCTAssertEqual(reloads, 0)
        XCTAssertEqual(captureRestarts, 0)
        withExtendedLifetime(monitor) {}
    }

    func testSettingOnReloadsAndRestartsCapture() {
        reloadEnabled = true
        let monitor = makeMonitor()
        source.switchTo(11)
        clock.advance(by: 1)
        XCTAssertEqual(reloads, 1)
        XCTAssertEqual(captureRestarts, 1)
        withExtendedLifetime(monitor) {}
    }

    func testSettingOffOnlyRestartsCapture() {
        reloadEnabled = false
        let monitor = makeMonitor()
        source.switchTo(11)
        clock.advance(by: 1)
        XCTAssertEqual(reloads, 0)
        XCTAssertEqual(captureRestarts, 1)
        withExtendedLifetime(monitor) {}
    }

    func testStopIgnoresPendingChange() {
        let monitor = makeMonitor()
        source.switchTo(11)
        clock.advance(by: 0)
        monitor.stop()
        clock.advance(by: 1)
        XCTAssertEqual(reloads, 0)
        XCTAssertEqual(captureRestarts, 0)
    }
}
