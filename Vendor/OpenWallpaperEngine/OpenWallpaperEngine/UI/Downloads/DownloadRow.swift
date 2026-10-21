import OWEInspectorKit
import SwiftUI

/// One download in the Downloads tab: the preview, the title, who made it and its size, then its
/// progress (with speed and time left while steamcmd reports a percentage) or how it ended. Its
/// buttons show on hover; VoiceOver reads them as the row's actions.
struct DownloadRow: View {
    @Environment(\.appAccentColor) private var accentColor
    let workshopId: String
    let kind: DownloadSections.Kind
    @ObservedObject var steamCmd: SteamCmdService
    let canDownload: Bool
    let actions: DownloadActions
    @State private var isHovered = false

    private var item: SteamCmdService.DownloadItem? { steamCmd.downloadItems[workshopId] }

    private var title: String {
        item?.title ?? steamCmd.downloadTitles[workshopId]
            ?? String(localized: "Workshop item \(workshopId)", comment: "Download title before the item's name is known; %@ is its Workshop ID")
    }

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: title)
                    .font(.headline)
                    .lineLimit(1)
                details
                if kind == .inProgress {
                    progress
                }
                status
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            buttons
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovered = hovering }
        }
        .accessibilityElement(children: .combine)
        .accessibilityActions { accessibilityActionButtons }
    }

    private var thumbnail: some View {
        AsyncImage(url: item?.previewURL) { phase in
            if case .success(let image) = phase {
                image.resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.quaternary)
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.tertiary)
                    }
            }
        }
        .frame(width: 96, height: 54)
        .clipShape(RoundedRectangle(cornerRadius: ExplorerItem.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ExplorerItem.cornerRadius, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        }
        .accessibilityHidden(true)
    }

    /// Who made it, its Workshop id and its size.
    private var details: some View {
        HStack(spacing: 8) {
            if let creatorId = item?.creatorId {
                Label {
                    Text(verbatim: SteamPlayerStore.shared.player(for: creatorId)?.personaName ?? creatorId)
                } icon: {
                    Image(systemName: "person")
                }
                .lineLimit(1)
            }
            Text(verbatim: workshopId)
                .monospacedDigit()
                .help("Workshop ID")
            if let subscriptions = item?.subscriptions, subscriptions > 0 {
                Label {
                    Text(subscriptions, format: .number.notation(.compactName))
                } icon: {
                    Image(systemName: "heart")
                }
            }
            if let fileSize = item?.fileSize, fileSize > 0 {
                Text(Int64(fileSize), format: .byteCount(style: .file))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var progress: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 8) {
                ProgressView(value: fraction(at: context.date))
                    .progressViewStyle(.linear)
                    .tint(accentColor)
                if let percentage = steamCmd.downloadPercentages[workshopId], percentage > 0 {
                    Text(percentage, format: .percent.precision(.fractionLength(0)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 40, alignment: .trailing)
                }
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch kind {
        case .inProgress:
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 8) {
                    Text(verbatim: statusText)
                    if let estimate = DownloadRateEstimate(fraction: steamCmd.downloadPercentages[workshopId],
                                                           fileSize: item?.fileSize ?? 0,
                                                           startedAt: steamCmd.downloadStartedAt[workshopId],
                                                           now: context.date) {
                        Text("\(Int64(estimate.bytesPerSecond).formatted(.byteCount(style: .file)))/s",
                             comment: "Download speed; %@ is an amount of data such as 2.4 MB")
                            .monospacedDigit()
                        Text("About \(Self.timeLeft(estimate.remaining)) left",
                             comment: "Download time remaining; %@ is a duration such as 2 min, 5 sec")
                            .monospacedDigit()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        case .queued:
            Label {
                Text(verbatim: SteamCmdService.queuedStatus)
            } icon: {
                Image(systemName: "clock")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .failed:
            Label {
                Text(verbatim: statusText)
                    .lineLimit(2)
                    .textSelection(.enabled)
            } icon: {
                Image(systemName: "exclamationmark.circle.fill")
            }
            .font(.caption)
            .foregroundStyle(.red)
        case .completed:
            Label {
                Text("Downloaded", comment: "Download status")
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    /// Retry stays visible on a failed row; the finished row's buttons show on hover, as Safari's.
    @ViewBuilder private var buttons: some View {
        switch kind {
        case .failed:
            Button {
                actions.retry(workshopId)
            } label: {
                Label("Retry download", systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
            }
            .glassButtonStyle()
            .disabled(!canDownload)
            .help("Retry download")
        case .completed where actions.folder(workshopId) != nil:
            GlassGroup(spacing: 8) {
                HStack(spacing: 8) {
                    Button {
                        actions.setAsWallpaper(workshopId)
                    } label: {
                        Label("Set as Wallpaper", systemImage: "photo.on.rectangle")
                            .labelStyle(.iconOnly)
                    }
                    .help("Set as Wallpaper")
                    Button {
                        actions.showInFinder(workshopId)
                    } label: {
                        Label("Show in Finder", systemImage: "folder")
                            .labelStyle(.iconOnly)
                    }
                    .help("Show in Finder")
                }
                .glassButtonStyle()
            }
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
            .accessibilityHidden(true)
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var accessibilityActionButtons: some View {
        switch kind {
        case .failed where canDownload:
            Button("Retry download") { actions.retry(workshopId) }
        case .completed where actions.folder(workshopId) != nil:
            Button("Set as Wallpaper") { actions.setAsWallpaper(workshopId) }
            Button("Show in Finder") { actions.showInFinder(workshopId) }
        default:
            EmptyView()
        }
    }

    private var statusText: String {
        switch steamCmd.downloadProgress[workshopId] {
        case .downloading(let status)?: return status
        case .failed(let message)?: return message
        case .completed?: return String(localized: "Downloaded", comment: "Download status")
        case nil: return SteamCmdService.queuedStatus
        }
    }

    /// steamcmd's percentage; before it reports one, a slow creep so the bar shows it's working.
    private func fraction(at date: Date) -> Double {
        guard case .downloading(let status)? = steamCmd.downloadProgress[workshopId] else { return 0.05 }
        if status == SteamCmdService.installingStatus { return 0.92 }
        if let percentage = steamCmd.downloadPercentages[workshopId], percentage > 0 { return percentage }
        let startedAt = steamCmd.downloadStartedAt[workshopId] ?? date
        return min(0.88, 0.18 + date.timeIntervalSince(startedAt) / 180 * 0.7)
    }

    private static func timeLeft(_ seconds: TimeInterval) -> String {
        Duration.seconds(Int64(seconds.rounded(.up)))
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
    }
}
