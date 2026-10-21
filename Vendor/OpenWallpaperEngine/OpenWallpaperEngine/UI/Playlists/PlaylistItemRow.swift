import SwiftUI

/// An item in the list layout: the preview, the title and type, how long it shows, and a Remove
/// button on hover.
struct PlaylistItemRow: View {
    let item: WallpaperPlaylistItem
    let actions: PlaylistItemActions
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            GifImage(contentsOf: PlaylistSummary.previewURL(for: item.wallpaper) ?? AppBundleLayout.wallpaperNotFoundURL,
                     animates: false)
                .resizable()
                .aspectRatio(16 / 9, contentMode: .fill)
                .frame(width: 80, height: 45)
                .clipShape(RoundedRectangle(cornerRadius: ExplorerItem.cornerRadius, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: item.wallpaper.project.displayTitle)
                    .lineLimit(1)
                Text(verbatim: LocalizedLabels.wallpaperType(item.wallpaper.project.type))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let duration = actions.durationLabel(item) {
                Text(verbatim: duration)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Button {
                actions.remove([item.id])
            } label: {
                Label("Remove from playlist", systemImage: "minus.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Remove from playlist")
            .opacity(isHovered ? 1 : 0)
            .accessibilityHidden(true)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovered = hovering }
        }
        .accessibilityElement(children: .combine)
        .accessibilityActions {
            Button("Set as Wallpaper") { actions.setAsWallpaper(item) }
            Button("Move Up") { actions.move(item, by: -1) }
            Button("Move Down") { actions.move(item, by: 1) }
            Button("Remove from playlist") { actions.remove([item.id]) }
        }
    }
}
