import Cocoa
import MetalKit
import CryptoKit
import OWESceneEditing

extension SceneMetalRenderer {
    // MARK: - Depth, draw order and 3D placement (docs/models-plan.md §2.4)

    /// Gives the pass WE's depth buffer (`SceneDepthBuffer`), cleared to the far depth, and sets
    /// `sceneDepthFormat` for this frame's pipelines: a perspective scene's, and an orthographic
    /// one's with model objects, whose models, and whatever tests depth, then test as in WE (MG6).
    /// WE's frame buffer always has depth (0x14017f59c); an orthographic scene without models
    /// keeps none here, which draws the same while every object lies at z = 0 [I].
    func attachSceneDepth(to pass: MTLRenderPassDescriptor, scene: MTLTexture) {
        sceneDepthFormat = .invalid
        guard isPerspective || !spatial.models.isEmpty, depthStates != nil,
              layerPipelines.pipelines(for: scene.pixelFormat, sampleCount: sceneSampleCount,
                                       depthFormat: SceneDepthStates.format) != nil,
              depthBuffer.prepare(width: scene.width, height: scene.height, sampleCount: sceneSampleCount) else {
            if depthBuffer.texture != nil { depthBuffer.releaseAll() }
            return
        }
        sceneDepthFormat = SceneDepthStates.format
        depthBuffer.attach(to: pass, clear: true)
    }

    /// Where a layer's quad lands through a 3D camera this frame: every layer of a perspective
    /// scene but a fullscreen one (WE draws those in screen space: `passthrough` without
    /// `TRANSFORM`), and a `perspective` layer of an orthographic scene through its temporary
    /// camera (0x1401e5b60), moved by the parallax and shake the 2D path moves it by (the camera
    /// keeps the view's offset). Nil for the rest, which draw in the scene's plane.
    func layerPlacement(_ entry: PreparedLayer, size: SIMD2<Float>, musicSyncLevel: Double, motion: CameraMotion,
                        camera: SceneFrameCamera) -> SceneLayerPlacement? {
        guard !entry.layer.fillsScene else { return nil }
        let offset = SceneAlignment.centerOffset(alignment(entry), size: size)
        if isPerspective {
            let world = layerWorld3D(entry, in: spatial.transforms, musicSyncLevel: musicSyncLevel)
            return SceneLayerPlacement(world: world, size: size, offset: offset, camera: camera)
        }
        guard perspective(entry.layer.id, authored: entry.layer.perspective) else { return nil }
        var world = layerWorld3D(entry, in: spatial.transforms, musicSyncLevel: musicSyncLevel)
        let shift = parallaxOffset(entry, local: evaluatedLocal(entry), motion: motion) - motion.shake
        world.columns.3 += SIMD4(shift.x, shift.y, 0, 0)
        var temporary = SceneLayerPlacement.perspectiveLayerCamera(sceneSize: sceneSize, fov: Float(spatial.camera.sceneFov))
        temporary.projection = frameZoom.projection(temporary.projection)
        return SceneLayerPlacement(world: world, size: size, offset: offset, camera: temporary)
    }

    /// A layer's `alignment` this frame: as a script set it (`IImageLayer.alignment`), else as
    /// authored. A fullscreen layer has none.
    func alignment(_ entry: PreparedLayer) -> String? {
        guard !entry.layer.fillsScene else { return entry.layer.alignment }
        return scripts.object(entry.layer.id)?.strings[.alignment] ?? entry.layer.alignment
    }

    /// An object's `perspective` this frame (`IEffectLayer.perspective`, `IModelLayer.perspective`):
    /// as a script set it, else `authored`.
    func perspective(_ id: String, authored: Bool) -> Bool {
        scripts.object(id)?.flag(.perspective) ?? authored
    }

    /// A layer's world matrix with its music sync (a video's zoom and tilt, applied to its own
    /// scale and `angles.z` as the 2D path applies them).
    private func layerWorld3D(_ entry: PreparedLayer, in hierarchy: SceneTransformHierarchy3D,
                              musicSyncLevel: Double) -> simd_float4x4 {
        let id = entry.layer.id
        guard let sync = entry.layer.musicSync else { return world3D(id, in: hierarchy) }
        var own = live3D(id, in: hierarchy) ?? hierarchy.nodes[id]?.local ?? .identity
        let zoom = 1 + sync.zoomAmount * Float(musicSyncLevel)
        own.scale *= SIMD3(zoom, zoom, 1)
        own.angles.z += sync.tiltAmount * Float(musicSyncLevel) * .pi / 180
        return hierarchy.world(of: id, local: own, live: { [unowned self] in self.live3D($0, in: hierarchy) })
    }

