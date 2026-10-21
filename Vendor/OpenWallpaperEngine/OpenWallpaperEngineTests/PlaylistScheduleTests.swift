import XCTest
@testable import OpenWallpaperEngine

/// WE's "Time of day" and "Day of week" playlists: the slots as WE's dialog lays them out, the item
/// for a moment across midnight, daylight saving and time zone changes, and the next change.
final class PlaylistScheduleTests: XCTestCase {
    private func calendar(_ zone: String, firstWeekday: Int = 2) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone) ?? .gmt
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    private func date(_ text: String, _ calendar: Calendar) -> Date {
        let parts = text.split(whereSeparator: { "-: ".contains($0) }).compactMap { Int($0) }
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2],
                                        hour: parts[3], minute: parts[4], second: parts.count > 5 ? parts[5] : 0)
        return calendar.date(from: components) ?? Date()
    }

    // MARK: - Time of day

    func testItemsWithoutEndsShareTheDayEvenly() {
        let slots = PlaylistSchedule.daySlots(ends: [nil, nil, nil, nil])
        XCTAssertEqual(slots.map(\.start), [0, 0.25, 0.5, 0.75])
        XCTAssertEqual(slots.map(\.end), [0.25, 0.5, 0.75, 1])
    }

    func testAnItemWithoutAnEndSharesTheTimeUpToTheNextEnd() {
        // WE's `flex`: items 1 and 2 share 0.2…0.8 evenly; the last runs to midnight.
        let slots = PlaylistSchedule.daySlots(ends: [0.2, nil, 0.8, nil])
        let starts: [Double] = slots.map(\.start)
        let ends: [Double] = slots.map(\.end)
        XCTAssertEqual(starts[1], 0.2, accuracy: 1e-9)
        XCTAssertEqual(starts[2], 0.5, accuracy: 1e-9)
        XCTAssertEqual(ends[2], 0.8, accuracy: 1e-9)
        XCTAssertEqual(ends[3], 1, accuracy: 1e-9)
    }

    func testEndsAreKeptAsWESavesThem() {
        // The last item has no end, and an end before the one above it is dropped.
        XCTAssertEqual(PlaylistSchedule.normalizedDayEnds([0.5, 0.25, 0.75, 0.9]), [0.5, nil, 0.75, nil])
        XCTAssertEqual(PlaylistSchedule.normalizedDayEnds([1.5]), [nil])
    }

    func testTheItemAcrossMidnight() {
        let calendar = calendar("Europe/Berlin")
        let ends: [Double?] = [0.25, 0.75, nil] // 00:00–06:00, 06:00–18:00, 18:00–24:00
        XCTAssertEqual(PlaylistSchedule.dayItem(at: date("2026-06-01 23:59:59", calendar), ends: ends, calendar: calendar), 2)
        XCTAssertEqual(PlaylistSchedule.dayItem(at: date("2026-06-02 00:00:00", calendar), ends: ends, calendar: calendar), 0)
        XCTAssertEqual(PlaylistSchedule.dayItem(at: date("2026-06-02 06:00:00", calendar), ends: ends, calendar: calendar), 1)
        let next = PlaylistSchedule.nextDayBoundary(after: date("2026-06-01 20:00", calendar), ends: ends, calendar: calendar)
        XCTAssertEqual(next, date("2026-06-02 00:00", calendar))
        let morning = PlaylistSchedule.nextDayBoundary(after: date("2026-06-02 00:00", calendar), ends: ends, calendar: calendar)
        XCTAssertEqual(morning, date("2026-06-02 06:00", calendar))
    }

    func testDaylightSavingKeepsWallClockSlots() {
        let calendar = calendar("America/New_York")
        // 2026-03-08: clocks go from 02:00 to 03:00. A slot ending at 02:30 starts the next item
        // at 03:00, the first moment after it that exists.
        let ends: [Double?] = [2.5 / 24, nil]
        let night = date("2026-03-08 01:30", calendar)
        XCTAssertEqual(PlaylistSchedule.dayItem(at: night, ends: ends, calendar: calendar), 0)
        let next = PlaylistSchedule.nextDayBoundary(after: night, ends: ends, calendar: calendar)
        XCTAssertEqual(next, date("2026-03-08 03:00", calendar))
        XCTAssertEqual(next.flatMap { PlaylistSchedule.dayItem(at: $0, ends: ends, calendar: calendar) }, 1)
        // 2026-11-01: clocks go back at 02:00; 08:00 is still 08:00, 8.5 hours after 00:30 EDT.
        let autumnEnds: [Double?] = [8.0 / 24, nil]
        let autumn = date("2026-11-01 00:30", calendar)
        let eight = PlaylistSchedule.nextDayBoundary(after: autumn, ends: autumnEnds, calendar: calendar)
        XCTAssertEqual(eight.map { calendar.component(.hour, from: $0) }, 8)
        XCTAssertEqual(eight.map { $0.timeIntervalSince(autumn) }, 8.5 * 3600)
    }

    func testATimeZoneChangeMovesTheSlot() {
        let berlin = calendar("Europe/Berlin"), tokyo = calendar("Asia/Tokyo")
        let ends: [Double?] = [0.5, nil] // mornings, afternoons
        let instant = date("2026-06-01 10:00", berlin) // 17:00 in Tokyo
        XCTAssertEqual(PlaylistSchedule.dayItem(at: instant, ends: ends, calendar: berlin), 0)
        XCTAssertEqual(PlaylistSchedule.dayItem(at: instant, ends: ends, calendar: tokyo), 1)
    }

    func testOneItemNeverChanges() {
        let calendar = calendar("Europe/Berlin")
        XCTAssertNil(PlaylistSchedule.nextDayBoundary(after: Date(), ends: [nil], calendar: calendar))
        XCTAssertEqual(PlaylistSchedule.dayItem(at: Date(), ends: [nil], calendar: calendar), 0)
        XCTAssertNil(PlaylistSchedule.dayItem(at: Date(), ends: [], calendar: calendar))
    }

    func testDraggedEndsSnapToFiveMinutes() {
        let fraction = (7.0 * 60 + 13) / 1440 // 07:13
        XCTAssertEqual(PlaylistSchedule.snappedDayFraction(fraction, itemCount: 3), (7.0 * 60 + 10) / 1440, accuracy: 1e-9)
        XCTAssertEqual(PlaylistSchedule.snappedDayFraction(fraction, itemCount: 51), fraction, accuracy: 1e-9)
    }

    // MARK: - Day of week

    func testItemsShareTheWeekAsWELabelsThem() {
        XCTAssertEqual(PlaylistSchedule.weekSlots(itemCount: 3), [0..<2, 2..<4, 4..<7])
        XCTAssertEqual(PlaylistSchedule.weekSlots(itemCount: 7), (0..<7).map { $0..<($0 + 1) })
        XCTAssertEqual(PlaylistSchedule.weekSlots(itemCount: 1), [0..<7])
        XCTAssertEqual(PlaylistSchedule.weekSlots(itemCount: 10).count, 7)
        XCTAssertEqual(PlaylistSchedule.weekSlots(itemCount: 0), [])
    }

    func testTheWeekStartsOnTheLocalesFirstDay() {
        let monday = calendar("Europe/Berlin", firstWeekday: 2), sunday = calendar("America/New_York", firstWeekday: 1)
        XCTAssertEqual(PlaylistSchedule.weekOffset(calendar: monday), 0)
        XCTAssertEqual(PlaylistSchedule.weekOffset(calendar: sunday), 6)
        // 2026-06-01 is a Monday, 2026-06-07 a Sunday.
        XCTAssertEqual(PlaylistSchedule.weekItem(at: date("2026-06-01 12:00", monday), itemCount: 7, calendar: monday), 0)
        XCTAssertEqual(PlaylistSchedule.weekItem(at: date("2026-06-07 12:00", monday), itemCount: 7, calendar: monday), 6)
        XCTAssertEqual(PlaylistSchedule.weekItem(at: date("2026-06-07 12:00", sunday), itemCount: 7, calendar: sunday), 0)
        XCTAssertEqual(PlaylistSchedule.weekItem(at: date("2026-06-01 12:00", sunday), itemCount: 7, calendar: sunday), 1)
        // Three items on a Monday week: Mon–Tue, Wed–Thu, Fri–Sun.
        XCTAssertEqual(PlaylistSchedule.weekItem(at: date("2026-06-03 12:00", monday), itemCount: 3, calendar: monday), 1)
        XCTAssertEqual(PlaylistSchedule.weekdays(of: 2, itemCount: 3, calendar: monday), [4, 5, 6])
        // A Sunday week: the first item is Sunday and Monday.
        XCTAssertEqual(PlaylistSchedule.weekdays(of: 0, itemCount: 3, calendar: sunday), [6, 0])
    }

    func testTheWeekLooksAgainAtMidnight() {
        let calendar = calendar("Europe/Berlin")
        let next = PlaylistSchedule.nextWeekBoundary(after: date("2026-06-01 15:00", calendar), itemCount: 3, calendar: calendar)
        XCTAssertEqual(next, date("2026-06-02 00:00", calendar))
        XCTAssertNil(PlaylistSchedule.nextWeekBoundary(after: Date(), itemCount: 1, calendar: calendar))
    }

    func testTheOtherTimingsDontSchedule() {
        let calendar = calendar("Europe/Berlin")
        for timing in [PlaylistTiming.timer, .logon, .never] {
            XCTAssertNil(PlaylistSchedule.item(for: timing, at: Date(), ends: [nil, nil], calendar: calendar))
            XCTAssertNil(PlaylistSchedule.nextBoundary(for: timing, after: Date(), ends: [nil, nil], calendar: calendar))
        }
    }
}
