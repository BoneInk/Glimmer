import Foundation

/// Which item a scheduled playlist shows, and when that changes next: WE's "Time of day" and
/// "Day of week" playlists, as its playlist dialog lays them out.
///
/// - Time of day: an item ends at its `daytimeend`, a fraction of the day; its slot starts where
///   the previous item's ends (the first at midnight) and the last runs to midnight. Items without
///   an end share the time up to the next end evenly (WE's `flex`). Times are wall-clock times,
///   so 08:00 is 08:00 on the days the clocks change too.
/// - Day of week: up to seven items share the week from its first day, each `floor(left / items
///   left)` days and the last the rest, as WE labels them; the week starts on the locale's first
///   weekday (WE's `dayofweekoffset`).
enum PlaylistSchedule {
    /// A slot of the day, as fractions of it.
    struct Slot: Equatable {
        var start: Double
        var end: Double
    }

    /// WE's slot snapping while dragging, for playlists of up to 50 items: five minutes.
    static let snapMinutes = 5
    static let snapItemLimit = 50

    // MARK: - Time of day

    /// Each item's slot of the day, from its stored end (`nil`: shares the time evenly).
    static func daySlots(ends: [Double?]) -> [Slot] {
        let ends = normalizedDayEnds(ends)
        var slots = [Slot](repeating: Slot(start: 0, end: 1), count: ends.count)
        var groupStart = 0
        var groupFrom = 0.0
        for index in ends.indices {
            let end: Double? = ends[index] ?? (index == ends.count - 1 ? 1 : nil)
            guard let end else { continue }
            let count = index - groupStart + 1
            let width = (end - groupFrom) / Double(count)
            for member in groupStart...index {
                let start = groupFrom + width * Double(member - groupStart)
                slots[member] = Slot(start: start, end: member == index ? end : start + width)
            }
            groupStart = index + 1
            groupFrom = end
        }
        return slots
    }

    /// The ends WE keeps (`selectPlaylist`): the last item has none, and an end before the one
    /// above it is dropped; ends are within the day.
    static func normalizedDayEnds(_ ends: [Double?]) -> [Double?] {
        var result = ends.map { $0.map { min(max($0, 0), 1) } }
        guard !result.isEmpty else { return result }
        result[result.count - 1] = nil
        var previous = 0.0
        for index in result.indices {
            guard let end = result[index] else { continue }
            if end < previous { result[index] = nil } else { previous = end }
        }
        return result
    }

    /// The fraction of the day `date` is at, by the wall clock of `calendar`'s time zone.
    static func dayFraction(of date: Date, calendar: Calendar) -> Double {
        let parts = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        let hours: Int = parts.hour ?? 0
        let minutes: Int = parts.minute ?? 0
        let wholeSeconds: Int = parts.second ?? 0
        let nanoseconds: Int = parts.nanosecond ?? 0
        let clock: Int = hours * 3600 + minutes * 60 + wholeSeconds
        let seconds = Double(clock) + Double(nanoseconds) / 1_000_000_000
        return min(max(seconds / 86_400, 0), 1)
    }

    /// The item whose slot `date` is in; nil without items.
    static func dayItem(at date: Date, ends: [Double?], calendar: Calendar) -> Int? {
        let slots = daySlots(ends: ends)
        guard !slots.isEmpty else { return nil }
        let fraction = dayFraction(of: date, calendar: calendar)
        return slots.firstIndex { fraction >= $0.start && fraction < $0.end } ?? slots.count - 1
    }

    /// The next time after `date` a slot starts (midnight included); nil with fewer than two items.
    static func nextDayBoundary(after date: Date, ends: [Double?], calendar: Calendar) -> Date? {
        let slots = daySlots(ends: ends)
        guard slots.count > 1 else { return nil }
        let boundaries = Set(slots.map { secondsOfDay($0.start) })
        return boundaries.compactMap { seconds -> Date? in
            let parts = DateComponents(hour: seconds / 3600, minute: seconds / 60 % 60, second: seconds % 60)
            // A time the clocks skip (the hour lost to daylight saving) starts at the next moment that exists.
            return calendar.nextDate(after: date, matching: parts, matchingPolicy: .nextTime)
        }.min()
    }

