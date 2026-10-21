import SwiftUI
import AVFoundation
import OWEInspectorKit
import OWESceneEditing

extension SceneInspectorContent {
    var detailColumn: some View {
        let selectedItem = model.items.first(where: { $0.id == selectedID })
        return Group {
            if let item = selectedItem {
                selectedItemDetail(item)
            } else if let error = model.errorMessage {
                ContentUnavailableView("Scene Unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ContentUnavailableView("Select a Scene Object", systemImage: "square.stack.3d.up")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(ArrowKeyMove { direction in
            if let selectedItem { move(selectedItem, direction: direction) }
        })
    }

    /// Shows where the wallpaper lives and copies that path, so its files can be opened elsewhere.
    var pathControl: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(wallpaperDirectory.path, forType: .string)
            didCopyPath = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { didCopyPath = false }
        } label: {
            Label(didCopyPath ? "Copied" : "Copy Path", systemImage: didCopyPath ? "checkmark" : "doc.on.doc")
                .labelStyle(.titleAndIcon)
        }
        .help(didCopyPath ? "Copied" : "Copy wallpaper folder path\n\(wallpaperDirectory.path)")
    }

    func selectedItemDetail(_ item: SceneInspectorItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                LabeledContent("Type", value: Self.kindLabel(item.kind))
                if item.isVersion {
                    Button {
                        model.useVersion(item)
                    } label: {
                        Label("Use This Version", systemImage: "checkmark.circle")
                    }
                }
                if !item.sourcePath.isEmpty { LabeledContent("Source", value: item.sourcePath) }
                if let material = item.materialPath { LabeledContent("Material", value: material) }
                detailList("Textures", values: item.texturePaths)
                decodedTextureList(for: item)
                detailList("Shaders", values: item.shaderPaths)
                effectList(for: item)
                if !item.isSynthetic, let objectID = Int(item.id) {
                    SceneEditorDepthMapSection(host: depthMaps, objectID: objectID)
                }
                editableObjectBlock(for: item)
                if let particle = item.rawParticle {
                    editableAssetBlock(title: "Particle System", isParticle: true, text: particle, path: item.sourcePath)
                }
                if let material = item.rawMaterial, let materialPath = item.materialPath {
                    editableAssetBlock(title: "Material Properties", isParticle: false, text: material, path: materialPath)
                }
            }
            .padding()
        }
    }

    @ViewBuilder func decodedTextureList(for item: SceneInspectorItem) -> some View {
        if model.loadingItemID == item.id {
            ProgressView("Decoding textures...")
        } else if model.decodedItemID == item.id {
            ForEach(model.decodedTextures) { texture in
                VStack(alignment: .leading, spacing: 6) {
                    Text(texture.path).font(.caption.monospaced()).foregroundStyle(.secondary)
                    Image(nsImage: texture.image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: 420)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            if !item.texturePaths.isEmpty && model.decodedTextures.isEmpty {
                ContentUnavailableView("Texture Unavailable", systemImage: "photo.badge.exclamationmark")
            }
        }
    }

    func loadSelectedTextures() {
        guard let item = model.items.first(where: { $0.id == selectedID }) else { return }
        model.loadTextures(for: item)
    }

    @ViewBuilder func detailList(_ title: LocalizedStringKey, values: [String]) -> some View {
        if !values.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                ForEach(values, id: \.self) { Text($0).font(.caption.monospaced()) }
            }
        }
    }

    /// Runs a JSON editor's Save; a failure is shown in the Couldn't Save alert.
    func save(_ body: () throws -> Void) {
        do { try body() } catch { saveError = error.localizedDescription }
    }

    @ViewBuilder func editableAssetBlock(title: LocalizedStringKey, isParticle: Bool, text: String,
                                                path: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button("Save") {
                    save { try model.saveAssetJSON(text, path: path) }
                }
                .buttonStyle(.borderedProminent)
            }
            TextEditor(text: Binding(
                get: { text },
                set: { value in
                    if let itemIndex = model.items.firstIndex(where: { $0.id == selectedID }) {
                        if isParticle {
                            model.items[itemIndex].rawParticle = value
                        } else {
                            model.items[itemIndex].rawMaterial = value
                        }
                    }
                }
            ))
            .font(.system(.caption, design: .monospaced))
            .frame(minHeight: 220)
            .padding(6)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    @ViewBuilder func editableObjectBlock(for item: SceneInspectorItem) -> some View {
        if item.isSynthetic {
            VStack(alignment: .leading, spacing: 6) {
                Text("Layer Details").font(.headline)
                Text(model.items.first(where: { $0.id == item.id })?.rawObject ?? item.rawObject)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Object Properties").font(.headline)
                    Spacer()
                    Button("Save") {
                        let current = model.items.first(where: { $0.id == item.id })?.rawObject ?? item.rawObject
                        save { try model.saveObjectJSON(current, item: item) }
                    }
                    .buttonStyle(.borderedProminent)
                }
                TextEditor(text: Binding(
                    get: { model.items.first(where: { $0.id == item.id })?.rawObject ?? item.rawObject },
                    set: { value in
                        guard let index = model.items.firstIndex(where: { $0.id == item.id }) else { return }
                        model.items[index].rawObject = value
                    }
                ))
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 220)
                .padding(6)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}
