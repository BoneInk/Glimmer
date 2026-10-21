import SwiftUI

/// A playlist's cover, as Music draws a playlist's artwork: one preview fills it, two sit side by
/// side, three put the first beside the other two, four make a grid. An empty playlist shows its
/// symbol.
struct PlaylistCover: View {
    let urls: [URL]
    let size: CGFloat
    var cornerRadius: CGFloat = ExplorerItem.cornerRadius

    var body: some View {
        mosaic
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 0.5)
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder private var mosaic: some View {
        let gap: CGFloat = size >= 64 ? 2 : 1
        switch urls.count {
        case 0:
            Rectangle()
                .fill(.quaternary)
                .overlay {
                    Image(systemName: "rectangle.stack")
                        .font(.system(size: size * 0.32, weight: .light))
                        .foregroundStyle(.secondary)
                }
        case 1:
            tile(urls[0])
        case 2:
            HStack(spacing: gap) { tile(urls[0]); tile(urls[1]) }
        case 3:
            HStack(spacing: gap) {
                tile(urls[0])
                VStack(spacing: gap) { tile(urls[1]); tile(urls[2]) }
            }
        default:
            VStack(spacing: gap) {
                HStack(spacing: gap) { tile(urls[0]); tile(urls[1]) }
                HStack(spacing: gap) { tile(urls[2]); tile(urls[3]) }
            }
        }
    }

    private func tile(_ url: URL) -> some View {
        Color.clear
            .overlay {
                GifImage(contentsOf: url, animates: false)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
            .clipped()
    }
}
