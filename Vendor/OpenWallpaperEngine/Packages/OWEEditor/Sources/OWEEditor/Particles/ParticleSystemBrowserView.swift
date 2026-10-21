import SwiftUI
import OWEInspectorKit
import OWESceneEditing

/// Add Particle System: every particle system WE's editor offers (`ParticleCatalog`), its default
/// systems and each preset's variants, in WE's groups, searchable, each with a preview (the system
/// on a dark background, a short loop rendered on first view and cached). Without WE's assets it
/// offers to install them.
struct ParticleSystemBrowserView: View {
    @ObservedObject var services: ParticleEditorServices
    @Environment(\.dismiss) private var dismiss
    @State private var catalog: ParticleCatalog?
    @State private var query = ""
    @State private var selection: ParticleCatalog.Item.ID?

    private static let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(PartL("Add Particle System")).font(.headline)
                Spacer()
                TextField(PartL("Search Particle Systems"), text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
            }
            .padding(14)
            Divider()
            ScrollView {
                content
                    .padding(14)
            }
            Divider()
            HStack {
                if let item = selectedItem, !item.summary.isEmpty {
                    Text(item.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button(L("Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(PartL("Add")) { selectedItem.map(choose) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedItem == nil)
            }
            .padding(14)
        }
        .frame(minWidth: 640, idealWidth: 760, minHeight: 480, idealHeight: 600)
        .task { catalog = services.catalog() }
        .onAppear { services.previews?.beginOpen(.particleSystems) }
        .onDisappear { services.previews?.endOpen() }
    }

    @ViewBuilder private var content: some View {
        if !services.hasWEAssets() {
            EditorAssetsPrompt(message: PartL("Wallpaper Engine’s particle systems and presets come with its assets, which aren’t installed."),
                               openSetup: openSetup)
        } else if let catalog {
            let groups = ParticleCatalog.grouped(ParticleCatalog.filter(catalog.items, query: query),
                                                 sceneIs3D: !services.model.pixelUnits)
            LazyVStack(alignment: .leading, spacing: 16) {
                if !catalog.hasPresets {
                    HStack {
                        Text(PartL("This copy of Wallpaper Engine’s assets has no presets. Install the assets again to add them."))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(PartL("Install Again…"), action: openSetup)
                    }
                }
                if groups.isEmpty {
                    Text(catalog.items.isEmpty ? PartL("Wallpaper Engine’s particle systems aren’t installed.")
                                               : PartL("No particle systems match."))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(40)
                }
                ForEach(groups, id: \.group) { entry in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title(of: entry.group))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 12) {
                            ForEach(entry.items) { item in
                                ParticleSystemTile(item: item, previews: services.previews, isSelected: selection == item.id)
                                    .onTapGesture(count: 2) { choose(item) }
                                    .onTapGesture { selection = item.id }
                                    .accessibilityAddTraits(.isButton)
                            }
                        }
                    }
                }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity).padding(40)
        }
    }

    private func title(of group: ParticleCatalog.Group) -> String {
        switch group.kind {
        case .systems(let is3D): return is3D ? PartL("3D Particle Systems") : PartL("Particle Systems")
        case .preset: return group.title
        }
    }

    private var selectedItem: ParticleCatalog.Item? {
        catalog?.items.first { $0.id == selection }
    }

    private func openSetup() {
        dismiss()
        services.openAssetsSetup()
    }

    private func choose(_ item: ParticleCatalog.Item) {
        dismiss()
        let model = services.model
        switch item.source {
        case .system(let path):
            model.addSystem(from: path, name: item.title, actionName: PartL("Add \(item.title)"))
        case .preset(let preset, let variant):
            model.addPreset(preset, variant: variant, actionName: PartL("Add \(variant.title)"))
        }
    }
}

/// One system or preset variant: its preview, title and preset.
private struct ParticleSystemTile: View {
    @Environment(\.appAccentColor) private var accentColor
    let item: ParticleCatalog.Item
    let previews: EditorPreviewProvider?
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.85))
                if let previews {
                    EditorPreviewView(provider: previews, subject: item.previewSubject, symbol: "sparkles")
                } else {
                    SymbolPreview(symbol: "sparkles")
                }
            }
            .frame(height: 84)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(item.title).font(.callout.weight(.medium)).lineLimit(1)
            if !item.group.title.isEmpty {
                Text(item.group.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(8)
        .background(isSelected ? accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isSelected ? accentColor : .clear, lineWidth: 1.5)
        }
        .contentShape(Rectangle())
        .help(item.summary)
    }
}
