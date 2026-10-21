import SwiftUI
import AppKit

/// The checklist of an import: the rating filter, Select All / None, and one row per item with
/// its preview. Items the rating filter leaves out aren't listed, so their previews never load.
struct ImportChecklistView: View {
    @ObservedObject var checklist: ImportChecklist

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("Content Rating")
                    .font(.callout.weight(.semibold))
                ForEach(WorkshopTags.ratings, id: \.self) { rating in
                    Toggle(isOn: ratingBinding(rating)) {
                        Text(LocalizedLabels.filterOption(rating))
                    }
                    .toggleStyle(.checkbox)
                }
                Spacer()
                Button("Select All") { checklist.selectAll() }
                Button("Select None") { checklist.selectNone() }
            }
            .controlSize(.small)

            List(checklist.visible) { candidate in
                ImportChecklistRow(candidate: candidate,
                                   isSelectable: checklist.isSelectable(candidate),
                                   isSelected: Binding(
                                    get: { checklist.selected.contains(candidate.id) },
                                    set: { _ in checklist.toggle(candidate) }))
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(minHeight: 180)

            if checklist.hiddenCount > 0 {
                Text("Items with other content ratings are hidden: \(checklist.hiddenCount)",
                     comment: "%lld is a number of Workshop items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func ratingBinding(_ rating: String) -> Binding<Bool> {
        Binding(
            get: { checklist.ratings.contains(rating) },
            set: { isOn in
                if isOn {
                    checklist.ratings.insert(rating)
                } else if checklist.ratings.count > 1 {
                    checklist.ratings.remove(rating)
                }
            })
    }
}

private struct ImportChecklistRow: View {
    let candidate: WorkshopImportCandidate
    let isSelectable: Bool
    @Binding var isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: $isSelected)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(!isSelectable)
            preview
                .frame(width: 64, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: candidate.title)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let type = candidate.type {
                        Text(verbatim: LocalizedLabels.wallpaperType(type))
                    }
                    if let rating = candidate.contentRating {
                        Text(LocalizedLabels.filterOption(rating))
                    }
                    if candidate.isApplication {
                        Text("Application wallpapers don't run on macOS; skipped.")
                    } else if candidate.isInLibrary {
                        Text("Already in your library")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .opacity(isSelectable ? 1 : 0.6)
    }

    @ViewBuilder
    private var preview: some View {
        if let file = candidate.previewFile, let image = NSImage(contentsOf: file) {
            Image(nsImage: image).resizable().scaledToFill()
        } else if let url = candidate.previewURL {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.secondary.opacity(0.15)
            }
        } else {
            Color.secondary.opacity(0.15)
        }
    }
}
