//
//  SceneContentLoader+ObjectRebuild.swift
//  Open Wallpaper Engine
//
//  Rebuilding some objects alone (`rebuildObjects`), without the rest of the scene.
//

import SwiftUI
import CoreText
import CryptoKit
import OWESceneEditing

extension SceneContentLoader {
    // MARK: - Objects rebuilt alone

    /// Rebuilds objects `ids` off the render and main threads, on the content queue, and delivers
    /// them on the main queue (`rebuildObjects`); nil when they can't be rebuilt alone.
    func rebuildObjectsAsync(_ ids: Set<Int>, completion: @escaping (SceneObjectReplacement?) -> Void) {
        contentQueue.async { [weak self] in
            let replacement = self?.rebuildObjects(ids)
            DispatchQueue.main.async { completion(replacement) }
        }
    }

    /// Objects `ids` built again with the current user properties, for the renderer to swap in
    /// (`SceneObjectReplacement`): the layers and particle systems of image, text, shape and
    /// particle objects. Nil, for a whole-content rebuild instead, when one is anything else (a
    /// light, sound, model or camera, which the scene's own stages hold), isn't in the scene,
    /// builds nothing, emits from another layer's image, or changes the scene's particle budget
    /// factor. Takes the scene lock.
    func rebuildObjects(_ ids: Set<Int>) -> SceneObjectReplacement? {
        sceneLock.lock()
        defer { sceneLock.unlock() }
        defer { endBuildTextures() }
        guard !ids.isEmpty, let authoredScene = loadedScene, let wallpaperDir = loadedWallpaperDirectory,
              !Self.isVideoType(currentWallpaper.project.type) else { return nil }
        let valueContext = userValueContext
        var scene = resolvedScene(authoredScene)
        scene.objects = SceneObjectIdentity.assigningFallbackIDs(scene.objects)
        let sceneSize = metalSceneSize(for: scene)
        if scene.general.projection == .orthographicAuto { Self.centreFirstImage(of: &scene, sceneSize: sceneSize) }
        let authoredTransforms = SceneTransformHierarchy(objects: scene.objects)
        var layers: [SceneMetalLayer] = []
        var particleSystems: [SceneMetalParticleSystem] = []
        var capacities = particleCapacities
        let particleCache = ParticleDefinitionCache(sharesParts: sharesParticleDefinitions)
        defer { logParticleBuildTiming(particleCache.timing, wallpaperDir: wallpaperDir) }
        for id in ids.sorted() {
            guard let index = scene.objects.firstIndex(where: { $0.id == id }) else { return nil }
            let object = scene.objects[index]
            guard object.light == nil, object.sound == nil, object.model == nil, object.cameraLayer == nil else { return nil }
            var layer = bindingTable.building(.object(id)) {
                buildLayer(object, id: id, wallpaperDir: wallpaperDir, sceneSize: sceneSize, context: valueContext)
            }
            layer?.order = index
            let family = bindingTable.building(.object(id)) {
                buildParticleFamily(object, id: id, wallpaperDir: wallpaperDir, sceneSize: sceneSize,
                                    pixelUnits: Self.particlesUsePixelUnits(scene), transforms: authoredTransforms,
                                    cache: particleCache)
            }
            guard layer != nil || !family.isEmpty, !family.contains(where: { !$0.emitterImages.isEmpty }) else { return nil }
            if let layer { layers.append(layer) }
            let base = particleSystems.count
            for var system in family {
                system.order = index
                system.link?.parentIndex += base
                particleSystems.append(system)
            }
            capacities[id] = family.isEmpty ? nil : family.reduce(0) { $0 + ParticleBudget.capacity(of: $1) }
        }
        let limit = renderSettings.particleBudget.limit
        let scale = ParticleBudget.scale(authored: ParticleBudget.total(Array(capacities.values)), budget: limit)
        guard particleSystems.isEmpty || scale == particleBudgetScale else { return nil }
        particleCapacities = capacities
        for index in particleSystems.indices { particleSystems[index].budgetScale = particleBudgetScale }
        var transforms = authoredTransforms
        for layer in layers where layer.fillsScene {
            transforms.makeRoot(layer.id, local: SceneLocalTransform(origin: layer.position, scale: layer.scale, angle: layer.rotation))
        }
        let rebuilt = scene.objects.filter { $0.id.map(ids.contains) ?? false }
        var content = SceneMetalContent(size: sceneSize, layers: layers, particleSystems: particleSystems,
                                        bloom: bloomSettings(for: scene.general), transforms: transforms,
                                        camera: SceneCameraEffects(scene.general, in: valueContext),
                                        clearColor: scene.general.clearColor(in: valueContext), wallpaperKey: propertyStoreKey)
        content.motions = objectMotions(rebuilt, besides: layers, context: valueContext)
        content.engineCombos = sceneEngineCombos
        return SceneObjectReplacement(objectIDs: Set(ids.map(String.init)), content: content)
    }
}
