import Foundation

/// Makes each model object drawable (docs/models-plan.md §2.6, §4.3 M5): loads its `.mdl`
/// (`MDLModel.load`), and plans every mesh's material for the object's `skin`
/// (`materials[min(skin, M − 1)]`, 0x140224dc4) with WE's model combos (`ModelMeshCombos`)
/// through `ModelMaterialPlanBuilder`. Objects sharing a `.mdl` and skin share one plan, and a
/// material shared by meshes with the same combos is planned once. What can't be drawn is logged
/// once per content: a `.mdl` that doesn't load, a mesh whose material doesn't translate.
struct SceneModelBuilder {
    let materials: ModelMaterialPlanBuilder
    /// Loads a `.mdl` of the wallpaper (its folder or package, then WE's assets).
    let loadModel: (String) throws -> MDLModel
    /// For log lines.
    var wallpaperName = ""

    /// `models` with their `plan`s.
    func build(_ models: [SceneModelObject]) -> [SceneModelObject] {
        var loaded: [String: Result<MDLModel, Error>] = [:]
        var plans: [String: SceneModelPlan?] = [:]
        var materialPlans: [MaterialKey: ModelMaterialPlan?] = [:]
        return models.map { object in
            var object = object
            guard let path = object.authored.path else {
                OWELog.error(.scene, "\(wallpaperName): model object \(object.name) names no .mdl (\(object.authored.source)); "
                             + "only a path is loaded")
                return object
            }
            let key = "\(path)|\(object.authored.skin)"
            if let plan = plans[key] {
                object.plan = plan
                return object
            }
            if loaded[path] == nil {
                loaded[path] = Result { try loadModel(path) }
                if case .failure(let error) = loaded[path]! {
                    OWELog.error(.scene, "\(wallpaperName): model \(path) of \(object.name) can't be loaded: \(error)")
                }
            }
            guard case .success(let model) = loaded[path]! else {
                plans[key] = .some(nil)
                return object
            }
            let plan = self.plan(model, path: path, skin: object.authored.skin, materials: &materialPlans)
            plans[key] = plan
            object.plan = plan
            return object
        }
    }

    private struct MaterialKey: Hashable {
        var path: String
        var combos: ModelMeshCombos
    }

    /// The model's plan; nil (logged) when no mesh can draw.
    private func plan(_ model: MDLModel, path: String, skin: Int,
                      materials cache: inout [MaterialKey: ModelMaterialPlan?]) -> SceneModelPlan? {
        let bones = model.skeleton?.bones.count ?? 0
        let morphed = Set((model.morphTargets ?? []).filter { !$0.targets.isEmpty }.map(\.mesh))
        var meshes: [SceneModelPlan.Mesh] = []
        for (index, mesh) in model.meshes.enumerated() {
            guard mesh.vertexCount > 0, mesh.indexCount > 0, !mesh.materials.isEmpty else { continue }
            let materialPath = mesh.materials[min(max(skin, 0), mesh.materials.count - 1)]
            let key = MaterialKey(path: materialPath,
                                  combos: ModelMeshCombos(mesh: mesh, bones: bones, morphTargets: morphed.contains(index)))
            if cache[key] == nil {
                do {
                    cache[key] = try materials.build(materialPath: materialPath, mesh: key.combos)
                } catch {
                    OWELog.error(.scene, "\(wallpaperName): model \(path) mesh \(index) doesn't draw, material \(materialPath): \(error)")
                    cache[key] = .some(nil)
                }
            }
            guard let material = cache[key] ?? nil else { continue }
            meshes.append(SceneModelPlan.Mesh(index: index, material: material, format: mesh.format,
                                              vertexData: mesh.vertexData, indexData: mesh.indexData,
                                              usesUInt32Indices: mesh.usesUInt32Indices, indexCount: mesh.indexCount,
                                              bounds: key.combos.skinning || key.combos.morphing ? nil : mesh.bounds,
                                              deforms: key.combos.skinning || key.combos.morphing))
        }
        guard !meshes.isEmpty else {
            OWELog.error(.scene, "\(wallpaperName): model \(path) has no mesh that draws")
            return nil
        }
        return SceneModelPlan(path: path, meshes: meshes, bounds: model.bounds, skeleton: model.skeleton,
                              clips: model.animations ?? [], attachments: model.attachments ?? [],
                              morphs: SceneModelMorphs(model: model))
    }
}
