import SwiftUI

/// A "Time of day" playlist's slots: each wallpaper's start, and the time it ends, which is the next
/// one's start (WE's `daytimeend`, snapped to five minutes as WE's timeline drags it). The last
/// runs to midnight; a wallpaper without its own end shares the time evenly with its neighbours.
struct PlaylistTimeOfDayEditor: View {
    @Binding var playlist: WallpaperPlaylist

    /// Times of day are shown and edited as wall-clock times of a fixed day without daylight
    /// saving, so every slot is the time of day it names.
    private static let clockZone = TimeZone(secondsFromGMT: 0) ?? .current
    private static let midnight = Date(timeIntervalSinceReferenceDate: 0)

    var body: some View {
        let slots = PlaylistSchedule.daySlots(ends: playlist.daytimeEnds)
        Section {
            ForEach(Array(playlist.items.enumerated()), id: \.element.id) { index, item in
                LabeledContent {
                    if index < playlist.items.count - 1 {
                        DatePicker("Ends", selection: endBinding(index, slots: slots), displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .environment(\.timeZone, Self.clockZone)
                    } else {
                        Text(Self.time(1))
                            .foregroundStyle(.secondary)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: item.wallpaper.project.displayTitle)
                            .lineLimit(1)
                        Text("From \(Self.time(slots[safe: index]?.start ?? 0))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Time of day")
        }
    }

    /// Item `index`'s end as a time; setting it keeps it after its start and before the next end.
    private func endBinding(_ index: Int, slots: [PlaylistSchedule.Slot]) -> Binding<Date> {
        Binding {
            Self.midnight.addingTimeInterval(Double(PlaylistSchedule.secondsOfDay(slots[safe: index]?.end ?? 1)))
        } set: { date in
            let seconds = date.timeIntervalSince(Self.midnight).truncatingRemainder(dividingBy: 86_400)
            let fraction = PlaylistSchedule.snappedDayFraction((seconds < 0 ? seconds + 86_400 : seconds) / 86_400,
                                                               itemCount: playlist.items.count)
            let lower = slots[safe: index]?.start ?? 0
            let upper = playlist.items[(index + 1)...].lazy.compactMap(\.daytimeEnd).first ?? 1
            playlist.items[index].daytimeEnd = min(max(fraction, lower), upper)
        }
    }

    /// A fraction of the day as the locale writes a time (1 is midnight).
    static func time(_ fraction: Double) -> String {
        let seconds = fraction >= 1 ? 0 : PlaylistSchedule.secondsOfDay(fraction)
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.timeZone = clockZone
        return midnight.addingTimeInterval(Double(seconds)).formatted(style)
    }
}
