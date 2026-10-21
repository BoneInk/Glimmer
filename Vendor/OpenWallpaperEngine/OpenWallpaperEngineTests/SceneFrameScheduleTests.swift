import XCTest
@testable import OpenWallpaperEngine

/// Which display renders a shared scene's frames (`SceneFrameSchedule`): one render per frame
/// however many displays present it.
final class SceneFrameScheduleTests: XCTestCase {
    private final class Display {}

    func testTheFastestDisplayDrivesAndEqualRatesKeepTheFirst() {
        let a = Display(), b = Display(), c = Display()
        var schedule = SceneFrameSchedule()
        schedule.add(ObjectIdentifier(a), frameRate: 60)
        schedule.add(ObjectIdentifier(b), frameRate: 60)
        XCTAssertEqual(schedule.driver, ObjectIdentifier(a))
        schedule.add(ObjectIdentifier(c), frameRate: 120)
        XCTAssertEqual(schedule.driver, ObjectIdentifier(c))
        schedule.remove(ObjectIdentifier(c))
        XCTAssertEqual(schedule.driver, ObjectIdentifier(a), "the driver's display was removed")
        schedule.setFrameRate(144, of: ObjectIdentifier(b))
        XCTAssertEqual(schedule.driver, ObjectIdentifier(b))
    }

    /// Two displays at 120 and 60 Hz, a second of vsyncs: 120 renders, not 180.
    func testOneRenderPerFrameWhateverTheDisplayCount() {
        let fast = Display(), slow = Display(), third = Display()
        var schedule = SceneFrameSchedule()
        schedule.add(ObjectIdentifier(slow), frameRate: 60)
        schedule.add(ObjectIdentifier(fast), frameRate: 120)
        schedule.add(ObjectIdentifier(third), frameRate: 60)
        var draws: [(time: Double, id: ObjectIdentifier)] = []
        for tick in 0..<120 { draws.append((Double(tick) / 120, ObjectIdentifier(fast))) }
        for tick in 0..<60 {
            draws.append((Double(tick) / 60 + 0.003, ObjectIdentifier(slow)))
            draws.append((Double(tick) / 60 + 0.005, ObjectIdentifier(third)))
        }
        var renders = 0
        for draw in draws.sorted(by: { $0.time < $1.time }) where schedule.shouldRender(draw.id, at: draw.time) {
            renders += 1
            schedule.rendered(at: draw.time)
        }
        XCTAssertEqual(renders, 120)
    }

    /// A driver that stops drawing (its display asleep, its window occluded) hands over after two
    /// of its frame intervals, so the other displays don't freeze.
    func testAnotherDisplayRendersWhenTheDriverStops() {
        let driver = Display(), other = Display()
        var schedule = SceneFrameSchedule()
        schedule.add(ObjectIdentifier(driver), frameRate: 60)
        schedule.add(ObjectIdentifier(other), frameRate: 60)
        schedule.rendered(at: 1)
        XCTAssertFalse(schedule.shouldRender(ObjectIdentifier(other), at: 1.02))
        XCTAssertTrue(schedule.shouldRender(ObjectIdentifier(other), at: 1.04))
        XCTAssertTrue(schedule.shouldRender(ObjectIdentifier(driver), at: 1.001))
    }

    func testTheFirstDrawRenders() {
        let display = Display()
        var schedule = SceneFrameSchedule()
        schedule.add(ObjectIdentifier(display), frameRate: 60)
        XCTAssertTrue(schedule.shouldRender(ObjectIdentifier(Display()), at: 0))
    }
}
