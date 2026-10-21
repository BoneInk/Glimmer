//
//  SceneContentLoader+EffectPlans.swift
//  Open Wallpaper Engine
//
//  Materials and effects planned through Wallpaper Engine's shaders.
//

import SwiftUI
import CoreText
import CryptoKit
import OWESceneEditing

extension SceneContentLoader {
    /// The image's own material through WE's shader; nil (logged when it's a failure) keeps the native draw.
    /// `prelit`: the layer has effects, so WE lights it before them (`ImageMaterialPlan.prelighting`).
    func buildImageMaterial(_ materialPath: String, object: WESceneObject, id: Int, wallpaperDir: URL,
                                    prelit: Bool = false) -> ImageMaterialPlan? {
        guard let translator = effectTranslator else { return nil }
        let builder = ImageMaterialPlanBuilder(
            translator: translator,
            readFile: { [weak self] path in self?.assetData(named: path, wallpaperDir: wallpaperDir) },
            loadTexture: { [weak self] name, path in self?.loadMetalTexture(named: name, materialDir: path, wallpaperDir: wallpaperDir) },
            sceneEngineCombos: sceneEngineCombos, blending: blendingOverride(for: object))
        do {
            return try builder.build(materialPath: materialPath, colorBlendMode: object.colorBlendMode,
                                     clampUVs: object.clampuvs, prelit: prelit)
        } catch {
            OWELog.error(.scene, "Image layer \(id) draws natively, material \(materialPath): \(error)")
            return nil
        }
    }

    /// A layer's own image composited with its `colorBlendMode` through WE's composite material
    /// (`ImageMaterialPlanBuilder.buildBlendComposite`); nil (logged) keeps the native draw.
    func buildBlendComposite(_ mode: Int, object: WESceneObject, id: Int, wallpaperDir: URL) -> ImageMaterialPlan? {
        guard let translator = effectTranslator else { return nil }
        let builder = ImageMaterialPlanBuilder(
            translator: translator,
            readFile: { [weak self] path in self?.assetData(named: path, wallpaperDir: wallpaperDir) },
            loadTexture: { [weak self] name, path in self?.loadMetalTexture(named: name, materialDir: path, wallpaperDir: wallpaperDir) },
            sceneEngineCombos: sceneEngineCombos, blending: blendingOverride(for: object))
        do {
            return try builder.buildBlendComposite(colorBlendMode: mode)
        } catch {
            OWELog.error(.scene, "Layer \(id) draws without its blend mode \(mode): \(error)")
            return nil
        }
    }

    /// A text object's `font` material (`materials/fonts/basefont.json`), whose `g_Texture0` is the
    /// renderer's rasterised text. WE's MSDF atlas (`msdf`, outline, drop shadow) isn't generated:
    /// CoreText's coverage stands in for it, as for plain fonts. nil (logged) keeps the native draw.
    func buildTextMaterial(_ object: WESceneObject, id: Int, wallpaperDir: URL) -> ImageMaterialPlan? {
        guard let translator = effectTranslator else { return nil }
        let builder = ImageMaterialPlanBuilder(
            translator: translator,
            readFile: { [weak self] path in self?.assetData(named: path, wallpaperDir: wallpaperDir) },
            loadTexture: { _, _ in nil },
            sceneEngineCombos: sceneEngineCombos)
        let materialPath = "materials/fonts/basefont.json"
        do {
            return try builder.buildText(materialPath: materialPath)
        } catch {
            OWELog.error(.scene, "Text layer \(id) draws natively, material \(materialPath): \(error)")
            return nil
        }
    }

    /// One of WE's post-processing chains (`SceneBloomChain`, `SceneHDRChain`) planned by `build`;
    /// nil, logged, when it can't be planned.
    func engineChain<Chain>(_ name: String, wallpaperDir: URL,
                                    _ build: (SceneEffectPlanBuilder) throws -> Chain) -> Chain? {
        guard let translator = effectTranslator else { return nil }
        let builder = SceneEffectPlanBuilder(
            translator: translator,
            readFile: { [weak self] path in self?.assetData(named: path, wallpaperDir: wallpaperDir) },
            loadTexture: { [weak self] name, materialPath in
                self?.loadMetalTexture(named: name, materialDir: materialPath, wallpaperDir: wallpaperDir)
            },
            sceneEngineCombos: sceneEngineCombos)
        do {
            return try build(builder)
        } catch {
            OWELog.error(.scene, "\(name) can't be planned; the scene draws without it: \(error)")
            return nil
        }
    }

