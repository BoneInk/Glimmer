import AppKit
import SwiftUI
import OWEInspectorKit
import UniformTypeIdentifiers
import OWESceneEditing

/// The wallpaper's textures, materials, models, particle systems, sounds and fonts (WE's asset
/// folders), and the files imported in the editor, with
/// import by the Import button or by dropping files: images become image layers, sounds sound
/// layers, fonts are kept for text layers. Double-click (or Add to Scene) puts an asset in.
struct AssetBrowserView: View {
    @Environment(\.appAccentColor) private var accentColor
    @ObservedObject var session: SceneEditSession
    @ObservedObject var tools: EditorTools
    let services: WallpaperEditorServices
    @State private var assets: [EditorAsset] = []
    @State private var query = ""
    @State private var isTargeted = false
    @State private var selection: EditorAsset.ID?
    @State private var isNamingMaterial = false
    @State private var materialName = ""
    @State private var isCleaning = false

    private var actions: LayerActions { LayerActions(session: session, services: services, tools: tools) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                TextField(L("Search Assets"), text: $query)
                    .textFieldStyle(.roundedBorder)
                Menu {
                    Button(L("Image…")) { actions.chooseImages(); reload() }
                    Button(L("Sound…")) { actions.chooseSounds(); reload() }
                    Button(L("Font…")) { importFonts() }
                } label: {
                    Label(L("Import"), systemImage: "square.and.arrow.down")
                }
                .fixedSize()
                .disabled(services.assetStore == nil)
                .help(L("Import files into the wallpaper’s edits"))
                ProjectToolsMenu(services: services, tools: tools, isNamingMaterial: $isNamingMaterial, isCleaning: $isCleaning)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
            List(selection: $selection) {
                ForEach(EditorAsset.Kind.allCases, id: \.self) { kind in
                    let items = filtered.filter { $0.kind == kind }
                    if !items.isEmpty {
                        Section(kind.title) {
                            ForEach(items) { asset in
                                AssetRow(asset: asset, services: services)
                                    .tag(asset.id)
                                    .onTapGesture(count: 2) { add(asset) }
                                    .contextMenu {
                                        Button(L("Add to Scene")) { add(asset) }
                                            .disabled(!canAdd(asset))
                                        Button(L("Copy Path")) {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(asset.path, forType: .string)
                                        }
                                    }
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if filtered.isEmpty {
                    Text(query.isEmpty ? L("Drop images, sounds or fonts here to import them.") : L("No assets match."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                }
            }
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .padding(4)
                        .allowsHitTesting(false)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                actions.importDropped(urls)
                reload()
                return !urls.isEmpty
            } isTargeted: { isTargeted = $0 }
        }
        .onAppear(perform: reload)
        .onChange(of: session.overlay) { _, _ in reload() }
        .alert(L("New Material"), isPresented: $isNamingMaterial) {
            TextField(L("Material name"), text: $materialName)
            Button(L("Cancel"), role: .cancel) { materialName = "" }
            Button(L("Create")) { createMaterial() }
        } message: {
            Text(L("Enter filename for the new material:"))
        }
        .sheet(isPresented: $isCleaning, onDismiss: reload) {
            CleanProjectSheet(session: session, services: services, tools: tools)
        }
    }

    private var filtered: [EditorAsset] {
        let words = query.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
        guard !words.isEmpty else { return assets }
        return assets.filter { asset in words.allSatisfy { asset.path.lowercased().contains($0) } }
    }

    private func reload() {
        var list = services.wallpaperAssets()
        let known = Set(list.map(\.path))
        for asset in services.assetStore?.assets() ?? [] where !known.contains(asset.path) {
            // The material and model an imported image comes with are listed by its texture.
            let kind = EditorAsset.kind(of: asset.path)
            guard kind != .other else { continue }
            list.append(EditorAsset(path: asset.path, kind: kind, isImported: true))
        }
        assets = list.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// WE's New Material: `materials/<name>.json`, selected in Materials once written.
    private func createMaterial() {
        defer { materialName = "" }
        guard let store = services.assetStore else { return }
        do {
            guard let path = try store.createMaterial(named: materialName) else { return }
            reload()
            selection = path
        } catch {
            tools.problem = L("The material couldn’t be created: \(error.localizedDescription)")
        }
    }

    private func importFonts() {
        guard let store = services.assetStore else { return }
        for url in EditorFilePicker.choose(.font, multiple: true) {
            do { _ = try store.importFont(from: url) } catch {
                tools.problem = L("“\(url.lastPathComponent)” couldn’t be added: \(error.localizedDescription)")
            }
        }
        reload()
    }

    private func canAdd(_ asset: EditorAsset) -> Bool {
        asset.kind == .model || asset.kind == .sound || (asset.kind == .texture && modelFor(asset) != nil)
    }

    /// The model an image texture is drawn through: the one beside it with its name.
    private func modelFor(_ asset: EditorAsset) -> String? {
        guard let name = asset.textureName else { return nil }
        let model = "models/\(name).json"
        return assets.contains(where: { $0.path.caseInsensitiveCompare(model) == .orderedSame }) ? model : nil
    }

    private func add(_ asset: EditorAsset) {
        let title = ((asset.fileName as NSString).deletingPathExtension)
        switch asset.kind {
        case .model:
            actions.addImage(fromModel: asset.path, title: title, size: imageSize(asset))
        case .texture:
            if let model = modelFor(asset) { actions.addImage(fromModel: model, title: title, size: imageSize(asset)) }
        case .sound:
            actions.addSound(paths: [asset.path], title: title)
        case .material, .particle, .font, .other:
            break
        }
    }

    /// The texture's size, for the new layer's (else the editor's default size).
    private func imageSize(_ asset: EditorAsset) -> SIMD2<Double>? {
        let texture = asset.kind == .texture ? asset.textureName
            : ((asset.path as NSString).deletingPathExtension as NSString).substring(from: min("models/".count, asset.path.count))
        guard let texture, let image = services.texture(texture) else { return nil }
        return SIMD2(Double(image.width), Double(image.height))
    }
}

private struct AssetRow: View {
    let asset: EditorAsset
    let services: WallpaperEditorServices
    @State private var thumbnail: CGImage?

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let thumbnail {
                    Image(decorative: thumbnail, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: asset.kind.symbol)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 28, height: 28)
            .background(.quaternary.opacity(thumbnail == nil ? 0 : 0.5), in: RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 1) {
                Text(asset.fileName).lineLimit(1).truncationMode(.middle)
                Text(asset.isImported ? L("Imported") : (asset.path as NSString).deletingLastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .help(asset.path)
        .task(id: asset.path) {
            guard asset.kind == .texture, let name = asset.textureName else { return }
            thumbnail = services.texture(name)
        }
    }
}

extension EditorAsset.Kind {
    var title: String {
        switch self {
        case .texture: return L("Textures")
        case .material: return L("Materials")
        case .model: return L("Models")
        case .particle: return L("Particles")
        case .sound: return L("Sounds")
        case .font: return L("Fonts")
        case .other: return L("Other Files")
        }
    }

    var symbol: String {
        switch self {
        case .texture: return "photo"
        case .material: return "paintpalette"
        case .model: return "square.stack.3d.up"
        case .particle: return "sparkles"
        case .sound: return "speaker.wave.2"
        case .font: return "textformat"
        case .other: return "doc"
        }
    }
}
