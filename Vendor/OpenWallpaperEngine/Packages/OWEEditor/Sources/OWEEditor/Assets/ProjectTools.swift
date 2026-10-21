import SwiftUI
import OWESceneEditing

/// The asset browser's project menu, WE's File menu items for the project's files: New Material,
/// Clean Project and Clean Local Storage.
struct ProjectToolsMenu: View {
    let services: WallpaperEditorServices
    let tools: EditorTools
    @Binding var isNamingMaterial: Bool
    @Binding var isCleaning: Bool

    var body: some View {
        Menu {
            Button(L("New Material…")) { isNamingMaterial = true }
                .disabled(services.assetStore == nil)
            Divider()
            Button(L("Clean Project…")) { isCleaning = true }
                .disabled(services.assetStore == nil)
            if let storage = services.localStorage {
                Button(L("Clean Local Storage")) {
                    do { try storage.clean() } catch {
                        tools.problem = L("The local storage couldn’t be cleaned: \(error.localizedDescription)")
                    }
                }
                .disabled(!storage.hasData())
            }
        } label: {
            Label(L("Project"), systemImage: "ellipsis.circle")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("New Material, Clean Project and Clean Local Storage"))
    }
}

/// WE's Clean Project: the editor's files nothing uses, listed to be checked, then moved to the
/// Trash, from where they can be put back.
struct CleanProjectSheet: View {
    @ObservedObject var session: SceneEditSession
    let services: WallpaperEditorServices
    let tools: EditorTools
    @Environment(\.dismiss) private var dismiss
    @State private var unused: [EditorAssetStore.Asset]?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Clean Project")).font(.headline)
            if let unused {
                if unused.isEmpty {
                    Text(L("No unused files found.")).foregroundStyle(.secondary)
                } else {
                    Text(L("The following assets appear to be unused by your project and may be deleted to reduce disk space. Please double check the list of files to be deleted below before continuing."))
                        .fixedSize(horizontal: false, vertical: true)
                    List(unused) { asset in
                        Text(asset.path).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                    }
                    .frame(minHeight: 160)
                    Text(L("The files will be moved to the Trash and can be put back from there if necessary."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
            HStack {
                Spacer()
                Button(L("Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L("Delete Files"), role: .destructive) { trash() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(unused?.isEmpty ?? true)
            }
        }
        .padding(16)
        .frame(minWidth: 480, idealWidth: 540, minHeight: 200)
        .task { find() }
    }

    private func find() {
        guard let store = services.assetStore else { unused = []; return }
        var roots = services.projectReferences()
        do {
            roots.append(try session.overlay.encoded())
        } catch {
            // Without the draft nothing can be called unused.
            tools.problem = L("The project’s files couldn’t be checked: \(error.localizedDescription)")
            unused = []
            return
        }
        unused = ProjectCleaner.unusedAssets(in: store, roots: roots)
    }

    private func trash() {
        defer { dismiss() }
        do {
            _ = try ProjectCleaner.trash(unused ?? [])
        } catch {
            tools.problem = L("Some files couldn’t be moved to the Trash: \(error.localizedDescription)")
        }
    }
}