    /// An object's world matrix this frame (M3's hierarchy): its own and its ancestors' live
    /// transforms, parents first.
    func world3D(_ id: String, in hierarchy: SceneTransformHierarchy3D) -> simd_float4x4 {
        hierarchy.world(of: id, local: live3D(id, in: hierarchy), live: { [unowned self] in self.live3D($0, in: hierarchy) },
                        attachments: SceneAttachmentProviders(providers: [models?.attachments as SceneAttachmentProviding?, puppetAttachments].compactMap { $0 }))
    }

    /// An object's world matrix where it is drawn: in an orthographic scene, in the zoom's drawn
    /// space (`SceneOrthographicZoom.space`), where the lights it is lit by are packed too;
    /// `world3D` (WE's world, what scripts see) elsewhere.
    func drawnWorld3D(_ id: String) -> simd_float4x4 {
        frameZoom.space * world3D(id, in: spatial.transforms)
    }

    /// The model renderer (`SceneModelRenderer`), when that is what draws the models.
    var models: SceneModelRenderer? { modelDrawing as? SceneModelRenderer }

    /// `layerCompositeOrder`, made from the layers' effects when `layers` changed.
    func compositeOrder() -> SceneLayerCompositeOrder {
        if let layerCompositeOrder { return layerCompositeOrder }
        let order = SceneLayerCompositeOrder(layers: layers.map { entry in
            (entry.layer.id, entry.layer.weEffects.reduce(into: Set<String>()) { $0.formUnion($1.compositeLayerIDs) })
        }, readingScene: Set(layers.filter(\.layer.readsScene).map(\.layer.id)))
        layerCompositeOrder = order
        return order
    }

    /// A text layer's composite without effects: its text in its colour, one pixel a scene unit,
    /// as WE draws it into a buffer of its size (effects would run there, `SceneTextRasterScale`).
    func compositeText(_ entry: PreparedLayer) -> MTLTexture? {
        guard let authored = entry.layer.text else { return nil }
        let scripted = scripts.text(authored, of: entry.layer.id)
        return makeTextFrame(scripted.text, value: scripted.value, pointSize: scripted.pointSize, boxSize: layerBaseSize(entry),
                             pixelsPerUnit: 1, layerID: entry.layer.id, fill: textFill(entry))?.frame.texture
    }

    /// An object's own 3D transform this frame (`SceneObjectMotion.local3D`: scripts, then
    /// timelines, then authored moved by the user bindings), evaluated once per frame; nil for an
    /// object without a motion, whose authored node stands. An object a script created has no
    /// authored node: its 2D transform stands in.
    private func live3D(_ id: String, in hierarchy: SceneTransformHierarchy3D) -> SceneLocalTransform3D? {
        if let cached = frameLocals3D[id] { return cached }
        guard let motion = layerIndexByStateId[id].map({ layers[$0].motion }) ?? objectMotions[id] else { return nil }
        let authored = hierarchy.nodes[id]?.local ?? SceneLocalTransform3D(objectLocal(motion, id: id))
        let local = motion.local3D(authored: authored, animation: timelines.object(id), script: scripts.object(id))
        frameLocals3D[id] = local
        return local
    }

    /// The depth and cull state a layer draws with where the pass has depth: a text object's (its
    /// `depthtest`, `SceneRasterState.text`), else its material's first pass; a layer without a
    /// material (composition and shape layers) neither tests nor writes.
    func layerRaster(_ entry: PreparedLayer) -> SceneRasterState {
        if entry.layer.text != nil { return .text(depthTest: spatial.depthTest(of: entry.layer.id) ?? false) }
        return entry.layer.imageMaterial?.raster ?? .disabled
    }

    /// A particle system drawn through a perspective scene's camera (docs/models-plan.md §2.12):
    /// the camera, and the matrix from the scene plane the system is simulated in (its object's 2D
    /// transform) to where its 3D world matrix puts it. Nil in an orthographic scene.
    func particlePlacement(_ system: ParticleSystemRuntime,
                           camera: SceneFrameCamera) -> ParticleMaterialUniforms.Placement? {
        guard isPerspective else {
            // A `perspective` system (flag 4) of an orthographic scene: WE pushes the temporary
            // camera a perspective layer gets (0x140236761 → 0x1401e5b60) and keeps g_EyePosition.
            guard system.configuration.perspective else { return nil }
            // Its emitter is already in the zoom's drawn plane (`emitterWorld`), so the camera
            // isn't zoomed again.
            var temporary = SceneLayerPlacement.perspectiveLayerCamera(sceneSize: sceneSize, fov: Float(spatial.camera.sceneFov))
            temporary.eye = SIMD3(sceneSize.x / 2, sceneSize.y / 2, ParticleMaterialUniforms.eyeDistance)
            return ParticleMaterialUniforms.Placement(camera: temporary)
        }
        return ParticleMaterialUniforms.Placement(camera: camera, model: particleSpaceModel(system))
    }