    /// A fraction of the day as whole seconds, at most 23:59:59.
    static func secondsOfDay(_ fraction: Double) -> Int {
        min(Int((fraction * 86_400).rounded()), 86_399)
    }

    /// `fraction` snapped as WE's dialog snaps a dragged boundary: down to five minutes, for
    /// playlists of up to 50 items.
    static func snappedDayFraction(_ fraction: Double, itemCount: Int) -> Double {
        let clamped = min(max(fraction, 0), 1)
        guard itemCount <= snapItemLimit else { return clamped }
        let step = Double(snapMinutes)
        return (clamped * 1440 / step).rounded(.down) * step / 1440
    }

    // MARK: - Day of week

    /// WE's offset of the week's first day from Monday (0 Monday … 6 Sunday), from `calendar`'s
    /// first weekday.
    static func weekOffset(calendar: Calendar) -> Int {
        (calendar.firstWeekday + 5) % 7
    }

    /// The days of the week (0 = the week's first day) each of the first seven items covers.
    static func weekSlots(itemCount: Int) -> [Range<Int>] {
        let count = min(PlaylistTiming.maxDayOfWeekItems, itemCount)
        var left = 7
        var slots: [Range<Int>] = []
        for index in 0..<max(count, 0) {
            let start = 7 - left
            let days = index < count - 1 ? left / (count - index) : left
            left -= days
            slots.append(start..<(start + days))
        }
        return slots
    }

    /// The days item `item` shows on, in order, as Monday-based weekdays (0 Monday … 6 Sunday).
    static func weekdays(of item: Int, itemCount: Int, calendar: Calendar) -> [Int] {
        let slots = weekSlots(itemCount: itemCount)
        guard slots.indices.contains(item) else { return [] }
        let offset = weekOffset(calendar: calendar)
        return slots[item].map { ($0 + offset) % 7 }
    }

    /// The item for `date`'s day; nil without items.
    static func weekItem(at date: Date, itemCount: Int, calendar: Calendar) -> Int? {
        let slots = weekSlots(itemCount: itemCount)
        guard !slots.isEmpty else { return nil }
        // Calendar weekdays are 1 Sunday … 7 Saturday; WE counts from Monday.
        let monday = (calendar.component(.weekday, from: date) + 5) % 7
        let day = (monday - weekOffset(calendar: calendar) + 7) % 7
        return slots.firstIndex { $0.contains(day) } ?? slots.count - 1
    }

    /// The next midnight after `date`, when a day-of-week playlist looks again; nil with fewer than
    /// two items.
    static func nextWeekBoundary(after date: Date, itemCount: Int, calendar: Calendar) -> Date? {
        guard min(PlaylistTiming.maxDayOfWeekItems, itemCount) > 1 else { return nil }
        return calendar.nextDate(after: date, matching: DateComponents(hour: 0, minute: 0, second: 0),
                                 matchingPolicy: .nextTime)
    }

    // MARK: - Either

    /// The item `timing` schedules at `date`; nil when the timing doesn't schedule or nothing plays.
    static func item(for timing: PlaylistTiming, at date: Date, ends: [Double?], calendar: Calendar) -> Int? {
        switch timing {
        case .daytime: return dayItem(at: date, ends: ends, calendar: calendar)
        case .dayofweek: return weekItem(at: date, itemCount: ends.count, calendar: calendar)
        case .logon, .timer, .never: return nil
        }
    }

    /// When `timing`'s item changes next after `date`; nil when it doesn't schedule.
    static func nextBoundary(for timing: PlaylistTiming, after date: Date, ends: [Double?], calendar: Calendar) -> Date? {
        switch timing {
        case .daytime: return nextDayBoundary(after: date, ends: ends, calendar: calendar)
        case .dayofweek: return nextWeekBoundary(after: date, itemCount: ends.count, calendar: calendar)
        case .logon, .timer, .never: return nil
        }
    }
}
