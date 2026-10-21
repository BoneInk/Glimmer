import SwiftUI

/// A "Day of week" playlist's days: the first seven wallpapers share the week from its first day,
/// as WE labels them; any after the seventh don't play.
struct PlaylistDayOfWeekList: View {
    let playlist: WallpaperPlaylist

    var body: some View {
        let calendar = Calendar.autoupdatingCurrent
        Section {
            ForEach(Array(playlist.items.prefix(PlaylistTiming.maxDayOfWeekItems).enumerated()), id: \.element.id) { index, item in
                LabeledContent {
                    Text(verbatim: Self.days(of: index, itemCount: playlist.items.count, calendar: calendar))
                        .foregroundStyle(.secondary)
                } label: {
                    Text(verbatim: item.wallpaper.project.displayTitle).lineLimit(1)
                }
            }
            if playlist.items.count > PlaylistTiming.maxDayOfWeekItems {
                Label("The Day of Week playlist does not support more than 7 wallpapers.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Day of week")
        }
    }

    /// The days item `index` shows on, "Monday" or "Monday – Wednesday", in the calendar's names.
    static func days(of index: Int, itemCount: Int, calendar: Calendar) -> String {
        let days = PlaylistSchedule.weekdays(of: index, itemCount: itemCount, calendar: calendar)
        guard let firstDay = days.first, let lastDay = days.last else { return "" }
        // Calendar's names start on Sunday; WE counts from Monday.
        let names = calendar.standaloneWeekdaySymbols
        let first = names[(firstDay + 1) % 7], last = names[(lastDay + 1) % 7]
        return days.count == 1 ? first : "\(first) – \(last)"
    }
}
