import Foundation

/// Puts the app's default time zone at the offset that makes now read a capture's wall-clock time,
/// so what reads the local clock through Foundation (`engine.timeOfDay`, `g_Daytime`, a day-and-night
/// cycle) sees the time WE's capture was taken at. Only the time of day is kept (the offset stays
/// within ±12 h). JavaScriptCore's `Date` keeps the host's zone, so script clocks show the real time
/// and are masked. Returns what puts the zone back.
enum WEReferenceLocalTime {
    static func set(_ time: String) -> () -> Void {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return {} }
        let wanted = parts[0] * 3600 + parts[1] * 60 + (parts.count > 2 ? parts[2] : 0)
        let now = Int(Date().timeIntervalSince1970)
        var offset = (wanted - now % 86400) % 86400
        if offset > 43200 { offset -= 86400 }
        if offset <= -43200 { offset += 86400 }
        let before = NSTimeZone.default
        guard let zone = TimeZone(secondsFromGMT: offset) else { return {} }
        NSTimeZone.default = zone
        return { NSTimeZone.default = before }
    }
}
