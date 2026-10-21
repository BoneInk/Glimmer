import Cocoa
import MetalKit
import CryptoKit
import OWESceneEditing

extension SceneMetalRenderer {
    /// Draws a puppet layer's mesh into its image (`puppetAlbedos`), posed by its animation layers
    /// this frame (docs/models-plan.md §4.3 M6, P2). Called only while the layer is visible, which
    /// is when WE evaluates its layers.
    func drawPuppet(_ puppet: ScenePuppetPlan, _ entry: PreparedLayer, frame: BuiltinFrameContext,
                    compositeSource: Bool, commandBuffer: MTLCommandBuffer) {
        guard let puppets, let source = entry.frames.first?.texture else { return }
        // Posed this frame by `advanceRigs`, before the scripts ran.
        let animator = puppetAnimator(entry.layer.id, puppet)
        // WE draws the posed mesh in the scene (docs/models-plan.md §2.13), with effects or without:
        // nothing clips it at the image's rect, so what the posed mesh draws into covers its posed
        // bounds and the quad grows with it. Without effects that is the image itself; with them,
        // the posed layout of their output (`posedEffectOutput`). As the image another layer
        // samples, the mesh stays in the image.
        let direct = entry.layer.weEffects.isEmpty && !compositeSource
        let canvas = compositeSource ? nil : puppets.canvas(puppet, layerID: entry.layer.id, pose: animator.pose)
        puppetCanvases[entry.layer.id] = canvas
        // With effects the mesh draws its bind pose, the image as its texture lays it out: that is
        // where the effects' masks are painted, and the posed mesh then lays their output out
        // (`posedEffectOutput`), as WE draws the layer's geometry last.
        var pose = animator.pose
        if !entry.layer.weEffects.isEmpty {
            // The texture channels are the image's: its effects see them. So are the parts'
            // opacities, which WE's mesh draw into the effects' buffer applies (`SKINNING_ALPHA`);
            // the parts' order matters where the posed mesh overlaps them (`posedEffectOutput`).
            pose = ScenePuppetPose.bind(boneCount: animator.pose.bones.count)
            pose.blendMap = animator.pose.blendMap
            pose.bonesAlpha = animator.pose.bonesAlpha
        }
        // A rig that rearranges an atlas: the editor paints the effects' masks over its texture as
        // stored, where its parts don't overlap, so the effects read the texture itself and the
        // posed mesh lays their output out by its texture coordinates.
        if !entry.layer.weEffects.isEmpty, !puppet.bindPoseIsTextureLayout {
            puppets.prepareLayer(puppet, layerID: entry.layer.id)
            puppetAlbedos[entry.layer.id] = nil
            return
        }

        // The mesh drawn in the scene culls by its winding there, which a mirroring world flips
        // (§5.17); drawn into the image for effects or for another layer, it isn't in the scene yet.
        let mirrored = direct && puppetIsMirrored(entry, camera: frame.camera)
        puppetAlbedos[entry.layer.id] = puppets.albedo(puppet, ScenePuppetRenderer.Draw(
            layerID: entry.layer.id, source: source, pose: pose, frame: frame,
            values: timelines.values,
            assetTexture: { [unowned self] key, source in self.effectAssetTexture(key: key, source: source) },
            canvas: direct ? canvas : nil, mirrored: mirrored),
            commandBuffer: commandBuffer)
        // Without effects WE draws the mesh in the scene through the layer's material, sampling
        // every texture at the mesh's coordinates: the quad draws with them laid out likewise.
        guard entry.layer.weEffects.isEmpty, let pass = entry.layer.imageMaterial?.pass else { return }
        var warped: [String: MTLTexture] = [:]
        for case let .asset(key, assetSource) in pass.textures.values {
            guard let texture = effectAssetTexture(key: key, source: assetSource) else { continue }
            warped[key] = puppets.warp(puppet, layerID: entry.layer.id, key: key, texture: texture,
                                       contentSize: assetSource.contentSize, pose: animator.pose, canvas: canvas,
                                       mirrored: mirrored, commandBuffer: commandBuffer)
        }
        puppetWarps[entry.layer.id] = warped
    }

