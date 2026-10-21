import OWEInspectorKit
import SwiftUI

/// A Workshop result in the Workshop and Discover tabs: its preview, title and tags, the download
/// control and the item's context menu.
struct WorkshopItemCard: View {
    @Environment(\.appAccentColor) private var accentColor
    let item: WorkshopItem
    @ObservedObject var viewModel: WorkshopViewModel
    /// The list the card is in, for ⇧-click ranges; nil is the Workshop grid's page.
    var selectionOrder: [WorkshopItem]? = nil

    var body: some View {
        ZStack(alignment: .bottom) {
            WorkshopThumbnail(url: item.previewImageURL, loader: viewModel.thumbnails)
                .aspectRatio(1, contentMode: .fit)
                .clipped()

            VStack(spacing: 2) {
                Text(item.title)
                    .lineLimit(2)
                    .font(.footnote)
                if !shownTags.isEmpty {
                    Text(verbatim: shownTags.map { "\u{2068}\($0)\u{2069}" }.joined(separator: " · "))
                        .lineLimit(1)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 30)
            .padding(4)
            .background(Color(white: 0, opacity: 0.65))
            .multilineTextAlignment(.center)
            .foregroundStyle(.white)
        }
        .help(shownTags.isEmpty ? item.title : "\(item.title)\n\(shownTags.formatted(.list(type: .and, width: .narrow)))")
        .overlay(alignment: .topTrailing) {
            downloadControl
                .padding(6)
                .shadow(color: .black.opacity(0.8), radius: 3, x: 0, y: 1)
        }
        .overlay(alignment: .topLeading) {
            if !viewModel.selectedItemIds.isEmpty {
                Button {
                    viewModel.selectItem(item, in: selectionOrder)
                } label: {
                    Label("Select item",
                          systemImage: viewModel.selectedItemIds.contains(item.id) ? "checkmark.circle.fill" : "circle")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(viewModel.selectedItemIds.contains(item.id) ? accentColor : .white)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(viewModel.selectedItemIds.contains(item.id) ? .isSelected : [])
                .padding(6)
                .shadow(color: .black.opacity(0.8), radius: 3, x: 0, y: 1)
                .help("Select item")
            }
        }
        // Rounded like the Installed tiles (`ExplorerItem.cornerRadius`), outlined as before.
        .clipShape(RoundedRectangle(cornerRadius: ExplorerItem.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ExplorerItem.cornerRadius, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: ExplorerItem.cornerRadius, style: .continuous))
        .contextMenu {
            WorkshopItemMenu(item: item, viewModel: viewModel)
        }
        .onTapGesture {
            viewModel.selectItem(item, in: selectionOrder)
        }
        .onTapGesture(count: 2) {
            viewModel.preview(item: item)
        }
    }

    @ViewBuilder
    private var downloadControl: some View {
        if viewModel.isPreviewLoading(item) {
            ProgressView()
                .controlSize(.small)
                .help("Preparing preview")
        } else {
        let state = viewModel.setAs?.downloadState(for: item.id) ?? viewModel.downloadState(for: item)
        switch state {
        case .downloading(let status):
            ProgressView()
                .controlSize(.small)
                .help(status)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .help("Downloaded")
        case .failed(let msg):
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .help(msg)
        case .none:
            if viewModel.steamCmd.isLoggedIn {
                Button {
                    viewModel.download(item: item)
                } label: {
                    Label("Download", systemImage: "arrow.down.circle.fill")
                        .labelStyle(.iconOnly)
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .help("Download")
            } else {
                Image(systemName: "person.badge.key")
                    .foregroundStyle(.secondary)
                    .help("Log in to download")
            }
        }
            }
    }

    /// The item's tags, without "Wallpaper", which every wallpaper has, in the UI's language.
    private var shownTags: [String] {
        item.tags.filter { $0.caseInsensitiveCompare("Wallpaper") != .orderedSame }
            .map { String(localized: LocalizedLabels.filterOption($0)) }
    }

}

/// A Workshop card's preview from `WorkshopThumbnailLoader`, with a placeholder while it loads.
private struct WorkshopThumbnail: View {
    let url: URL?
    let loader: WorkshopThumbnailLoader
    @State private var loaded: (url: URL, image: NSImage?)?

    var body: some View {
        // A cached image draws at once, without a loading frame.
        let image = url.flatMap { url in loaded?.url == url ? loaded?.image : loader.cachedImage(for: url) }
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(1, contentMode: .fill)
            } else if url != nil, loaded?.url != url {
                placeholder.overlay(ProgressView().controlSize(.small))
            } else {
                placeholder
            }
        }
        .task(id: url) {
            guard let url, loader.cachedImage(for: url) == nil else { return }
            let image = await loader.image(for: url)
            guard !Task.isCancelled else { return }
            loaded = (url, image)
        }
    }

    private var placeholder: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .aspectRatio(1, contentMode: .fit)
    }
}
