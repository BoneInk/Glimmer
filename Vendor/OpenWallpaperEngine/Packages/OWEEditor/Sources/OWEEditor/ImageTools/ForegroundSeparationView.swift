import OWESceneEditing
import SwiftUI

/// What an image tool window works on, from the layer context menu's Image Editing submenu.
struct ImageToolRequest: Identifiable, Equatable {
    enum Tool: Equatable {
        case foregroundSeparation
        case characterSheet
        /// Puppet Warp on the sheet Character Sheet Creation made.
        case puppetWarp
    }

    var tool: Tool
    var layerID: Int
    var id: String { "\(tool)-\(layerID)" }
}

/// The image tool windows the editor shows over its window.
struct ImageToolSheet: View {
    let request: ImageToolRequest
    let session: SceneEditSession
    let services: WallpaperEditorServices
    let tools: EditorTools

    var body: some View {
        switch request.tool {
        case .foregroundSeparation:
            ForegroundSeparationView(session: session, layerID: request.layerID, services: services, tools: tools)
        case .characterSheet:
            CharacterSheetView(session: session, layerID: request.layerID, services: services, tools: tools)
        case .puppetWarp:
            if let assets = services.puppetEditorAssets, let layer = session.outline.layer(request.layerID) {
                PuppetWorkspaceView(session: session, layer: layer, assets: assets)
            }
        }
    }
}

/// The picture of an image layer, as the image tools read it.
@MainActor
enum ImageToolPicture {
    static func load(layerID: Int, session: SceneEditSession, services: WallpaperEditorServices) -> RGBAImage? {
        guard let layer = session.outline.layer(layerID), let material = ImageLayerMaterial(layer: layer, readFile: services.readFile),
              let texture = material.texture, let image = services.texture(texture) else { return nil }
        return RGBAImage(image)
    }
}

/// WE's Foreground Separation window for one image layer.
struct ForegroundSeparationView: View {
    let session: SceneEditSession
    let layerID: Int
    let services: WallpaperEditorServices
    let tools: EditorTools
    @StateObject private var holder: EditorHolder
    @State private var viewport = ImageToolViewport()
    @State private var isConfirming = false
    @State private var isConfirmingCancel = false
    @State private var problem: String?
    @Environment(\.dismiss) private var dismiss

    static let helpURL = URL(string: "https://docs.wallpaperengine.io/en/scene/image-preparation/foreground-separation.html")!

    /// Holds the editor once the picture is read.
    @MainActor
    final class EditorHolder: ObservableObject {
        let editor: SeparationEditor?
        init(picture: RGBAImage?) {
            editor = picture.map { SeparationEditor(picture: $0, settings: ForegroundSeparator.Settings()) }
        }
    }

    init(session: SceneEditSession, layerID: Int, services: WallpaperEditorServices, tools: EditorTools) {
        self.session = session
        self.layerID = layerID
        self.services = services
        self.tools = tools
        _holder = StateObject(wrappedValue: EditorHolder(picture: ImageToolPicture.load(layerID: layerID, session: session, services: services)))
    }

    var body: some View {
        VStack(spacing: 0) {
            if let editor = holder.editor {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(IL("Foreground Separation")).font(.headline).padding([.top, .horizontal], 12)
                        SeparationControls(editor: editor)
                    }
                    .frame(width: 300)
                    Divider()
                    VStack(spacing: 0) {
                        SeparationViewBar(editor: editor) { viewport.fit() }
                        Divider()
                        SeparationCanvasView(editor: editor, viewport: $viewport)
                        if editor.mode == .brush {
                            Text(IL("Tip: Only draw rough outlines of the foreground and background. Pixel-perfect outlines will not improve the result. Click Help for more information."))
                                .font(.caption).foregroundStyle(.secondary).padding(6)
                        }
                    }
                }
                .onAppear {
                    viewport.imageSize = editor.size
                    editor.start()
                }
                Divider()
                footer(editor)
            } else {
                ContentUnavailableView(IL("Only for Image Layers"), systemImage: "photo",
                                       description: Text(IL("The layer’s picture can’t be read.")))
                Button(IL("Close")) { dismiss() }.padding()
            }
        }
        .frame(minWidth: 1000, idealWidth: 1280, minHeight: 680, idealHeight: 820)
    }

    private func footer(_ editor: SeparationEditor) -> some View {
        HStack {
            SeparationFooterTools(editor: editor, helpURL: Self.helpURL)
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Button(IL("Cancel"), role: .cancel) {
                if editor.hasEdits { isConfirmingCancel = true } else { dismiss() }
            }
            .keyboardShortcut(.cancelAction)
            Button(IL("OK")) { isConfirming = true }
                .keyboardShortcut(.defaultAction)
                .disabled(editor.isComputing || editor.result == nil)
        }
        .padding(12)
        .alert(IL("Confirm Foreground Separation"), isPresented: $isConfirming) {
            Button(IL("OK")) { apply(editor) }
            Button(IL("Cancel"), role: .cancel) {}
        } message: {
            Text(IL("The existing image layer will be replaced with the new background image and a new layer with the foreground image will be added. Do you want to continue?"))
        }
        .alert(IL("Cancel"), isPresented: $isConfirmingCancel) {
            Button(IL("Discard"), role: .destructive) { dismiss() }
            Button(IL("Keep Editing"), role: .cancel) {}
        } message: {
            Text(IL("Do you want to cancel and discard the mask?"))
        }
    }

    private func apply(_ editor: SeparationEditor) {
        guard let result = editor.result, let store = services.assetStore else { return }
        let name = session.outline.layer(layerID)?.title ?? ""
        do {
            try session.applyForegroundSeparation(result, to: layerID, store: store, readFile: services.readFile,
                                                  foregroundName: IL("\(name) Foreground"), actionName: IL("Foreground Separation"))
            dismiss()
        } catch {
            problem = IL("The separation couldn’t be saved: \(error.localizedDescription)")
        }
    }
}
