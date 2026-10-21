import AppKit
import OWESceneEditing

/// WE's Edit with External Image Editor: an image layer's picture is written as a PNG and opened
/// in the image editor the author chose (WE's "Custom image editor path"; asked for the first
/// time, as WE's "Select Image Editor"), and every time the editor saves it the picture is
/// imported again and becomes the layer's image, one undo step each ("Changes you make will be
/// automatically re-imported").
@MainActor
final class ExternalImageEditor {
    /// The defaults key of the chosen app's location.
    static let applicationKey = "WallpaperEditorExternalImageEditor"

    private let editing: ExternalImageEditing
    private var watchers: [Int: DirectoryWatch] = [:]

    init(editing: ExternalImageEditing) {
        self.editing = editing
    }

    /// The chosen app, if it is still there.
    var application: URL? {
        guard let path = editing.defaults.string(forKey: Self.applicationKey),
              FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(filePath: path)
    }

    /// Asks for the image editor (an app); keeps and returns it, nil when cancelled.
    @discardableResult
    func chooseApplication() -> URL? {
        let panel = NSOpenPanel()
        panel.title = L("Select Image Editor")
        panel.message = L("Choose the app that edits image layers. Changes you save there are imported again automatically.")
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(filePath: "/Applications", directoryHint: .isDirectory)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        editing.defaults.set(url.path(percentEncoded: false), forKey: Self.applicationKey)
        return url
    }

    /// The texture the image layer draws (its model's material's first texture), when it has a
    /// picture of its own.
    static func texture(of layer: SceneLayer, readFile: (String) -> Data?) -> String? {
        // Optional: a model or material that can't be read has no picture to edit (the scene's
        // load reports it).
        guard layer.imageRole == .picture, let model = layer.fields["image"]?.stringValue,
              let modelJSON = readFile(model).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
              let material = modelJSON["material"] as? String,
              let materialJSON = readFile(material).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
              let pass = (materialJSON["passes"] as? [[String: Any]])?.first,
              let texture = (pass["textures"] as? [Any])?.first as? String, !texture.hasPrefix("_rt") else { return nil }
        return texture
    }

    /// Opens the layer's picture in the image editor and imports it again whenever it is saved.
    func edit(_ layer: SceneLayer, session: SceneEditSession, services: WallpaperEditorServices, tools: EditorTools) {
        guard let store = services.assetStore,
              let texture = Self.texture(of: layer, readFile: services.readFile),
              let image = services.texture(texture), let png = EditorAssetStore.pngData(image) else {
            tools.problem = L("This layer has no picture of its own to edit.")
            return
        }
        guard let application = application ?? chooseApplication() else { return }
        let cleaned = EditorAssetStore.materialFileName(layer.name ?? "")
        let base = cleaned.isEmpty ? "layer" : cleaned
        let file = editing.directory.appending(path: "\(base)-\(layer.id).png")
        do {
            try FileManager.default.createDirectory(at: editing.directory, withIntermediateDirectories: true)
            try png.write(to: file, options: .atomic)
        } catch {
            tools.problem = L("The picture couldn’t be handed to the image editor: \(error.localizedDescription)")
            return
        }
        watch(file, layerID: layer.id, session: session, store: store, tools: tools)
        NSWorkspace.shared.open([file], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard let error else { return }
            Task { @MainActor in tools.problem = L("The image editor couldn’t open the picture: \(error.localizedDescription)") }
        }
    }

    /// Re-imports `file` as the layer's image each time its modification date changes.
    private func watch(_ file: URL, layerID: Int, session: SceneEditSession, store: EditorAssetStore, tools: EditorTools) {
        watchers[layerID] = nil
        var last = Self.modified(file)
        watchers[layerID] = DirectoryWatch(directory: file.deletingLastPathComponent()) { [weak session, weak tools] in
            guard let session, let tools else { return }
            let now = Self.modified(file)
            guard now != nil, now != last else { return }
            last = now
            Self.reimport(file, layerID: layerID, session: session, store: store, tools: tools)
        }
    }

    static func reimport(_ file: URL, layerID: Int, session: SceneEditSession, store: EditorAssetStore, tools: EditorTools) {
        guard session.outline.layer(layerID) != nil else { return }
        do {
            let image = try store.importImage(from: file)
            session.edit(actionName: L("Edit with External Image Editor")) { overlay in
                overlay.setField("image", to: .string(image.model), of: layerID)
                overlay.setField("size", to: SceneVector.value([image.size.x, image.size.y]), of: layerID)
            }
        } catch {
            tools.problem = L("“\(file.lastPathComponent)” couldn’t be imported again: \(error.localizedDescription)")
        }
    }

    private static func modified(_ file: URL) -> Date? {
        // Optional: a file being replaced has no date for a moment; the next event reads it.
        (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}

/// Calls `onChange` on the main actor when anything in a folder changes (editors save by
/// replacing the file, which a watch of the file itself would lose).
@MainActor
final class DirectoryWatch {
    private let source: DispatchSourceFileSystemObject?

    init(directory: URL, onChange: @escaping @MainActor () -> Void) {
        let descriptor = open(directory.path(percentEncoded: false), O_EVTONLY)
        guard descriptor >= 0 else {
            source = nil
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .extend],
                                                               queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { onChange() } }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    deinit { source?.cancel() }
}
