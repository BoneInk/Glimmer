import SwiftUI

/// Settings › Assets › Manage Blocklist: the Workshop wallpapers and authors blocked from a
/// Workshop item's context menu (`WorkshopBlockList`), each with Unblock.
struct WorkshopBlockListSection: View {
    @ObservedObject var blockList: WorkshopBlockList

    var body: some View {
        Section {
            if blockList.isEmpty {
                Text("You have not blocked any authors or wallpapers.")
                    .foregroundStyle(.secondary)
            }
            ForEach(blockList.authors) { author in
                row(author, systemImage: "person.crop.circle.badge.xmark") { blockList.unblockAuthor(author.id) }
            }
            ForEach(blockList.items) { item in
                row(item, systemImage: "photo") { blockList.unblockItem(item.id) }
            }
        } header: {
            Label("Manage Blocklist", systemImage: "eye.slash")
        } footer: {
            Text("Blocked wallpapers and authors' wallpapers are hidden from the Workshop and Discover tabs on this Mac. Nothing is sent to Steam.")
        }
    }

    private func row(_ entry: WorkshopBlockList.Entry, systemImage: String, unblock: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: entry.name)
                    .lineLimit(1)
                Text(verbatim: entry.id)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Unblock", action: unblock)
        }
    }
}
