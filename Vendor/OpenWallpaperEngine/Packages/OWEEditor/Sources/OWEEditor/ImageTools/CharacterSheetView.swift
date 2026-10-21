import OWESceneEditing
import SwiftUI

/// WE's Puppet Sheet Creation window (Image Editing › Character Sheet Creation): the limb
/// hierarchy on the left, the selected limb's separation beside it, and OK, which makes the sheet
/// and opens Puppet Warp on it, where WE's guide goes next.
struct CharacterSheetView: View {
    @StateObject private var model: CharacterSheetModel
    let tools: EditorTools
    let hasPuppetEditor: Bool
    @State private var viewport = ImageToolViewport()
    @State private var newLimbName = ""
    @State private var isAddingLimb = false
    @State private var removing: CharacterSheetModel.Limb?
    @State private var isConfirming = false
    @State private var isConfirmingCancel = false
    @Environment(\.dismiss) private var dismiss

    static let helpURL = URL(string: "https://docs.wallpaperengine.io/en/scene/image-preparation/character-sheet.html")!

    init(session: SceneEditSession, layerID: Int, services: WallpaperEditorServices, tools: EditorTools) {
        _model = StateObject(wrappedValue: CharacterSheetModel(session: session, layerID: layerID, services: services,
                                                               bodyName: IL("Body")))
        self.tools = tools
        hasPuppetEditor = services.puppetAssets != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if let picture = model.picture {
                HStack(spacing: 0) {
                    hierarchy.frame(width: 220)
                    Divider()
                    controls.frame(width: 300)
                    Divider()
                    canvas
                }
                .onAppear { viewport.imageSize = SIMD2(Double(picture.width), Double(picture.height)) }
                Divider()
                footer
            } else {
                ContentUnavailableView(IL("Only for Image Layers"), systemImage: "photo",
                                       description: Text(IL("The layer’s picture can’t be read.")))
                Button(IL("Close")) { dismiss() }.padding()
            }
        }
        .frame(minWidth: 1180, idealWidth: 1400, minHeight: 700, idealHeight: 860)
        .overlay { if model.isGenerating { busy } }
        .onChange(of: model.selection) { _, _ in
            model.refreshSources()
            model.selected?.editor?.start()
        }
        .alert(IL("Add Limb"), isPresented: $isAddingLimb) {
            TextField(IL("Name"), text: $newLimbName)
            Button(IL("OK")) { model.addLimb(named: newLimbName); model.selected?.editor?.start() }
            Button(IL("Cancel"), role: .cancel) {}
        } message: {
            Text(IL("Enter name of character limb:"))
        }
        .alert(IL("Remove Limb \(removing?.name ?? "")"), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button(IL("Remove"), role: .destructive) { if let removing { model.removeLimb(removing.id) } }
            Button(IL("Cancel"), role: .cancel) {}
        } message: {
            Text(IL("Are you sure that you want to remove the limb \(removing?.name ?? "")?"))
        }
    }

    private var hierarchy: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(IL("Puppet Sheet Creation")).font(.headline)
            Button { newLimbName = ""; isAddingLimb = true } label: { Label(IL("Add Limb"), systemImage: "plus") }
            Text(IL("Hierarchy")).font(.subheadline).foregroundStyle(.secondary)
            List(selection: $model.selection) {
                ForEach(Array(model.limbs.enumerated()), id: \.element.id) { index, limb in
                    HStack(spacing: 4) {
                        Text(model.treePrefix(index)).font(.body.monospaced()).foregroundStyle(.secondary)
                        Text(limb.name).lineLimit(1)
                        Spacer()
                        if limb.depth > 0 {
                            Button { removing = limb } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.borderless)
                                .help(IL("Remove Limb"))
                        }
                    }
                    .tag(limb.id)
                }
            }
            .listStyle(.sidebar)
        }
        .padding(12)
    }

    @ViewBuilder private var controls: some View {
        if let editor = model.selected?.editor {
            SeparationControls(editor: editor).id(model.selection)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "figure.stand").font(.largeTitle).foregroundStyle(.secondary)
                Text(IL("Add a limb to separate it from the body.")).multilineTextAlignment(.center).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        }
    }

    @ViewBuilder private var canvas: some View {
        VStack(spacing: 0) {
            if let editor = model.selected?.editor {
                SeparationViewBar(editor: editor) { viewport.fit() }
                Divider()
                SeparationCanvasView(editor: editor, viewport: $viewport).id(model.selection)
            } else {
                ImageToolCanvas(image: model.picture?.cgImage, viewport: $viewport) { _ in EmptyView() }
            }
        }
    }

    private var footer: some View {
        HStack {
            if let editor = model.selected?.editor {
                SeparationFooterTools(editor: editor, helpURL: Self.helpURL)
            }
            if let problem = model.problem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Button(IL("Cancel"), role: .cancel) {
                if model.limbs.count > 1 { isConfirmingCancel = true } else { dismiss() }
            }
            .keyboardShortcut(.cancelAction)
            Button(IL("OK")) { isConfirming = true }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canFinish)
        }
        .padding(12)
        .alert(IL("Confirm Puppet Sheet Creation"), isPresented: $isConfirming) {
            Button(IL("OK")) { finish() }
            Button(IL("Cancel"), role: .cancel) {}
        } message: {
            Text(IL("The existing layer will be removed along with any effects or settings and a new texture with the character sheet for puppet warp will be imported. Do you want to continue?"))
        }
        .alert(IL("Cancel"), isPresented: $isConfirmingCancel) {
            Button(IL("Discard"), role: .destructive) { dismiss() }
            Button(IL("Keep Editing"), role: .cancel) {}
        } message: {
            Text(IL("Do you want to cancel and discard the mask?"))
        }
    }

    private var busy: some View {
        ZStack {
            Color.black.opacity(0.35)
            VStack(spacing: 12) {
                Text(IL("Generating Puppet Warp Sheet")).font(.headline)
                ProgressView()
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func finish() {
        Task {
            guard let id = await model.finish() else { return }
            // WE's guide continues in Puppet Warp with the sheet.
            tools.imageTool = hasPuppetEditor ? ImageToolRequest(tool: .puppetWarp, layerID: id) : nil
            if !hasPuppetEditor { dismiss() }
        }
    }
}
