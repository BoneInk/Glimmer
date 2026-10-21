import SwiftUI

/// The image a wallpaper drag from the Installed grid shows: the tile's picture, or for several
/// wallpapers up to three of their pictures stacked and offset, with how many there are in a
/// badge, as Finder and Photos show a drag of several items.
struct InstalledDragPreview: View {
    /// The pictures, the dragged tile's first; at most `maxShown` are drawn.
    var pictures: [URL]
    /// How many wallpapers the drag moves.
    var count: Int
    /// A tile's side.
    var size: CGFloat

    static let maxShown = 3

    private var shown: [URL] { Array(pictures.prefix(Self.maxShown)) }
    private var step: CGFloat { (size * 0.07).rounded() }

    var body: some View {
        let spread = step * CGFloat(max(shown.count - 1, 0))
        ZStack(alignment: .bottomLeading) {
            // The dragged tile in front, the others behind it, up and to the right.
            ForEach(Array(shown.enumerated()).reversed(), id: \.offset) { index, url in
                picture(url)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: ExplorerItem.cornerRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: ExplorerItem.cornerRadius, style: .continuous)
                            .strokeBorder(.white.opacity(0.5), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                    .offset(x: step * CGFloat(index), y: -step * CGFloat(index))
            }
        }
        .frame(width: size + spread, height: size + spread, alignment: .bottomLeading)
        .overlay(alignment: .topTrailing) {
            if count > 1 {
                Text(count, format: .number)
                    .font(.callout.bold())
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.red))
                    .offset(x: 6, y: -6)
            }
        }
        .padding(8)
    }

    @ViewBuilder private func picture(_ url: URL) -> some View {
        if let still = GifImage.still(at: url) {
            Image(decorative: still, scale: 1).resizable().scaledToFill()
        } else {
            Rectangle().fill(.quaternary)
        }
    }
}

extension InstalledDragPreview {
    /// The preview of a drag from `wallpaper`'s tile: what `wallpapersActedOn` moves, its own
    /// picture first.
    init(library: InstalledLibraryModel, wallpaper: WEWallpaper, size: CGFloat) {
        let moved = library.wallpapersActedOn(from: wallpaper)
        let others = moved.filter { $0.wallpaperDirectory != wallpaper.wallpaperDirectory }
        let previews = ([wallpaper] + others.prefix(Self.maxShown - 1)).map { $0.previewURL ?? AppBundleLayout.wallpaperNotFoundURL }
        self.init(pictures: previews, count: max(moved.count, 1), size: size)
    }
}

/// `InstalledDragPreview` for a tile's drag, worked out only when the drag starts: SwiftUI makes
/// a drag's preview view with every redraw of the tile, but draws it only for a drag.
struct InstalledTileDragPreview: View {
    var library: InstalledLibraryModel
    var wallpaper: WEWallpaper
    var size: CGFloat

    var body: some View {
        InstalledDragPreview(library: library, wallpaper: wallpaper, size: size)
    }
}
