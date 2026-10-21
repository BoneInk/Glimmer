import Foundation

/// Builds a scene's `SceneSpatialContent` (docs/models-plan.md § Seams): the camera settings,
/// the `camera` block, its path files, every camera layer with its path file, and every model
/// object. Objects must already carry their ids (`SceneObjectIdentity.assigningFallbackIDs`).
struct SceneSpatialContentBuilder {
    /// Reads a file of the wallpaper (its folder, its `.pkg` or WE's assets); nil when missing.
    var readFile: (String) -> Data?
    /// For log lines.
    var wallpaperName: String

    func build(_ authoredScene: WEScene, context: SceneValueContext) -> SceneSpatialContent {
        var scene = authoredScene
        scene.objects = SceneObjectIdentity.assigningFallbackIDs(scene.objects)
        var content = SceneSpatialContent()
        content.camera = SceneCameraSettings(scene.general, in: context)
        content.drawOrder = SceneDrawOrderMode(content.camera)
        content.transforms = SceneTransformHierarchy3D(objects: scene.objects)
        if let eye = scene.camera.eye { content.staticEye = Self.vector(eye) }
        if let center = scene.camera.center { content.staticCenter = Self.vector(center) }
        if let up = scene.camera.up { content.staticUp = Self.vector(up) }
        for file in scene.camera.paths ?? [] {
            guard let data = read(file, what: "camera path") else { continue }
            do {
                content.cameraPaths += try WESceneCameraPathFile(data: data).paths
            } catch {
                OWELog.error(.scene, "\(wallpaperName): camera path \(file) can't be read: \(error)")
            }
        }
        for (index, object) in scene.objects.enumerated() {
            let id = String(SceneObjectIdentity.id(of: object, at: index))
            let name = object.name ?? "#\(index)"
            if !object.renderValues.isEmpty { content.renderValues[id] = object.renderValues }
            // WE's factory tries model, particle, image, sprite and text before shape (0x14019075e).
            if object.shape != nil, object.model == nil, object.particle == nil, object.image == nil, object.textValue == nil {
                content.unreflectable.insert(id)
            }
            if let model = object.model {
                content.models.append(SceneModelObject(id: id, name: name, order: index, authored: model,
                                                       animationLayers: object.animationLayers,
                                                       renderValues: object.renderValues,
                                                       perspective: object.perspective ?? false))
            } else if let layer = object.cameraLayer {
                content.cameraLayers.append(SceneCameraLayerObject(id: id, name: name, order: index, authored: layer,
                                                                   pathFile: layer.path.flatMap(cameraLayerPaths)))
            }
        }
        return content
    }

    private func cameraLayerPaths(_ file: String) -> WECameraLayerPathFile? {
        guard let data = read(file, what: "camera layer path") else { return nil }
        do {
            return try WECameraLayerPathFile(data: data)
        } catch {
            OWELog.error(.scene, "\(wallpaperName): camera layer path \(file) can't be read: \(error)")
            return nil
        }
    }

    private func read(_ file: String, what: String) -> Data? {
        guard let data = readFile(file) else {
            OWELog.error(.scene, "\(wallpaperName): \(what) \(file) is missing")
            return nil
        }
        return data
    }

    private static func vector(_ text: String) -> SIMD3<Float> {
        let (x, y, z) = text.parseVector3()
        return SIMD3(Float(x), Float(y), Float(z))
    }
}
