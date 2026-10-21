import AppKit
import UniformTypeIdentifiers
import SwiftUI
import OWEModelImport
import OWESceneEditing

/// The window's tool state the canvas, the layer list and the inspector share: snapping and its
/// guides, mask painting, and the sidebar's tab.
@MainActor
final class EditorTools: ObservableObject {
    enum SidebarTab: String, CaseIterable, Identifiable {
        case layers, assets
        var id: String { rawValue }
    }

    /// Dragged layers snap to the scene's edges and centre and to other layers (Command while
    /// dragging turns it off for that drag).
    @Published var snapping = true
    /// Where the drag in progress snapped, drawn on the canvas.
    @Published var guides: [LayerSnapping.Guide] = []
    /// The effects open in the inspector, as `<layer>:<effect key>`: the canvas draws their gizmos.
    @Published var expandedEffects: Set<String> = []
    @Published var maskPainting: MaskPainting?
    @Published var sidebarTab: SidebarTab = .layers
    /// The layer whose name is being edited in the list.
    @Published var renaming: Int?
    /// Copy Transforms' `origin`, `scale` and `angles`, for Paste Transforms.
    @Published var copiedTransform: LayerTransform?
    /// Copy Effect's effect, and Copy all Effects' list, for pasting on any layer of the window.
    @Published var copiedEffect: SceneJSONValue?
    @Published var copiedEffects: [SceneJSONValue] = []
    /// The layer Move to Custom Position asks a list position for.
    @Published var choosingListPosition: Int?
    /// Edit with External Image Editor's watches, made on first use.
    var externalEditor: ExternalImageEditor?
    /// A message for the window's banner (an import that failed, say).
    @Published var problem: String?
    /// The canvas's gizmo: which handles the selection shows (Multi, every one, in a 2D scene; the
    /// canvas switches a 3D scene to Translate).
    @Published var gizmoMode: GizmoMode = .multi
    /// Each mode's space as last chosen; unset, the mode's own (`GizmoMode.defaultSpace`).
    @Published var gizmoSpaces: [GizmoMode: GizmoSpace] = [:]

    /// The current mode's axes: the scene's or the object's own.
    var gizmoSpace: GizmoSpace {
        get { gizmoSpaces[gizmoMode] ?? gizmoMode.defaultSpace }
        set { if gizmoMode.hasSpaceChoice { gizmoSpaces[gizmoMode] = newValue } }
    }

    /// A gizmo button: its mode, or none when it is the mode already (WE's `setGizmoMode`).
    func toggleGizmoMode(_ mode: GizmoMode) {
        gizmoMode = gizmoMode == mode ? .none : mode
    }
    /// Images waiting for the importer's options (`ImportOptionsSheet`).
    @Published var pendingImport: PendingImageImport?
    /// Normal Map Generation's options by material, kept while the window is open (as WE's editor).
    var normalMapSettings: [String: NormalMapGenerator.Settings] = [:]
    /// The image tool window open over the editor (Image Editing).
    @Published var imageTool: ImageToolRequest?

    /// Canvas points within which a drag snaps.
    static let snapDistance: Double = 6

    func isExpanded(_ effectKey: String, of layerID: Int) -> Bool { expandedEffects.contains("\(layerID):\(effectKey)") }

    func setExpanded(_ expanded: Bool, _ effectKey: String, of layerID: Int) {
        let key = "\(layerID):\(effectKey)"
        if expanded { expandedEffects.insert(key) } else { expandedEffects.remove(key) }
    }
}

/// Choosing files to import, as the Add menu and the asset browser do.
@MainActor
enum EditorFilePicker {
    enum Kind {
        case image, sound, font, mask, model

        var allowedExtensions: [String] {
            switch self {
            case .image: return ["png", "jpg", "jpeg", "gif", "tif", "tiff", "bmp", "heic", "webp", "psd", "tga"]
                + EditorAssetStore.videoTypes.sorted()
            case .mask: return ["png", "jpg", "jpeg", "gif", "tif", "tiff", "bmp", "heic", "webp", "psd", "tga"]
            case .sound: return EditorAssetStore.soundTypes.sorted()
            case .font: return EditorAssetStore.fontTypes.sorted()
            case .model: return EditorModelImporter.fileExtensions.sorted()
            }
        }
    }

    /// The files chosen; empty when the panel was cancelled.
    static func choose(_ kind: Kind, multiple: Bool = false) -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = multiple
        panel.allowedContentTypes = kind.allowedExtensions.compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK else { return [] }
        return panel.urls
    }
}

/// Images chosen or dropped for new image layers, waiting for the importer's options.
struct PendingImageImport: Identifiable {
    let id = UUID()
    var urls: [URL]
    /// Where on the scene they were dropped; nil for its centre.
    var point: SIMD2<Double>?
}
