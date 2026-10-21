import SwiftUI

/// When the stats overlay shows (WE's View › Show Stats: Never, Auto, Always). Auto shows only the
/// numbers past WE's limits.
public enum RenderStatsMode: String, CaseIterable, Sendable {
    case never, auto, always

    public var title: String {
        switch self {
        case .never: return S("Never")
        case .auto: return S("Auto")
        case .always: return S("Always")
        }
    }
}

/// The Wallpaper Editor's stats overlay ("Stats per frame"): every number of the frame, a row
/// past WE's limit in red, in a small translucent table that lets clicks through to the canvas.
public struct RenderStatsOverlay: View {
    private let stats: RenderStats
    private let mode: RenderStatsMode

    public init(stats: RenderStats, mode: RenderStatsMode) {
        self.stats = stats
        self.mode = mode
    }

    public var body: some View {
        let rows = mode == .auto ? stats.rows.filter(\.isWarning) : stats.rows
        if mode != .never, !rows.isEmpty {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 1) {
                ForEach(rows) { row in
                    GridRow {
                        Text(row.title)
                        Text(row.value)
                            .monospacedDigit()
                            .gridColumnAlignment(.trailing)
                    }
                    .foregroundStyle(row.isWarning ? Color.white : Color.primary)
                    .padding(.horizontal, 4)
                    .background(row.isWarning ? Color.red.opacity(0.85) : Color.clear)
                }
            }
            .font(.caption2)
            .padding(4)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(S("Stats per frame"))
        }
    }
}

/// Scene Edit / Export's compact readout: frames per second, GPU time and texture memory, red
/// when one of the frame's numbers is past WE's limit.
public struct RenderStatsBadge: View {
    private let stats: RenderStats

    public init(stats: RenderStats) {
        self.stats = stats
    }

    public var body: some View {
        let warns = stats.rows.contains(where: \.isWarning)
        Text(stats.summary)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(warns ? Color.white : Color.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(warns ? AnyShapeStyle(Color.red.opacity(0.85)) : AnyShapeStyle(.ultraThinMaterial),
                        in: Capsule())
            .help(stats.rows.map { "\($0.title): \($0.value)" }.joined(separator: "\n"))
    }
}

/// The overlay over a feed: it watches the feed while it shows (not in Never), so the renderer
/// counts only then.
public struct RenderStatsFeedOverlay: View {
    @ObservedObject private var feed: RenderStatsFeed
    private let mode: RenderStatsMode

    public init(feed: RenderStatsFeed, mode: RenderStatsMode) {
        self.feed = feed
        self.mode = mode
    }

    public var body: some View {
        // An empty stack still appears, so the feed is watched before its first numbers.
        ZStack(alignment: .topTrailing) {
            Color.clear.frame(width: 0, height: 0)
            if let stats = feed.stats { RenderStatsOverlay(stats: stats, mode: mode) }
        }
        .modifier(RenderStatsWatching(feed: feed, isWatching: mode != .never))
    }
}

/// The compact readout over a feed, watching it while shown.
public struct RenderStatsFeedBadge: View {
    @ObservedObject private var feed: RenderStatsFeed

    public init(feed: RenderStatsFeed) {
        self.feed = feed
    }

    public var body: some View {
        ZStack {
            Color.clear.frame(width: 0, height: 0)
            if let stats = feed.stats { RenderStatsBadge(stats: stats) }
        }
        .modifier(RenderStatsWatching(feed: feed, isWatching: true))
    }
}

/// Watches `feed` while the view is on screen and `isWatching` holds.
struct RenderStatsWatching: ViewModifier {
    let feed: RenderStatsFeed
    let isWatching: Bool
    @State private var watches = false

    func body(content: Content) -> some View {
        content
            .onAppear { set(isWatching) }
            .onDisappear { set(false) }
            .onChange(of: isWatching) { _, watching in set(watching) }
    }

    private func set(_ watching: Bool) {
        guard watching != watches else { return }
        watches = watching
        if watching { feed.watch() } else { feed.unwatch() }
    }
}
