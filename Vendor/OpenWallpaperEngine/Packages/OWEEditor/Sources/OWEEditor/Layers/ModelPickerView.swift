import SwiftUI
import OWESceneEditing

/// Add Layer › Model: the 3D models the scene can draw (`.mdl`), the wallpaper's own, the ones
/// imported in the editor and WE's, searchable; choosing one adds a model layer drawing it.
/// Import FBX or OBJ… imports a model file as WE's Add Asset › Model does and adds it.
struct ModelPickerView: View {
    let models: [EditorModelChoice]
    /// The models imported into the edits' files, listed apart.
    var imported: Set<String> = []
    /// Chooses FBX or OBJ files to import; nil without the edits' files.
    var importFiles: (() -> Void)?
    let choose: (EditorModelChoice) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection: EditorModelChoice.ID?

    private var filtered: [EditorModelChoice] {
        let words = query.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
        guard !words.isEmpty else { return models }
        return models.filter { model in words.allSatisfy { model.path.lowercased().contains($0) } }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("Add Model")).font(.headline)
                Spacer()
                TextField(L("Search Models"), text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
            }
            .padding(14)
            Divider()
            List(selection: $selection) {
                section(L("This Wallpaper"), filtered.filter { !$0.isShared && !imported.contains($0.path) })
                section(L("Imported"), filtered.filter { imported.contains($0.path) })
                section(L("Wallpaper Engine"), filtered.filter(\.isShared))
            }
            .overlay {
                if filtered.isEmpty {
                    Text(models.isEmpty ? L("Neither this wallpaper nor Wallpaper Engine’s assets have a 3D model (.mdl).")
                                        : L("No models match."))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                }
            }
            Divider()
            HStack {
                if let importFiles {
                    Button(L("Import FBX or OBJ…")) {
                        dismiss()
                        importFiles()
                    }
                }
                Spacer()
                Button(L("Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L("Add")) { selected.map(add) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected == nil)
            }
            .padding(14)
        }
        .frame(minWidth: 460, idealWidth: 520, minHeight: 360, idealHeight: 440)
    }

    @ViewBuilder private func section(_ title: String, _ items: [EditorModelChoice]) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { model in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.title)
                        Text(model.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    .tag(model.id)
                    .onTapGesture(count: 2) { add(model) }
                }
            }
        }
    }

    private var selected: EditorModelChoice? { models.first { $0.id == selection } }

    private func add(_ model: EditorModelChoice) {
        dismiss()
        choose(model)
    }
}
