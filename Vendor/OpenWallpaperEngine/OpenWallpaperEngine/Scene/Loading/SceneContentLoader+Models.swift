//
//  SceneContentLoader+Models.swift
//  Open Wallpaper Engine
//
//  Model objects' `.mdl`s and materials, and scripts' model data.
//

import SwiftUI
import CoreText
import CryptoKit
import OWESceneEditing

extension SceneContentLoader {
    /// The model objects' `.mdl`s and materials (`SceneModelBuilder`); without a translator none draws.
    /// Plans are kept by `.mdl` and skin for the content's life, so a script's clones share their
    /// original's (and its GPU buffers).
    func buildModels(_ models: [SceneModelObject], wallpaperDir: URL) -> [SceneModelObject] {
        OWEPhaseTiming.measure(.particlesModels) { buildModelsUntimed(models, wallpaperDir: wallpaperDir) }
    }

    private func buildModelsUntimed(_ models: [SceneModelObject], wallpaperDir: URL) -> [SceneModelObject] {
        guard !models.isEmpty, let translator = effectTranslator else { return models }
        let known = models.map { object -> SceneModelObject in
            var object = object
            object.plan = object.authored.path.flatMap { modelPlans["\($0)|\(object.authored.skin)"] }
            return object
        }
        if known.allSatisfy({ $0.plan != nil }) { return known }
        let materials = ModelMaterialPlanBuilder(
            translator: translator,
            readFile: { [weak self] path in self?.assetData(named: path, wallpaperDir: wallpaperDir) },
            loadTexture: { [weak self] name, path in self?.loadMetalTexture(named: name, materialDir: path, wallpaperDir: wallpaperDir) },
            sceneEngineCombos: sceneEngineCombos, isBuiltinShader: Self.isBuiltinShader)
        let package = pkgParser
        let built = SceneModelBuilder(materials: materials,
                                      loadModel: { try MDLModel.load(path: $0, package: package, directory: wallpaperDir) },
                                      wallpaperName: wallpaperDir.lastPathComponent).build(models)
        for object in built {
            guard let plan = object.plan, let path = object.authored.path else { continue }
            modelPlans["\(path)|\(object.authored.skin)"] = plan
        }
        return built
    }

    /// A model layer showing a script's model data (`thisScene.createModelData`, its token as the
    /// object's `model`); nil (logged) when the token names no data or no shape can draw.
    func buildScriptModel(_ object: SceneModelObject, token: Int, modelData: SceneScriptModelDataStore,
                                  wallpaperDir: URL) -> SceneModelObject? {
        guard let translator = effectTranslator else { return nil }
        guard let data = modelData.snapshot(token)?.data else {
            OWELog.error(.script, "createLayer: model data \(token) of \(object.name) doesn't exist")
            return nil
        }
        let materials = ModelMaterialPlanBuilder(
            translator: translator,
            readFile: { [weak self] path in self?.assetData(named: path, wallpaperDir: wallpaperDir) },
            loadTexture: { [weak self] name, path in self?.loadMetalTexture(named: name, materialDir: path, wallpaperDir: wallpaperDir) },
            sceneEngineCombos: sceneEngineCombos, isBuiltinShader: Self.isBuiltinShader)
        var built = object
        let planner = SceneScriptModelPlanBuilder(materials: materials, wallpaperName: wallpaperDir.lastPathComponent)
        let geometry = SceneScriptModelGeometry(store: modelData, token: token)
        // `replaceData` re-creates the model from its new shapes, on the script's thread
        // (`SceneScriptModelGeometry.dataReplaced`). The planner reads this model's assets and
        // caches, which the scene lock owns, so it plans under it as `createLayer` does.
        geometry.replan = { [weak self, weak geometry] data in
            guard let self, let geometry else { return nil }
            self.sceneLock.lock()
            defer { self.sceneLock.unlock() }
            return planner.plan(data, geometry: geometry, objectName: object.name)
        }
        built.plan = planner.plan(data, geometry: geometry, objectName: object.name)
        return built
    }
}
