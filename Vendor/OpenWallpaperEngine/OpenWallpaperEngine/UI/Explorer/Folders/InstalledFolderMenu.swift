import AppKit
import SwiftUI

/// A folder tile's context menu, WE's: Open, Rename, Change Icon, Change Color, Move to Folder
/// and Remove Folder, with Create Folder for a folder inside the one shown.
struct InstalledFolderMenu: View {
    var viewModel: ContentViewModel
    var folder: InstalledFolder

    private var library: InstalledLibraryModel { viewModel.library }

    var body: some View {
        Group {
            Section {
                Button {
                    library.open(folder: folder.id)
                } label: {
                    Label("Open", systemImage: "folder")
                }
                Button {
                    viewModel.presentation.folderNamePrompt = .rename(folder.id, folder.title)
                } label: {
                    Label("Rename…", systemImage: "pencil")
                }
                iconMenu
                colorMenu
                MoveToFolderMenu(library: library, movingFolder: folder.id) { destination in
                    library.move(folder: folder.id, toFolder: destination)
                }
            }
            Section {
                Button(role: .destructive) {
                    viewModel.presentation.folderRemoval = folder
                } label: {
                    Label {
                        Text("Remove Folder…", comment: "Context menu of a folder in the Installed tab; its wallpapers go back to the top level")
                    } icon: {
                        Image(systemName: "folder.badge.minus")
                    }
                }
            }
        }
        .labelStyle(.titleAndIcon)
    }

    private var iconMenu: some View {
        Menu {
            // WE's grid: its plain folder first (the default), then its 29 icons.
            // Palettes: menus drop items whose label is only an image, so the icons are palette
            // rows instead. A menu lays one palette out in a single row, so the icons are split
            // into rows of `iconsPerRow` that share one selection: a grid.
            ForEach(Array(Self.iconRows.enumerated()), id: \.offset) { _, row in
                Picker(selection: Binding(get: { folder.icon }, set: { library.setIcon($0, ofFolder: folder.id) })) {
                    ForEach(row, id: \.self) { icon in
                        Image(systemName: icon?.systemImage ?? InstalledFolderIcon.defaultSystemImage).tag(icon)
                    }
                } label: {
                    Text("Change Icon", comment: "Context menu of a folder in the Installed tab")
                }
                .pickerStyle(.palette)
                .labelsHidden()
            }
        } label: {
            Label {
                Text("Change Icon", comment: "Context menu of a folder in the Installed tab")
            } icon: {
                Image(systemName: "star.square")
            }
        }
    }

    private var colorMenu: some View {
        Menu {
            Button {
                library.setColor(nil, ofFolder: folder.id)
            } label: {
                Label {
                    Text("Default", comment: "Change Icon / Change Color menu item: the plain folder icon or colour")
                } icon: {
                    Image(systemName: folder.color == nil ? "checkmark" : "circle")
                }
            }
            Divider()
            ForEach(InstalledFolderColor.allCases, id: \.self) { color in
                Button {
                    library.setColor(color, ofFolder: folder.id)
                } label: {
                    Label {
                        Text(color.label)
                    } icon: {
                        // A drawn swatch: menus tint symbol images to one colour, so a coloured
                        // symbol would show grey.
                        Image(nsImage: Self.swatch(color.color, selected: folder.color == color))
                    }
                }
            }
        } label: {
            Label {
                Text("Change Color", comment: "Context menu of a folder in the Installed tab")
            } icon: {
                Image(systemName: "paintpalette")
            }
        }
    }

    /// Icons per palette row in Change Icon.
    private static let iconsPerRow = 5

    /// The icons in rows of `iconsPerRow`.
    private static let iconRows: [[InstalledFolderIcon?]] = {
        let icons = InstalledFolderIcon.pickerOrder
        return stride(from: 0, to: icons.count, by: iconsPerRow).map { Array(icons[$0..<min($0 + iconsPerRow, icons.count)]) }
    }()

    /// A filled circle in `color` (not a template image, so the menu keeps its colour), ringed
    /// when it is the folder's colour.
    private static func swatch(_ color: Color, selected: Bool) -> NSImage {
        let size = NSSize(width: 14, height: 14)
        let image = NSImage(size: size, flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
            NSColor(color).setFill()
            circle.fill()
            if selected {
                NSColor.labelColor.setStroke()
                circle.lineWidth = 1.5
                circle.stroke()
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}