    /// Whether a puppet layer shows its image mirrored on screen this frame: its world through the
    /// camera in a perspective scene, else its 2D world (`ScenePuppetRenderer.isMirrored`).
    private func puppetIsMirrored(_ entry: PreparedLayer, camera: SceneFrameCamera) -> Bool {
        if isPerspective {
            return ScenePuppetRenderer.isMirrored(world: world3D(entry.layer.id, in: spatial.transforms),
                                                  viewProjection: camera.viewProjection)
        }
        let linear = worldTransform(entry).linear
        return ScenePuppetRenderer.isMirrored(axisX: linear.columns.0, axisY: linear.columns.1)
    }

    /// A puppet's effect output (in its image's bind layout, `drawPuppet`) laid out by the posed
    /// mesh, which the layer then draws: WE draws a layer with effects through its geometry, the
    /// skinned mesh for a puppet, its triangles blended over each other by the layer's material,
    /// culled by their winding through `camera` (`puppetIsMirrored`). Anything else, or while the
    /// mesh can't be drawn, as it is.
    func posedEffectOutput(_ output: MTLTexture?, of entry: PreparedLayer, camera: SceneFrameCamera,
                           commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        guard let output, let puppet = entry.layer.puppet, let puppets, let animator = puppetAnimators[entry.layer.id],
              let source = entry.frames.first?.texture, source.width > 0, source.height > 0 else { return output }
        // The output keeps the source's layout, the image in the same share of its texels.
        let share = SIMD2(Float(puppet.contentPixels.x) / Float(source.width), Float(puppet.contentPixels.y) / Float(source.height))
        let content = SIMD2(Float(output.width), Float(output.height)) * simd_min(share, SIMD2(repeating: 1))
        // A rig whose effects ran on its texture (`drawPuppet`) has its parts faded here; any other
        // had them faded when its mesh drew the effects' input.
        return puppets.warp(puppet, layerID: entry.layer.id, key: "_effects", texture: output, contentSize: content,
                            pose: animator.pose, canvas: puppetCanvases[entry.layer.id], redraw: true, blended: true,
                            mirrored: puppetIsMirrored(entry, camera: camera), fades: !puppet.bindPoseIsTextureLayout,
                            commandBuffer: commandBuffer) ?? output
    }

    /// A script's call on a puppet's layers or bones. `setBoneTransform`'s matrix is in the scene;
    /// the rig keeps it in its model space (0x14020f350 multiplies by the object's inverse world).
    func performRigCommand(_ command: SceneScriptRigCommand, on id: String) {
        guard let index = layers.firstIndex(where: { $0.layer.id == id }),
              let puppet = layers[index].layer.puppet else {
            models?.perform(command, on: id)
            return
        }
        let animator = puppetAnimator(id, puppet)
        if case let .setWorld(bone, matrix) = command {
            animator.perform(.setWorld(bone: bone, matrix: ScenePuppetAttachments.matrix(worldTransform(layers[index])).inverse * matrix))
        } else {
            animator.perform(command)
        }
    }

    /// Bone attachments on puppets, as their animators last posed them.
    var puppetAttachments: ScenePuppetAttachments {
        ScenePuppetAttachments { [unowned self] id in
            guard let animator = self.puppetAnimators[id], let index = self.layerIndexByStateId[id],
                  let plan = self.layers[index].layer.puppet else { return nil }
            return (plan, animator)
        }
    }