    /// WE's volumetric lights (`SceneVolumetricsPlan`); nil, logged, when they can't be planned.
    func volumetricsPlan(_ lights: [SceneLightObject], wallpaperDir: URL) -> SceneVolumetricsPlan? {
        guard lights.contains(where: \.light.castVolumetrics), let translator = effectTranslator else { return nil }
        let builder = SceneEffectPlanBuilder(
            translator: translator,
            readFile: { [weak self] path in self?.assetData(named: path, wallpaperDir: wallpaperDir) },
            loadTexture: { [weak self] name, materialPath in
                self?.loadMetalTexture(named: name, materialDir: materialPath, wallpaperDir: wallpaperDir)
            },
            sceneEngineCombos: sceneEngineCombos)
        do {
            return try SceneVolumetricsPlan.build(lights: lights, settings: renderSettings, builder: builder)
        } catch {
            OWELog.error(.scene, "WE's volumetrics can't be planned; the scene draws without them: \(error)")
            return nil
        }
    }

    /// Plans each visible effect for Wallpaper Engine's own shaders. An effect that can't be
    /// planned (no toolchain, sources missing) is left out, with the reason logged.
    func buildEffectPlans(_ effects: [WEObjectEffect], objectID: Int, wallpaperDir: URL,
                                  objectCombos: [String: Int] = [:]) -> (plans: [SceneEffectPlan], handled: Set<Int>) {
        guard !effects.isEmpty, let translator = effectTranslator else { return ([], []) }
        var builder = SceneEffectPlanBuilder(
            translator: translator,
            readFile: { [weak self] path in self?.assetData(named: path, wallpaperDir: wallpaperDir) },
            loadTexture: { [weak self] name, materialPath in
                self?.loadMetalTexture(named: name, materialDir: materialPath, wallpaperDir: wallpaperDir)
            },
            sceneEngineCombos: sceneEngineCombos,
            readWallpaperFile: { [weak self] path in
                // The editor's files of the wallpaper (an effect made in the Wallpaper Editor) are its own.
                guard let self, let data = self.editorAssetsLock.withLock({ self.editorAssets[path] })
                        ?? self.wallpaperData(named: path, wallpaperDir: wallpaperDir) else { return nil }
                return self.bindingTable.resolvedData(data, path: path, properties: self.userProperty)
            })
        builder.objectCombos = objectCombos
        var plans: [SceneEffectPlan] = []
        var handled = Set<Int>()
        let storeKey = propertyStoreKey
        for (index, effect) in effects.enumerated() {
            // The app's own switch removes an effect; WE's `visible` only hides it, so a script or a
            // user property can show it again.
            let enabled = userProperty(
                sceneAuthoredEffectEnabledKey(objectID: objectID, effectIndex: index)) != "false"
            guard enabled else {
                handled.insert(index)
                continue
            }
            do {
                var plan = try builder.build(effect, owner: (objectID, index), overrides: { key in
                    SceneEffectOverride.stored(
                        property: sceneAuthoredEffectOverrideKey(objectID: objectID, effectIndex: index, parameter: key),
                        lookup: { WallpaperServices.shared.userPropertyString($0, wallpaper: storeKey) })
                })
                plan.effectIndex = index
                plan.visible = isEffectVisible(effect)
                plans.append(plan)
                handled.insert(index)
            } catch {
                OWELog.error(.scene, "Effect \(effect.file) on object \(objectID) can't use WE shaders: \(error)")
            }
        }
        return (plans, handled)
    }

    /// Scene Edit / Export's blending for the object's material (`sceneObjectBlendingKey`); nil
    /// when it has none, or one its kind of layer doesn't draw with, which keeps the material's.
    func blendingOverride(for object: WESceneObject) -> WEMaterialBlending? {
        guard let objectID = object.id, let value = userProperty(sceneObjectBlendingKey(objectID: objectID)) else { return nil }
        let supported = object.particle != nil ? WEMaterialBlending.particleSystem : WEMaterialBlending.imageLayer
        guard let blending = WEMaterialBlending(authored: value), supported.contains(blending) else {
            OWELog.error(.scene, "Object \(objectID) keeps its material's blending: \"\(value)\" isn't one it draws with")
            return nil
        }
        return blending
    }
}