    /// The matrix from the space a system's particles are simulated in (the scene plane its
    /// object's 2D transform places them in, and their depth) to where its 3D world matrix puts
    /// them, through a child's links in depth (`ParticleLinkSpace`): identity in an orthographic
    /// scene, or when the two agree.
    private func particleSpaceModel(_ system: ParticleSystemRuntime) -> simd_float4x4 {
        guard isPerspective, let id = particleObjectID(system) else { return matrix_identity_float4x4 }
        let planar = transforms.world(of: id, live: { [self] id in liveLocal(id) }, attachments: puppetAttachments.affine)
        let x = planar.linear.columns.0, y = planar.linear.columns.1, t = planar.translation
        let embedded = simd_float4x4(columns: (SIMD4<Float>(x.x, x.y, 0, 0), SIMD4<Float>(y.x, y.y, 0, 0),
                                               SIMD4<Float>(0, 0, 1, 0), SIMD4<Float>(t.x, t.y, 0, 1)))
        guard abs(simd_determinant(planar.linear)) > 1e-12 else { return matrix_identity_float4x4 }
        return world3D(id, in: spatial.transforms) * system.configuration.linkSpace * embedded.inverse
    }

    /// The capsules a `collisionmodel` operator of `system` collides with (docs/models-plan.md
    /// §2.12): model object `id`'s bones as last posed (its bind pose before its first frame) or
    /// its box, through its world matrix, in the space the system's particles are simulated in.
    /// A Puppet Warp image is one too: WE reads its rig's `.mdl` and its posed bones (puppet+0x2c8,
    /// 0x1401d4a69) as a model's, in the image's model space (its pixels, centred, y up).
    func particleCapsules(_ id: String, for system: ParticleSystemRuntime) -> [ParticleCapsule] {
        let space = particleSpaceModel(system)
        let toParticles = abs(space.determinant) > 1e-12 ? space.inverse : matrix_identity_float4x4
        if let plan = spatial.models.first(where: { $0.id == id })?.plan {
            return ParticleCapsule.capsules(boneVectors: plan.skeleton?.boneVectors,
                                            boneWorlds: models?.animator(for: id)?.worlds ?? [], bounds: plan.bounds,
                                            world: toParticles * drawnWorld3D(id))
        }
        if let index = layerIndexByStateId[id], let puppet = layers[index].layer.puppet {
            return ParticleCapsule.capsules(boneVectors: puppet.skeleton.boneVectors,
                                            boneWorlds: puppetAnimators[id]?.worlds ?? [],
                                            bounds: puppet.bounds ?? MDLBounds(min: .zero, max: .zero),
                                            world: toParticles * drawnWorld3D(id))
        }
        if reportedCollisionTargets.insert(id).inserted {
            OWELog.error(.scene, "Particle collisionmodel: object \(id) is neither a drawable model nor a Puppet Warp image; its particles don't collide with it")
        }
        return []
    }

    /// Draws model object `index` (`SceneSpatialContent.models`) through `modelDrawing` at its
    /// place in the object loop, unless it is hidden.
    func drawModel(_ index: Int, frame: BuiltinFrameContext, pixelFormat: MTLPixelFormat,
                   encoder: MTLRenderCommandEncoder, commandBuffer: MTLCommandBuffer) {
        guard let modelDrawing, spatial.models.indices.contains(index) else { return }
        let model = spatial.models[index]
        guard scripts.isVisible(model.id) else { return }
        modelDrawing.draw(model, SceneModelDraw(
            world: drawnWorld3D(model.id), camera: modelCamera(model, frame: frame), frame: frame,
            values: timelines.values, pixelFormat: pixelFormat, sampleCount: sceneSampleCount, depth: frameDepth,
            mipMappedFrameBuffer: mipMappedTarget,
            assetTexture: { [unowned self] key, source in self.effectAssetTexture(key: key, source: source) },
            layerComposite: { [unowned self] id in self.layerComposites[id] }, shadowAtlas: frameShadowAtlas,
            planarReflection: frameReflection),
            encoder: encoder, commandBuffer: commandBuffer)
        encoder.setRenderPipelineState(renderPipeline)
    }