    /// What a rope chain's step reads from the scene (`ScenePuppetRope.Environment`): `general`'s
    /// gravity and wind, the running time WE's wind noise reads (wrapped past 432000 s,
    /// 0x14017fcca) and the scene's width as the orthographic width [I: a perspective scene's
    /// is 0 in WE].
    private func currentRopeEnvironment() -> ScenePuppetRope.Environment {
        let physics = cameraGeneral.map { ScenePhysicsSettings($0, in: LiveSceneValueContext(wallpaper: wallpaperKey)) }
        return ScenePuppetRope.Environment(physics: physics ?? ScenePhysicsSettings(),
                                           time: Float(clock.time.truncatingRemainder(dividingBy: 432_000)),
                                           projectionWidth: sceneSize.x)
    }

    /// The layer's animator, made on first use.
    /// WE's object loop (0x1401891a0, at 0x14017fd26 in the frame): every object's update before
    /// the scripts' frame (0x1401802e5), so scripts read this frame's pose and get the layers'
    /// clip events (`animationEvent`) and ends (`addEndedCallback`) before their `update`, and
    /// their bone writes land on this frame's pose. A puppet updates hidden or not (0x1401fdf90
    /// tests only that it has a rig and layers, through 0x1402076e0); a model only while it and
    /// its parents are visible (0x14021c4d8), as its draw asks too. Without scripts nobody reads
    /// the events and ends, so they are dropped.
    func advanceRigs() {
        let delta = Float(clock.delta)
        var ropeEnvironment: ScenePuppetRope.Environment?
        let outlinesHitBoxes = puppetHitBoxes.isWanted
        var hitBoxes: [ScenePuppetHitBoxOutline] = []
        for entry in layers {
            guard let puppet = entry.layer.puppet else { continue }
            // Last frame's bones, for the `layerimage` emitters on it; none before its first update.
            if let existing = puppetAnimators[entry.layer.id] {
                emitterImages.willAdvance(puppet: entry.layer.id, worlds: existing.worlds)
            }
            let animator = puppetAnimator(entry.layer.id, puppet)
            if let rope = animator.rope {
                // The scene's gravity and wind, resolved once a frame for the rope chains.
                if ropeEnvironment == nil { ropeEnvironment = currentRopeEnvironment() }
                rope.environment = ropeEnvironment ?? ScenePuppetRope.Environment()
            }
            // Physics bones move in the scene: the image's world this frame, before the scripts'.
            let world = ScenePuppetAttachments.matrix(worldTransform(entry))
            animator.advance(delta: delta, values: timelines.values, objectWorld: world)
            if !scripts.isRunning {
                _ = animator.takeEnded()
                _ = animator.takeEvents()
            }
            if outlinesHitBoxes, scripts.isVisible(entry.layer.id) {
                hitBoxes += ScenePuppetHitBoxOutline.outlines(layerID: entry.layer.id, skeleton: puppet.skeleton,
                                                              boneWorlds: animator.worlds, world: world)
            }
        }
        if outlinesHitBoxes { puppetHitBoxes.publish(hitBoxes) }
        guard let models else { return }
        var frame = BuiltinFrameContext()
        frame.time = clock.time
        frame.frameTime = clock.delta
        for model in spatial.models where scripts.isVisible(model.id) {
            // `IModelLayer.rootmotion` as a script set it, else as authored.
            if let rootMotion = scripts.object(model.id)?.flag(.rootmotion) {
                models.animator(for: model.id)?.rootMotion = rootMotion
            }
            guard let plan = model.plan,
                  models.advance(model, plan: plan, frame: frame, values: timelines.values) != nil,
                  !scripts.isRunning, let animator = models.animator(for: model.id) else { continue }
            _ = animator.takeEnded()
            _ = animator.takeEvents()
        }
    }

    private func puppetAnimator(_ id: String, _ puppet: ScenePuppetPlan) -> ScenePuppetAnimator {

        if let animator = puppetAnimators[id] { return animator }
        let animator = puppet.makeAnimator(objectID: Int(id))
        puppetAnimators[id] = animator
        return animator
    }
}
