import Foundation

extension SceneScriptSceneDescriber {
    /// A Puppet Warp image's rig for scripts: model JSON → `puppet` `.mdl`, played by the object's
    /// `animationlayers`. Nil for an image without a rig.
    func rig(model path: String, animationLayers: SceneJSON?) -> SceneScriptRigDescription? {
        puppetImage(path, animationLayers: animationLayers).rig
    }

    /// A Puppet Warp image's rig (`rig(model:animationLayers:)`) and its hit boxes for the cursor
    /// pass (`SceneScriptCursorShape.puppet`), from one read of its `.mdl`.
    func puppetImage(_ path: String, animationLayers: SceneJSON?) -> (rig: SceneScriptRigDescription?, cursor: SceneScriptCursorShape?) {
        guard let modelData = file(path),
              case .object(let model)? = try? decodeTolerant(SceneJSON.self, from: modelData),
              case .string(let puppet)? = model["puppet"] else {
            // Optional: most images have no rig.
            return (nil, nil)
        }
        guard let mdl = readMDL(puppet, of: path) else { return (nil, nil) }
        return (rig(mdl, of: path, animationLayers: animationLayers), .puppet(mdl))
    }

    /// A model object's rig for scripts (docs/models-plan.md §2.8): its `.mdl`'s skeleton, clips and
    /// attachment points, played by the object's `animationlayers`. Scripts get its animation-layer
    /// and attachment API; models have no bone API (0x140227814). Nil for a model without bones.
    func rig(modelObject path: String, animationLayers: SceneJSON?) -> SceneScriptRigDescription? {
        modelObject(path, animationLayers: animationLayers).rig
    }

    /// A model object's rig (`rig(modelObject:animationLayers:)`) and what the cursor pass tests it
    /// with (`SceneScriptCursorShape`), from one read of its `.mdl`. Both nil when the file is
    /// missing or can't be read: WE's test has no model data then and never hits it.
    func modelObject(_ path: String, animationLayers: SceneJSON?) -> (rig: SceneScriptRigDescription?, cursor: SceneScriptCursorShape?) {
        guard let mdl = readMDL(path, of: path) else { return (nil, nil) }
        let description = rig(mdl, of: path, animationLayers: animationLayers)
        return (description.flatMap { $0.bones.isEmpty ? nil : $0 }, .model(mdl))
    }

    /// The rig of `.mdl` `path` (named by `owner`), played by `animationLayers`.
    private func rig(mdl path: String, of owner: String, animationLayers: SceneJSON?) -> SceneScriptRigDescription? {
        readMDL(path, of: owner).flatMap { rig($0, of: owner, animationLayers: animationLayers) }
    }

    /// `.mdl` `path` (named by `owner`), or nil (logged) when it is missing or can't be read.
    private func readMDL(_ path: String, of owner: String) -> MDLModel? {
        guard let data = file(path) else {
            OWELog.error(.script, "Rig \(path) of \(owner) is missing; its bone and animation-layer API is inert")
            return nil
        }
        do {
            return try MDLModel(data: data)
        } catch {
            OWELog.error(.script, "Rig \(path) of \(owner) can't be read; its bone and animation-layer API is inert: \(error)")
            return nil
        }
    }

    private func rig(_ mdl: MDLModel, of owner: String, animationLayers: SceneJSON?) -> SceneScriptRigDescription? {
        var layers: [WEAnimationLayer] = []
        if let animationLayers, let text = Self.jsonText(animationLayers) {
            do {
                layers = try JSONDecoder().decode([Failable<WEAnimationLayer>].self, from: Data(text.utf8)).compactMap(\.value)
            } catch {
                OWELog.error(.script, "The animation layers of \(owner) can't be read: \(error)")
            }
        }
        return SceneScriptRigDescription(model: mdl, layers: layers)
    }
}

/// One array element that may fail to decode on its own.
private struct Failable<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        do {
            value = try Value(from: decoder)
        } catch {
            // Element by element: the loader logs a bad layer when it builds the scene.
            value = nil
        }
    }
}