    /// The camera model object `model` draws through: the frame's, or in an orthographic scene a
    /// `perspective` model's temporary camera, a perspective layer's (WE's model draw tests the
    /// object's flag 0x80 and pushes it, 0x140222770 → 0x1401e5b60).
    private func modelCamera(_ model: SceneModelObject, frame: BuiltinFrameContext) -> SceneFrameCamera {
        guard !isPerspective, perspective(model.id, authored: model.perspective) else { return frame.camera }
        var temporary = SceneLayerPlacement.perspectiveLayerCamera(sceneSize: sceneSize, fov: Float(spatial.camera.sceneFov))
        temporary.projection = frameZoom.projection(temporary.projection)
        return temporary
    }

    /// This frame's object loop: the layers and models in draw order, each with the barrier below
    /// which the particle systems are drawn before it, and the order and keys of the systems.
    struct DrawSequence {
        var items: [(item: SceneDrawItem, barrier: Int)] = []
        /// `batches`' indices in draw order, and each one's key.
        var batchOrder: [Int] = []
        var batchKeys: [Int] = []
    }

    /// WE's object loop (0x14018aac0): scene order (or the order scripts set) keeps each layer's
    /// particle barrier and each system's scene index; a model goes before the first layer
    /// authored after it. `customsortorder` and `transparentsorting` then sort the whole list
    /// (`SceneDrawOrderMode.ordered`), and each object's position becomes its key.
    func drawSequence(batches: [ParticleSystemRuntime], forward: SIMD3<Float>) -> DrawSequence {
        // Each model goes before the first layer authored after it, models before one layer in scene order.
        let layerOrders = layers.map(\.layer.order)
        var modelsBefore = [[Int]](repeating: [], count: layers.count + 1)
        if modelDrawing != nil {
            for (index, model) in spatial.models.enumerated() {
                modelsBefore[layerOrders.firstIndex { $0 > model.order } ?? layers.count].append(index)
            }
        }
        var items: [(item: SceneDrawItem, barrier: Int)] = []
        for position in 0...layers.count {
            items += modelsBefore[position].map { (item: SceneDrawItem.model($0), barrier: spatial.models[$0].order) }
            if position < layers.count { items.append((.layer(position), layers[position].particleBarrier)) }
        }
        let keys = batches.map(\.configuration.order)
        guard spatial.drawOrder.reorders else {
            return DrawSequence(items: items, batchOrder: Array(batches.indices), batchKeys: keys)
        }
        var list: [SceneDrawItem] = []
        var next = 0
        for (item, barrier) in items {
            while next < batches.count, keys[next] < barrier {
                list.append(.particles(next))
                next += 1
            }
            list.append(item)
        }
        list += (next..<batches.count).map { SceneDrawItem.particles($0) }
        let ordered = spatial.drawOrder.ordered(list.map { drawEntry($0, batches: batches) }, forward: forward)
        var sequence = DrawSequence()
        for (position, item) in ordered.enumerated() {
            if case .particles(let batch) = item {
                sequence.batchOrder.append(batch)
                sequence.batchKeys.append(position)
            } else {
                sequence.items.append((item, position))
            }
        }
        return sequence
    }

    /// An object as the draw-order modes see it (`SceneDrawEntry`).
    private func drawEntry(_ item: SceneDrawItem, batches: [ParticleSystemRuntime]) -> SceneDrawEntry {
        var entry = SceneDrawEntry(item: item)
        let id: String?
        switch item {
        case .layer(let index):
            let layer = layers[index].layer
            id = layer.id
            entry.translucent = layer.text != nil || SceneDrawEntry.imageIsTranslucent(
                blending: layer.imageMaterial?.pass.blending, passthrough: layer.sceneInput, solidLayer: layer.solidFill != nil)
            entry.drawsLast = layer.fillsScene
        case .particles(let index):
            id = particleObjectID(batches[index])
            entry.translucent = true
        case .model(let index):
            let model = spatial.models[index]
            id = model.id
            entry.translucent = modelDrawing?.isTranslucent(model) ?? false
        }
        guard let id else { return entry }
        entry.sortOrder = spatial.sortOrder(of: id)
        // Only a perspective scene sorts by origin; its objects live in `spatial.transforms`.
        if spatial.drawOrder.splitsTranslucent {
            entry.origin = live3D(id, in: spatial.transforms)?.origin ?? spatial.transforms.nodes[id]?.local.origin ?? .zero
        }
        return entry
    }
}
