import AppKit
import SwiftUI
import OWEModelImport
import OWESceneEditing

/// Adding and rearranging layers, as the Add menu, the layer list's menus, the asset browser and
/// drops on the canvas do it: one place, one undo step each.
@MainActor
struct LayerActions {
    let session: SceneEditSession
    let services: WallpaperEditorServices
    let tools: EditorTools

    /// Where a new layer goes: the scene's centre (a 3D scene's origin).
    var sceneCentre: SIMD2<Double> { (session.outline.size ?? .zero) / 2 }

    var sceneSize: SIMD2<Double> { session.outline.size ?? SIMD2(1920, 1080) }

    // MARK: Adding

    /// Images (and GIFs and MP4s) to add: WE's importer asks for their texture options first
    /// (`ImportOptionsSheet`, then `importImages`); a video alone has none to ask.
    func addImages(_ urls: [URL], at point: SIMD2<Double>? = nil) {
        guard services.assetStore != nil, !urls.isEmpty else { return }
        if urls.allSatisfy({ EditorAssetStore.videoTypes.contains($0.pathExtension.lowercased()) }) {
            importImages(urls, options: TextureImportOptions(), asSequence: false, at: point)
        } else {
            tools.pendingImport = PendingImageImport(urls: urls, point: point)
        }
    }

    func chooseImages() { addImages(EditorFilePicker.choose(.image, multiple: true)) }

    /// An image layer of a texture the wallpaper or the editor already has (`materials/….tex`).
    func addImage(fromModel model: String, title: String, size: SIMD2<Double>?, at point: SIMD2<Double>? = nil) {
        let object = SceneLayerFactory.image(name: title, model: model, size: size ?? sceneSize / 2, origin: point ?? sceneCentre)
        session.addLayer(object, actionName: L("Add Image Layer"))
    }

    /// WE's new text layer: Arial at 32 points.
    func addText(script: SceneLayerFactory.TextScript? = nil) {
        let value = script?.placeholder ?? L("Text")
        let object = SceneLayerFactory.text(name: script == .clock ? L("Clock") : script == .date ? L("Date") : L("Text"),
                                            value: value, font: "systemfont_arial", pointSize: 32, origin: sceneCentre,
                                            script: script?.source, scriptProperties: script?.properties)
        let id = session.addLayer(object, actionName: L("Add Text Layer"))
        if script == nil { session.editingText = id }
    }

    func addSolid() {
        let object = SceneLayerFactory.solid(name: L("Solid Color"), color: SIMD3(1, 1, 1), size: sceneSize, origin: sceneCentre)
        session.addLayer(object, actionName: L("Add Solid Color Layer"))
    }

    func addComposition() {
        let object = SceneLayerFactory.composition(name: L("Composition"), size: sceneSize / 2, origin: sceneCentre)
        session.addLayer(object, actionName: L("Add Composition Layer"))
    }

    func addFullscreen() {
        session.addLayer(SceneLayerFactory.fullscreen(name: L("Fullscreen")), actionName: L("Add Fullscreen Layer"))
    }

    func addSounds(_ urls: [URL]) {
        guard let store = services.assetStore else { return }
        var paths: [String] = []
        for url in urls {
            do {
                paths.append(try store.importSound(from: url))
            } catch {
                tools.problem = L("“\(url.lastPathComponent)” couldn’t be added: \(error.localizedDescription)")
            }
        }
        guard let first = urls.first, !paths.isEmpty else { return }
        addSound(paths: paths, title: first.deletingPathExtension().lastPathComponent)
    }

    func addSound(paths: [String], title: String) {
        session.addLayer(SceneLayerFactory.sound(name: title, files: paths), actionName: L("Add Sound Layer"))
    }

    func chooseSounds() { addSounds(EditorFilePicker.choose(.sound, multiple: true)) }

    /// Files dropped on the canvas or the asset browser: images become image layers at the drop
    /// point, sounds a sound layer, FBX and OBJ models model layers, fonts are imported for text
    /// layers.
    func importDropped(_ urls: [URL], at point: SIMD2<Double>? = nil) {
        guard let store = services.assetStore else { return }
        var images: [URL] = [], sounds: [URL] = [], models: [URL] = []
        for url in urls {
            let fileExtension = url.pathExtension.lowercased()
            if EditorModelImporter.fileExtensions.contains(fileExtension) {
                models.append(url)
            } else if EditorAssetStore.soundTypes.contains(fileExtension) {
                sounds.append(url)
            } else if EditorAssetStore.fontTypes.contains(fileExtension) {
                do { _ = try store.importFont(from: url) } catch {
                    tools.problem = L("“\(url.lastPathComponent)” couldn’t be added: \(error.localizedDescription)")
                }
            } else {
                images.append(url)
            }
        }
        addImages(images, at: point)
        if !sounds.isEmpty { addSounds(sounds) }
        if !models.isEmpty { importModels(models, at: point) }
    }

    // MARK: Arranging

    func duplicate(_ id: Int) {
        session.duplicate([id], copyName: { name in
            name.isEmpty ? L("Copy") : L("\(name) Copy")
        }, actionName: L("Duplicate Layer"))
    }

    func delete(_ id: Int) { session.delete([id], actionName: L("Delete Layer")) }

    func group(_ id: Int) { session.group([id], name: L("Group"), actionName: L("Group Layer")) }

    func ungroup(_ id: Int) { session.ungroup(id, actionName: L("Ungroup")) }

    func unparent(_ id: Int) { session.setParent([id], to: nil, actionName: L("Move Out of Group")) }

    func parent(_ id: Int, to parent: Int) { session.setParent([id], to: parent, actionName: L("Move Into Group")) }

    func bringForward(_ id: Int) { session.step(id, by: 1, actionName: L("Bring Forward")) }
    func sendBackward(_ id: Int) { session.step(id, by: -1, actionName: L("Send Backward")) }
    func bringToFront(_ id: Int) { session.step(id, by: Int.max / 2, actionName: L("Bring to Front")) }
    func sendToBack(_ id: Int) { session.step(id, by: -(Int.max / 2), actionName: L("Send to Back")) }

    /// 0 the minimum (left, bottom), 1 the centre, 2 the maximum (right, top).
    func align(_ id: Int, horizontal: Int? = nil, vertical: Int? = nil) {
        session.alignToScene(id, horizontal: horizontal, vertical: vertical, actionName: L("Align Layer"))
    }
}
