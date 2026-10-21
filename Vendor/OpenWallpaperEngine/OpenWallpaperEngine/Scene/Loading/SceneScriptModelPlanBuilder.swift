import Foundation

/// Plans a model layer showing a script's model data (`createLayer({model: modelData})`,
/// `SceneScriptModelData`): each shape is a mesh through its material's first pass, as a `.mdl`
/// mesh's would be (`ModelMaterialPlanBuilder`, no bones or morph targets), with the data's box. The
/// plan's `geometry` hands the renderer what `applyData` changes. A shape whose material doesn't
/// plan is logged and left out.
struct SceneScriptModelPlanBuilder {
    let materials: ModelMaterialPlanBuilder
    /// For log lines.
    var wallpaperName = ""

    func plan(_ data: SceneScriptModelData, geometry: SceneModelGeometrySource, objectName: String) -> SceneModelPlan? {
        let combos = ModelMeshCombos(skinning: false, boneCount: ModelMeshCombos.boneCount(0))
        var meshes: [SceneModelPlan.Mesh] = []
        for (index, shape) in data.shapes.enumerated() where shape.vertexCount > 0 && shape.indexCount > 0 {
            guard let material = material(shape.materialPaths, combos: combos, shape: index, objectName: objectName) else { continue }
            meshes.append(SceneModelPlan.Mesh(index: index, material: material, format: shape.format,
                                              vertexData: shape.vertices, indexData: shape.drawnIndices,
                                              usesUInt32Indices: shape.drawsUInt32Indices, indexCount: shape.indexCount))
        }
        guard !meshes.isEmpty else {
            OWELog.error(.scene, "\(wallpaperName): the model data of \(objectName) has no shape that draws")
            return nil
        }
        return SceneModelPlan(path: "model data (\(objectName))", meshes: meshes, bounds: data.bounds, skeleton: nil,
                              geometry: geometry)
    }

    /// The first of `paths` that plans; nil (logged) when none does.
    private func material(_ paths: [String], combos: ModelMeshCombos, shape: Int, objectName: String) -> ModelMaterialPlan? {
        var failures: [String] = []
        for path in paths {
            do {
                return try materials.build(materialPath: path, mesh: combos)
            } catch ModelMaterialPlanError.missing(let missing) where missing == path {
                failures.append("\(path) missing")
            } catch {
                failures.append("\(path): \(error)")
                break
            }
        }
        OWELog.error(.scene, "\(wallpaperName): model data shape \(shape) of \(objectName) doesn't draw: "
                     + failures.joined(separator: "; "))
        return nil
    }
}
