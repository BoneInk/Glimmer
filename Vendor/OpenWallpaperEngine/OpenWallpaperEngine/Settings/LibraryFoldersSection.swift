import AppKit
import SwiftUI

/// Settings › Assets › Library Folders: more folders of wallpapers for the Installed tab
/// (`LibraryFolders`), added and removed here. Changes apply at once.
struct LibraryFoldersSection: View {
    @State private var folders: [URL] = LibraryFolders().folders
    @State private var addError: String?

    var body: some View {
        Section {
            if folders.isEmpty {
                Text("No library folders")
                    .foregroundStyle(.secondary)
            }
            ForEach(folders, id: \.self) { folder in
                row(folder)
            }
            HStack {
                Button("Add Folder…") { addFolders() }
                    .help("Adds a folder of wallpapers to the Installed tab")
                Spacer()
            }
            if let addError {
                Text(addError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Label("Library Folders", systemImage: "folder.badge.plus")
        } footer: {
            Text("The Installed tab also lists the wallpapers in these folders, and follows their changes. Each wallpaper is a folder with a project.json. Downloads and imports still go into the Wallpaper Storage folder.")
        }
    }

    private func row(_ folder: URL) -> some View {
        HStack {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: folder.lastPathComponent)
                Text(verbatim: folder.path(percentEncoded: false))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) {
                    Text("This folder can't be found. Its wallpapers are hidden until it is back.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Spacer()
            Button {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path(percentEncoded: false))
            } label: {
                Label("Show in Finder", systemImage: "magnifyingglass")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")
            Button {
                LibraryFolders().remove(folder)
                changed()
            } label: {
                Label("Remove", systemImage: "minus.circle")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Removes the folder from the library. Its wallpapers stay on disk.")
        }
    }

    private func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = String(localized: "Choose folders of wallpapers to add to the library")
        guard panel.runModal() == .OK else { return }
        addError = nil
        for folder in panel.urls {
            do {
                try LibraryFolders().add(folder)
            } catch {
                addError = "\(folder.lastPathComponent): \(error.localizedDescription)"
            }
        }
        changed()
    }

    private func changed() {
        folders = LibraryFolders().folders
        AppDelegate.shared.libraryFoldersDidChange()
    }
}
