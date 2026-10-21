import SwiftUI

/// An item in the grid layout, as Photos shows an album: the preview with its title below.
struct PlaylistItemTile: View {
    let item: WallpaperPlaylistItem
    let actions: PlaylistItemActions
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The 16:9 frame comes from a clear view: GifImage is an AppKit view with no height of its
            // own, so sized by itself in a grid cell it collapses to nothing.
            Color.clear
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    GifImage(contentsOf: PlaylistSummary.previewURL(for: item.wallpaper) ?? AppBundleLayout.wallpaperNotFoundURL,
                             animates: false)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .accessibilityHidden(true)
                }
                .clipShape(RoundedRectangle(cornerRadius: ExplorerItem.cornerRadius, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    Button {
                        actions.remove([item.id])
                    } label: {
                        Label("Remove from playlist", systemImage: "minus.circle.fill")
                            .labelStyle(.iconOnly)
                            .font(.title3)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.55))
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                    .help("Remove from playlist")
                    .opacity(isHovered ? 1 : 0)
                    .accessibilityHidden(true)
                }
                .overlay(alignment: .bottomTrailing) {
                    if let duration = actions.durationLabel(item) {
                        Text(verbatim: duration)
                            .font(.caption.monospacedDigit())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(8)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: item.wallpaper.project.displayTitle)
                    .font(.callout)
                    .lineLimit(1)
                Text(verbatim: LocalizedLabels.wallpaperType(item.wallpaper.project.type))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovered = hovering }
        }
        .onTapGesture(count: 2) { actions.setAsWallpaper(item) }
        .contextMenu { PlaylistItemMenu(item: item, actions: actions) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityActions {
            Button("Set as Wallpaper") { actions.setAsWallpaper(item) }
            Button("Move Up") { actions.move(item, by: -1) }
            Button("Move Down") { actions.move(item, by: 1) }
            Button("Remove from playlist") { actions.remove([item.id]) }
        }
    }
}
