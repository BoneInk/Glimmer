import SwiftUI

/// A folder in the Installed grid, the size of a wallpaper tile: its icon in its colour, its
/// title and how many wallpapers it holds. Clicking opens it; wallpapers and folders dropped on
/// it move into it; it can be dragged into another folder or a breadcrumb.
struct InstalledFolderTile: View {
    var viewModel: ContentViewModel
    var folder: InstalledFolder
    @State private var isTargeted = false
    /// Counts the drops it took, for their feedback.
    @State private var drops = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let count = viewModel.library.wallpaperCount(of: folder)
        ZStack(alignment: .bottom) {
            Rectangle().fill(.quaternary)
            // WE's open variant while something is dragged over it.
            Image(systemName: folder.systemImage(open: isTargeted))
                .resizable()
                .scaledToFit()
                .foregroundStyle(folder.color?.color ?? Color.secondary)
                .padding(viewModel.navigation.explorerIconSize * 0.24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, 24)
            VStack(spacing: 2) {
                Text(verbatim: folder.title)
                    .lineLimit(2)
                    .font(.footnote)
                Text("\(count) wallpapers")
                    .lineLimit(1)
                    .font(.caption2)
                    .opacity(0.75)
            }
            .frame(maxWidth: .infinity, minHeight: 30)
            .padding(4)
            .background(Color(white: 0, opacity: 0.2))
            .multilineTextAlignment(.center)
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: ExplorerItem.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ExplorerItem.cornerRadius, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: isTargeted ? 3 : 0)
        }
        .contentShape(Rectangle())
        .help(folder.title)
        .onTapGesture { viewModel.library.open(folder: folder.id) }
        .modifier(FolderTileDragAndDrop(isEnabled: viewModel.allowsLibraryActions, viewModel: viewModel,
                                        folder: folder, isTargeted: $isTargeted, drops: $drops, reduceMotion: reduceMotion))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// A folder tile drags into another folder and takes the tiles dropped on it, except while the
/// Installed tab picks wallpapers for an export, when it only opens.
private struct FolderTileDragAndDrop: ViewModifier {
    let isEnabled: Bool
    var viewModel: ContentViewModel
    var folder: InstalledFolder
    @Binding var isTargeted: Bool
    @Binding var drops: Int
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .draggable(InstalledDragPayload.folder(folder.id).text)
                .dropDestination(for: String.self) { texts, _ in
                    let moved = withAnimation(InstalledDropAnimation.move(reduceMotion: reduceMotion)) {
                        viewModel.library.drop(texts, into: folder.id)
                    }
                    if moved { drops += 1 }
                    return moved
                } isTargeted: { isTargeted = $0 }
                .dropFeedback(trigger: drops, cornerRadius: ExplorerItem.cornerRadius)
        } else {
            content
        }
    }
}

extension InstalledFolderColor {
    var color: Color {
        let rgb = self.rgb
        return Color(.sRGB, red: Double(rgb.red) / 255, green: Double(rgb.green) / 255, blue: Double(rgb.blue) / 255)
    }
}
