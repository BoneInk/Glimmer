import SwiftUI

/// Which name the Installed tab's folder alert asks for.
enum InstalledFolderPrompt: Equatable {
    /// Create Folder, in the folder shown.
    case create
    /// Rename, with the folder's current title.
    case rename(UUID, String)
}

/// The Installed tab's folder alerts: the name for Create Folder and Rename (WE's text input,
/// prefilled with "New Folder", numbered when taken, or the title), and Remove Folder's confirmation.
struct InstalledFolderPrompts: ViewModifier {
    var viewModel: ContentViewModel
    @State private var name = ""

    private var presentation: ContentPresentation { viewModel.presentation }

    private var isNaming: Binding<Bool> {
        Binding(get: { presentation.folderNamePrompt != nil },
                set: { if !$0 { presentation.folderNamePrompt = nil } })
    }

    private var isConfirmingRemoval: Binding<Bool> {
        Binding(get: { presentation.folderRemoval != nil },
                set: { if !$0 { presentation.folderRemoval = nil } })
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: presentation.folderNamePrompt) { _, prompt in
                switch prompt {
                case .create: name = viewModel.library.newFolderTitle
                case .rename(_, let title): name = title
                case nil: break
                }
            }
            .alert(namingTitle, isPresented: isNaming) {
                TextField("Name", text: $name)
                Button("Cancel", role: .cancel) {}
                Button("OK") { commitName() }
            }
            .alert(removalTitle, isPresented: isConfirmingRemoval) {
                Button("Cancel", role: .cancel) {}
                Button("Remove Folder", role: .destructive) {
                    if let folder = presentation.folderRemoval { viewModel.library.removeFolder(folder.id) }
                }
            } message: {
                Text("The wallpapers in it and in its folders go back to Installed. No wallpaper is deleted.",
                     comment: "Message of the Remove Folder confirmation in the Installed tab")
            }
    }

    private var namingTitle: Text {
        if case .rename = presentation.folderNamePrompt {
            return Text("Rename Folder", comment: "Title of the alert that renames a folder in the Installed tab")
        }
        return Text("Create Folder", comment: "Title of the alert that names a new folder in the Installed tab, the Installed tab's button that opens it, and the command in a wallpaper's context menu that makes a folder and moves the wallpaper (or the selection it is in) into it")
    }

    private var removalTitle: Text {
        Text("Remove Folder “\(presentation.folderRemoval?.title ?? "")”?",
             comment: "%@ is the folder's name; title of the Remove Folder confirmation in the Installed tab")
    }

    private func commitName() {
        switch presentation.folderNamePrompt {
        case .create: viewModel.library.createFolder(named: name)
        case .rename(let id, _): viewModel.library.renameFolder(id, to: name)
        case nil: break
        }
    }
}
