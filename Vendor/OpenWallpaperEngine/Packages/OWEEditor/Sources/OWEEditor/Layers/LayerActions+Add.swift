import Foundation
import OWESceneEditing

/// The layers of WE's Add Asset dialog beyond images, text and sounds: models, lights, cameras,
/// the Full Composition Layer, the Solid Placeholder and the presets that add other layers.
extension LayerActions {
    /// A 2D (orthographic) scene; WE offers some layers only there and places new ones differently.
    var is2D: Bool { session.outline.size != nil }

    /// The scene's camera (`camera` of scene.json) and `general.fov`, WE's defaults where missing.
    var sceneCamera: (eye: SIMD3<Double>, centre: SIMD3<Double>, up: SIMD3<Double>, fov: Double) {
        func vector(_ value: SceneJSONValue?, _ fallback: SIMD3<Double>) -> SIMD3<Double> {
            guard let value else { return fallback }
            let parts = SceneVector.components(value, fallback: [fallback.x, fallback.y, fallback.z])
            return parts.count >= 3 ? SIMD3(parts[0], parts[1], parts[2]) : fallback
        }
        // Optional: a scene without a readable root has WE's default camera.
        let root = session.outline.sceneData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let camera = (root?["camera"] as? [String: Any]).flatMap { SceneJSONValue(any: $0) }
        let fov = session.outline.general["fov"]?.doubleValue ?? 50
        return (vector(camera?["eye"], SIMD3(0, 0, 0)), vector(camera?["center"], SIMD3(0, 0, -1)),
                vector(camera?["up"], SIMD3(0, 1, 0)), fov)
    }

    // MARK: Layers

    /// A light at the view's centre (`SceneLayerFactory.light`).
    func addLight(_ kind: SceneLayerFactory.LightKind) {
        let centre = is2D ? SIMD3(sceneCentre.x, sceneCentre.y, 0) : sceneCamera.centre
        let object = SceneLayerFactory.light(name: kind.title, kind: kind, is2D: is2D, centre: centre)
        session.addLayer(object, actionName: L("Add Light"))
    }

    /// A camera framing what the scene's camera frames now.
    func addCamera() {
        let camera = sceneCamera
        let object = SceneLayerFactory.camera(name: L("Camera"), eye: camera.eye, centre: camera.centre, up: camera.up,
                                              fov: camera.fov)
        session.addLayer(object, actionName: L("Add Camera"))
    }

    /// WE's Full Composition Layer, over the whole 2D scene.
    func addFullComposition() {
        let object = SceneLayerFactory.fullComposition(name: L("Full Composition Layer"), size: sceneSize, origin: sceneCentre)
        session.addLayer(object, actionName: L("Add Full Composition Layer"))
    }

    /// WE's Solid Placeholder: white, 256 × 256 pixels (its Add dialog's defaults), drawn through
    /// the instanced model the project keeps.
    func addSolidPlaceholder() {
        guard let store = services.assetStore else { return }
        do {
            let data = try JSONSerialization.data(withJSONObject: SceneLayerFactory.solidPlaceholderModel,
                                                  options: [.prettyPrinted, .sortedKeys])
            let model = "models/solid_instance_model_\(EditorAssetStore.contentHash(data, bytes: 4)).json"
            try store.store(data, at: model)
            let object = SceneLayerFactory.solidPlaceholder(name: L("Solid Placeholder"), model: model, color: SIMD3(1, 1, 1),
                                                            size: SIMD2(256, 256), origin: sceneCentre)
            session.addLayer(object, actionName: L("Add Solid Placeholder"))
        } catch {
            tools.problem = L("The Solid Placeholder couldn’t be added: \(error.localizedDescription)")
        }
    }

    /// A model layer drawing `choice`, at a 2D scene's centre (or `point`) or a 3D scene's camera centre.
    func addModel(_ choice: EditorModelChoice, at point: SIMD2<Double>? = nil) {
        let centre = point ?? sceneCentre
        let origin = is2D ? SIMD3(centre.x, centre.y, 0) : sceneCamera.centre
        session.addLayer(SceneLayerFactory.model(name: choice.title, model: choice.path, origin: origin),
                         actionName: L("Add Model"))
    }

    // MARK: Presets

    /// Adds a preset's variant as WE's editor does: its files copied into the project (its
    /// particle definitions and materials, and the built-in effects its objects use, as an added
    /// effect's), then its objects as layers in one undo step, at the scene's centre (a particle
    /// system's origin is relative to it).
    func addPreset(_ preset: ParticlePreset, variant: ParticlePreset.Variant) {
        guard let store = services.assetStore else { return }
        do {
            for dependency in variant.dependencies {
                // A preset may list a file it doesn't ship (WE's `water` does); the scene reports
                // anything its objects then can't read.
                guard let data = try? Data(contentsOf: preset.directory.appending(path: dependency)) else { continue }
                try store.store(data, at: dependency)
            }
            let catalog = variant.effects.isEmpty ? [] : services.effectCatalog()
            for file in variant.effects {
                guard let entry = catalog.first(where: { $0.file.caseInsensitiveCompare(file) == .orderedSame }) else { continue }
                try services.prepareEffect(entry)
            }
        } catch {
            tools.problem = L("“\(variant.title)” couldn’t be added: \(error.localizedDescription)")
            return
        }
        let centre = SIMD3(sceneCentre.x, sceneCentre.y, 0)
        let objects: [[String: SceneJSONValue]] = variant.objects.compactMap { authored in
            guard case .object(var fields) = authored else { return nil }
            fields["id"] = nil
            if fields["particle"]?.stringValue != nil {
                let origin = SceneVector.components(fields["origin"], fallback: [0, 0, 0])
                fields["origin"] = SceneVector.value([origin[0] + centre.x, origin[1] + centre.y, origin[2] + centre.z])
            } else if is2D {
                // The presets write their objects for WE's 1920 × 1080 template; a layer goes to the
                // scene's centre, as a new image or text layer does.
                let origin = SceneVector.components(fields["origin"], fallback: [0, 0, 0])
                fields["origin"] = SceneVector.value([centre.x, centre.y, origin.count > 2 ? origin[2] : 0])
            }
            if fields["name"] == nil { fields["name"] = .string(variant.title) }
            return fields
        }
        session.addLayers(objects, actionName: L("Add \(variant.title)"))
    }
}

extension SceneLayerFactory.LightKind {
    /// The type as WE's inspector names it.
    var title: String {
        switch self {
        case .point: return L("Point Light")
        case .spot: return L("Spot Light")
        case .tube: return L("Tube Light")
        case .directional: return L("Directional Light")
        }
    }

    var symbol: String {
        switch self {
        case .point: return "lightbulb"
        case .spot: return "flashlight.on.fill"
        case .tube: return "light.cylindrical.ceiling"
        case .directional: return "sun.max"
        }
    }
}
