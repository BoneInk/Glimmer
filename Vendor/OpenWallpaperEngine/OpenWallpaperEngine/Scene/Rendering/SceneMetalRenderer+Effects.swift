import Cocoa
import MetalKit
import CryptoKit
import OWESceneEditing

extension SceneMetalRenderer {
    func runEffects(_ entry: PreparedLayer, draw: LayerDraw, input: MTLTexture, snapshot: MTLTexture?,
                    frame: BuiltinFrameContext, commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        guard let effectGraph, !entry.layer.weEffects.isEmpty else { return nil }
        var context = effectContext(entry, draw: draw, input: input, snapshot: snapshot, frame: frame)
        let lit = prelit(entry, draw: draw, input: input, snapshot: snapshot, frame: frame, commandBuffer: commandBuffer)
        if lit != nil {
            // The prelit image is redrawn into the same texture every frame (its lights, the
            // reflection it samples): a new version, so no kept chain output outlives it.
            prelitVersion &+= 1
            context.inputVersion = prelitVersion
        }
        return effectGraph.apply(entry.layer.weEffects, to: lit ?? input,
                                 layerID: entry.layer.id, context: context, commandBuffer: commandBuffer)
    }

    /// Runs a layer's effects up to their last pass, which `encodeLayer` then draws into the scene
    /// through the layer's quad and material blending, as WE draws a layer's last effect pass
    /// (`EffectGraphRenderer.lastScenePass`): the shader runs once per pixel of the screen, not of
    /// the layer's buffer (docs/test-risks.md FX2). The chain starts from WE's base pass, the layer's
    /// material drawn into its buffer with the layer's colour, alpha and brightness
    /// (`ImageMaterialRenderer.base`), which the last pass then carries into the scene; a solid
    /// layer's base is its `flat` fill with the layer's alpha (`solidSceneBase`). nil where the
    /// effects composite through a buffer (`lastPassDrawsIntoScene`), or while a pipeline compiles.
    func runEffectsDrawingLastPass(_ entry: PreparedLayer, draw: LayerDraw, input: MTLTexture, compositeSource: Bool,
                                   sceneFormat: MTLPixelFormat, frame: BuiltinFrameContext,
                                   commandBuffer: MTLCommandBuffer) -> EffectGraphRenderer.DrawnLastPass? {
        guard let effectGraph, let base = lastPassDrawsIntoScene(entry, compositeSource: compositeSource) else { return nil }
        var context = effectContext(entry, draw: draw, input: input, snapshot: nil, frame: frame)
        let format = context.frameBufferFormat
        let target = lastPassPlacement(blending: base.blending, draw: draw, image: nil, sceneFormat: sceneFormat)
        guard effectGraph.scenePassIsReady(entry.layer.weEffects, hidden: context.hiddenEffects, scene: target) else { return nil }
        let baseTexture: MTLTexture
        switch base {
        case .material(let plan):
            guard let imageMaterials, imageMaterials.baseIsReady(plan, layerID: entry.layer.id, format: format),
                  let drawn = imageMaterials.base(plan, materialDraw(entry, draw, texture: input, frame: frame),
                                                  inputVersion: context.inputVersion, format: format,
                                                  commandBuffer: commandBuffer) else { return nil }
            baseTexture = drawn.texture
            context.inputVersion = drawn.version
        case .solid:
            guard let fill = solidSceneBase(entry.layer, alpha: draw.opacity, commandBuffer: commandBuffer) else { return nil }
            baseTexture = fill.texture
            context.inputVersion = fill.version
        }
        return effectGraph.applyDrawingLastPass(entry.layer.weEffects, to: baseTexture, layerID: entry.layer.id,
                                                context: context, commandBuffer: commandBuffer)
    }

    /// What a layer's last effect pass draws over in the layer's buffer before it goes into the
    /// scene (WE's base pass), and the blending it draws into the scene with (the layer material's).
    private enum LastPassBase {
        /// The layer's material drawn into its buffer (`ImageMaterialRenderer.base`).
        case material(ImageMaterialPlan)
        /// A solid layer's `flat` fill (`SceneMetalLayer.solidBlending`).
        case solid(blending: String)

        var blending: String {
            switch self {
            case .material(let plan): plan.pass.blending
            case .solid(let blending): blending
            }
        }
    }

    /// The layer's base when its effects' last pass draws into the scene (WE's rule for the
    /// last pass, below); nil when they composite through a buffer. WE sets an object's flag 0x10,
    /// which runs every pass into its buffers and draws them with a composite material
    /// (0x1401e9513, 0x1401ea06d…0x1401ea0c9), when:
    /// - its `colorBlendMode` is other than 0 and 31 (0x1401e6f74…0x1401e6fa2);
    /// - the scene has distance or height fog (scene flags 0x800000/0x1000000 from `general`'s
    ///   `fogdistance`/`fogheight`, 0x140186561…0x1401865ad; tested at 0x1401e6f96);
    /// - another object samples its image (`_rt_imageLayerComposite_<id>`: 0x1401881b0, 0x1401d3c1e);
    /// - it is lit with effects: its prelighting pass fills the buffer (0x140209b70…0x140209b79);
    /// - it is text (0x14020b1fa…0x14020b20d).
    /// Ours also composites through a buffer where it draws the layer another way: without the
    /// layer's material pass (text, scene regions, shapes, a material that draws no image),
    /// with a `BLENDMODE` (31, which WE adds with), for effects that read the scene (WE copies the
    /// scene before the last pass, 0x1401ea0dd…0x1401ea114) and while a planar reflection draws
    /// the layers' images.
    /// A solid layer (`solidBlending`, WE's `flat` material) draws its last pass into the scene
    /// like an image: the pass's `a_Position` is the layer's quad in layer units, centred on it,
    /// not the buffer's −1…1 (3141421197's ray-marcher takes its view rays from it).
    private func lastPassDrawsIntoScene(_ entry: PreparedLayer, compositeSource: Bool) -> LastPassBase? {
        let layer = entry.layer
        // A puppet's last pass would draw its bind layout; its output is laid out by the posed mesh first.
        guard layer.text == nil, !layer.sceneInput, layer.puppet == nil, !layer.readsScene, !compositeSource,
              !lighting.settings.fog.distance, !lighting.settings.fog.height,
              planarReflection?.isNeeded(spatial.models) != true else { return nil }
        guard let plan = layer.imageMaterial else {
            guard let blending = layer.solidBlending, layer.solidFill != nil,
                  blending.lowercased() != "alphatocoverage" else { return nil }
            return .solid(blending: blending)
        }
        guard plan.prelighting == nil, layer.solidFill == nil,
              (plan.pass.variant?.combos["BLENDMODE"] ?? 0) == 0,
              !plan.pass.readsSceneSnapshot, !plan.pass.readsMipMappedFrameBuffer,
              plan.pass.blending.lowercased() != "alphatocoverage" else { return nil }
        return .material(plan)
    }

    /// Where a layer's last effect pass draws: its quad, as its material draws it (`encodeLayer`),
    /// sampling the chain's buffers where `image` shows its picture (its sprite frame, or the
    /// content of a padded texture); nil `image` gives the pass only its target (`scenePassIsReady`).
    func lastPassPlacement(blending: String, draw: LayerDraw, image: RenderTextureFrame?,
                           sceneFormat: MTLPixelFormat) -> EffectGraphRenderer.ScenePlacement {
        let extent = draw.placement?.size ?? draw.quad.extent
        let positions = draw.placement?.quadPositions ?? ImageMaterialRenderer.quadPositions(extent: extent)
        let texCoords = ImageMaterialRenderer.corners.map { corner -> SIMD2<Float> in
            guard let image else { return corner }
            return image.uvOrigin + corner.x * image.uvAxisX + corner.y * image.uvAxisY
        }
        let viewProjection: simd_float4x4
        if let placement = draw.placement {
            viewProjection = placement.shaderViewProjection
        } else if frameDepth != nil, !isPerspective {
            viewProjection = PassMatrices.shaderViewProjection(SceneCamera.orthographic(size: sceneSize))
        } else {
            viewProjection = ImageMaterialRenderer.viewProjection(sceneSize: sceneSize)
        }
        return EffectGraphRenderer.ScenePlacement(
            positions: positions, texCoords: texCoords,
            model: draw.placement?.world ?? ImageMaterialRenderer.modelMatrix(draw.quad),
            view: draw.placement?.camera.view ?? matrix_identity_float4x4, viewProjection: viewProjection,
            blending: blending, pixelFormat: sceneFormat, sampleCount: sceneSampleCount,
            depthFormat: frameDepth == nil ? .invalid : SceneDepthStates.format)
    }

    /// What a layer's effects start from: its image, or for a sprite sheet its current frame cut out
    /// of the atlas (for an image in a padded .tex, the image cut out of its allocation), as WE's
    /// base pass draws it into the layer's buffer (`SceneSpriteFrameInputs`).
    func effectInput(_ entry: PreparedLayer, image: RenderTextureFrame, commandBuffer: MTLCommandBuffer) -> MTLTexture {
        guard entry.layer.puppet == nil, let cut = spriteFrameInputs.input(image, layerID: entry.layer.id, commandBuffer: commandBuffer)
        else { return image.texture }
        spriteFrameVersions[entry.layer.id] = cut.version
        return cut.texture
    }

    /// A layer's material draw of `texture` this frame (`ImageMaterialRenderer.Draw`), as `encodeLayer` makes it.
    private func materialDraw(_ entry: PreparedLayer, _ draw: LayerDraw, texture: MTLTexture,
                              frame: BuiltinFrameContext) -> ImageMaterialRenderer.Draw {
        ImageMaterialRenderer.Draw(
            layerID: entry.layer.id, quad: draw.quad, sceneSize: sceneSize,
            color: SIMD3(draw.color.x, draw.color.y, draw.color.z), alpha: draw.opacity, brightness: draw.brightness,
            texture: texture, contentSize: entry.layer.source.contentSize, uvOrigin: .zero,
            uvAxisX: SIMD2(1, 0), uvAxisY: SIMD2(0, 1), sceneSnapshot: nil, mipMappedFrameBuffer: mipMappedTarget,
            shadowAtlas: frameShadowAtlas, frame: frame, values: values(of: entry.layer.id),
            assetTexture: { [unowned self] key, source in self.effectAssetTexture(key: key, source: source) },
            assetSprite: { [unowned self] key, source in self.effectAssetSprite(key: key, source: source) },
            placement: draw.placement)
    }

    /// What a layer's effect chain reads this frame besides its input.
    func effectContext(_ entry: PreparedLayer, draw: LayerDraw, input: MTLTexture, snapshot: MTLTexture?,
                       frame: BuiltinFrameContext) -> EffectGraphRenderer.Context {
        var context = EffectGraphRenderer.Context(
            frame: frame,
            values: values(of: entry.layer.id),
            assetTexture: { [unowned self] key, source in self.effectAssetTexture(key: key, source: source) },
            sceneSnapshot: snapshot,
            // The scripted/animated values the layer is drawn with this frame, not the authored ones
            // (in the raster already for text with font effects).
            layerColor: !textRastersInColor(entry) ? SIMD3(draw.color.x, draw.color.y, draw.color.z) : SIMD3(repeating: 1),
            layerAlpha: draw.opacity)
        context.mipMappedFrameBuffer = mipMappedTarget
        context.layerComposite = { [unowned self] id in self.layerComposites[id] }
        context.planarReflection = frameReflection
        context.systemTexture = { [unowned self] kind in self.systemTexture(kind) }
        context.effectTextureProjection = EffectGraphRenderer.effectTextureProjection(quad: draw.quad, sceneSize: sceneSize)
        context.layerModelMatrix = draw.placement?.world ?? BuiltinPassContext.layerModelMatrix(draw.world)
        // WE's layer buffers are frame-buffer class: RGBA16F in HDR.
        context.frameBufferFormat = postProcess.drawsHDR ? .rgba16Float : .rgba8Unorm
        context.assetContentSize = { _, source in source.contentSize }
        context.assetSprite = { [unowned self] key, source in self.effectAssetSprite(key: key, source: source) }
        if let probe = drawProbe { context.recordAnimated = { probe.record(constant: $0, value: $1) } }
        // Hidden effects (authored, user-bound or a script's `visible`) are built but skipped;
        // constants scripts set go over the material's.
        var scripted = scripts.effects(entry.layer.weEffects, of: entry.layer.id)
        if !editorLive.isEmpty { scripted = editorLive.effects(entry.layer.weEffects, of: entry.layer.id, scripted: scripted) }
        context.hiddenEffects = scripted.hidden
        context.constantWrites = scripted.writes
        context.scriptRevision = scripted.revision
        context.resolution = effectResolution(of: entry.layer.id)
        // A puppet's mesh redraws its image into the same texture as it moves: without the
        // drawing's version, the chain's kept output and base pass would hold the first pose.
        if entry.layer.puppet != nil { context.inputVersion = puppets?.albedoVersion(entry.layer.id) ?? 0 }
        // A sprite sheet's frames are cut into the same texture as it plays.
        if let version = spriteFrameVersions[entry.layer.id] { context.inputVersion = version }
        // Effect Detail: Match Display runs a layer's effects at most at its size on screen.
        if renderSettings.sceneDetail == .matchDisplay {
            context.footprint = effectFootprint(entry, draw: draw, input: input)
        }
        // Scene regions are drawn at the scene target's density, below full detail when the target
        // is smaller than the scene's authored size; solid fills and text with effects are at WE's
        // own buffer size.
        if context.footprint == nil, fullDetailScale > 1, entry.layer.solidFill == nil, entry.layer.text == nil {
            let standIn = (SIMD2(Float(input.width), Float(input.height)) * fullDetailScale).rounded(.toNearestOrAwayFromZero)
            context.inputStandInSize = SIMD2(Int(standIn.x), Int(standIn.y))
        }
        return context
    }

    /// The on-screen size, in scene-target pixels, of the whole image a layer's effects run on
    /// (`SceneEffectDetail`): its quad at the target's density, over the part of the image the quad
    /// shows (a padded `.tex` or a sprite frame shows part of it). Nil where the effects already run
    /// at the display's density or their input isn't the layer's image: scene-input layers (the
    /// scene under them, resampled at the target's density), text (rasterised at it), videos and
    /// perspective layers.
    private func effectFootprint(_ entry: PreparedLayer, draw: LayerDraw, input: MTLTexture) -> SIMD2<Float>? {
        let layer = entry.layer
        guard !layer.sceneInput, layer.text == nil, !perspective(layer.id, authored: layer.perspective), let frame = entry.frames.first,
              frame.texture.width == input.width, frame.texture.height == input.height else { return nil }
        if case .video = layer.source { return nil }
        let shown = SIMD2(simd_length(frame.uvAxisX), simd_length(frame.uvAxisY))
        guard shown.x > 0, shown.y > 0 else { return nil }
        // Through a camera, the quad is as large as its projection.
        if let placement = draw.placement {
            guard let density = placement.pixelsPerUnit(targetSize: SIMD2<Float>(sceneRenderTargetSize)) else { return nil }
            return placement.size * imageShareOfQuad(entry) * density / shown
        }
        return draw.quad.extent * imageShareOfQuad(entry) * renderPixelsPerUnit / shown
    }

    /// The share of a layer's quad its image covers: less than 1 where a puppet's quad grew to its
    /// posed bounds (`ScenePuppetCanvas`), so its effects keep running at the image's density.
    private func imageShareOfQuad(_ entry: PreparedLayer) -> SIMD2<Float> {
        guard let puppet = entry.layer.puppet, let canvas = puppetCanvases[entry.layer.id] else { return SIMD2(1, 1) }
        return ScenePuppetCanvas.imageShare(imageSize: puppet.imageSize, canvas: canvas)
    }

    /// A lit or reflective layer's image as its effects start from it: lit by its material's
    /// prelighting pass (`ImageMaterialRenderer.prelight`); nil for any other layer.
    private func prelit(_ entry: PreparedLayer, draw: LayerDraw, input: MTLTexture, snapshot: MTLTexture?,
                        frame: BuiltinFrameContext, commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        guard let plan = entry.layer.imageMaterial, plan.prelighting != nil, let imageMaterials else { return nil }
        let lit = imageMaterials.prelight(plan, ImageMaterialRenderer.Draw(
            layerID: entry.layer.id, quad: draw.quad, sceneSize: sceneSize, color: SIMD3(repeating: 1), alpha: 1,
            brightness: 1, texture: input, contentSize: entry.layer.source.contentSize, uvOrigin: .zero,
            uvAxisX: SIMD2(1, 0), uvAxisY: SIMD2(0, 1), sceneSnapshot: snapshot, mipMappedFrameBuffer: mipMappedTarget,
            shadowAtlas: frameShadowAtlas, frame: frame, values: values(of: entry.layer.id),
            assetTexture: { [unowned self] key, source in self.effectAssetTexture(key: key, source: source) },
            assetSprite: { [unowned self] key, source in self.effectAssetSprite(key: key, source: source) }),
            // The layer's effect buffers' format: RGBA16F in HDR (docs/lighting-plan.md §2.3, §2.6).
            format: postProcess.drawsHDR ? .rgba16Float : .rgba8Unorm, commandBuffer: commandBuffer)
        prelitImages[entry.layer.id] = lit
        return lit
    }

    /// A textureless layer's image as its effects start from it: its fill at WE's buffer size, the
    /// layer's `size` rounded (`SceneMetalLayer.solidFill`), filled once per content; nil for a
    /// layer with a texture (or when the target can't be made, and the 1×1 source stands in).
    func solidEffectInput(_ layer: SceneMetalLayer, commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        guard let fill = layer.solidFill else { return nil }
        let size = SolidEffectInput.size(layer.size)
        if let cached = solidEffectInputs[layer.id], cached.width == size.x, cached.height == size.y { return cached }
        guard let texture = solidFillTexture(layer, fill: fill, reusing: nil, commandBuffer: commandBuffer) else { return nil }
        solidEffectInputs[layer.id] = texture
        return texture
    }

    /// A solid layer's base pass when its last effect pass draws into the scene: its fill at the
    /// effect input's size with the layer's `alpha` in its alpha, as WE's `flat` writes `g_Alpha`
    /// into the layer's buffer and the last pass carries it into the scene. Refilled when the
    /// alpha changes, with a new `version` for the chain's `inputVersion`.
    private func solidSceneBase(_ layer: SceneMetalLayer, alpha: Float,
                                commandBuffer: MTLCommandBuffer) -> (texture: MTLTexture, version: UInt64)? {
        guard var fill = layer.solidFill else { return nil }
        fill.w *= alpha
        let size = SolidEffectInput.size(layer.size)
        let cached = solidSceneBases[layer.id].flatMap { $0.texture.width == size.x && $0.texture.height == size.y ? $0 : nil }
        if let cached, cached.alpha == fill.w { return (cached.texture, cached.version) }
        guard let texture = solidFillTexture(layer, fill: fill, reusing: cached?.texture, commandBuffer: commandBuffer)
        else { return nil }
        solidSceneBaseFills &+= 1
        solidSceneBases[layer.id] = (texture, fill.w, solidSceneBaseFills)
        return (texture, solidSceneBaseFills)
    }

    /// `fill` (straight RGBA) over a texture of `layer`'s effect input size (`SolidEffectInput`):
    /// `reusing`, or a new one.
    private func solidFillTexture(_ layer: SceneMetalLayer, fill: SIMD4<Float>, reusing: MTLTexture?,
                                  commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        let size = SolidEffectInput.size(layer.size)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: size.x,
                                                                  height: size.y, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        guard let texture = reusing ?? device.makeTexture(descriptor: descriptor) else {
            OWELog.error(.scene, "Layer \(layer.id): could not allocate its \(size.x)×\(size.y) effect input")
            return nil
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: Double(fill.x), green: Double(fill.y),
                                                            blue: Double(fill.z), alpha: Double(fill.w))
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encoder.endEncoding()
        return texture
    }

    func effectAssetTexture(key: String, source: SceneMetalTextureSource) -> MTLTexture? {
        if case .animated = source { return animatedAssetFrame(key: key, source: source)?.texture }
        if let cached = effectAssetTextures[key] { return cached }
        guard let texture = makeTextureFrames(from: source)?.first?.texture else { return nil }
        effectAssetTextures[key] = texture
        return texture
    }

    /// An animated asset texture's sprite frame this frame, for `g_TextureNRotation/Translation`;
    /// nil for a still one.
    func effectAssetSprite(key: String, source: SceneMetalTextureSource) -> BuiltinSpriteFrame? {
        guard case .animated = source, let frame = animatedAssetFrame(key: key, source: source) else { return nil }
        return BuiltinSpriteFrame(rotation: SIMD4(frame.uvAxisX.x, frame.uvAxisX.y, frame.uvAxisY.x, frame.uvAxisY.y),
                                  translation: frame.uvOrigin)
    }

    /// The frame an effect or material shows of an animated asset texture (T7): the texture's
    /// shared clock (§2.7), which every binding of the frame and every image layer of the texture
    /// share. The key is `materialPath|name`; the clock is the texture name's.
    private func animatedAssetFrame(key: String, source: SceneMetalTextureSource) -> RenderTextureFrame? {
        let frames: [RenderTextureFrame]
        if let cached = effectAssetFrames[key] {
            frames = cached
        } else {
            guard let made = makeTextureFrames(from: source), !made.isEmpty else { return nil }
            effectAssetFrames[key] = made
            frames = made
        }
        guard frames.count > 1 else { return frames[0] }
        let texture = key.split(separator: "|", omittingEmptySubsequences: false).last.map(String.init) ?? key
        let frame = timelines.materialTextureFrame(texture: texture, frameTimes: { frames.map(\.duration) },
                                                   delta: Float(clock.delta))
        // `setFrame(n)` can't reach a material's clock; a frame outside the sheet can't happen, but draws the first.
        return frame >= 0 && Int(frame) < frames.count ? frames[Int(frame)] : frames[0]
    }
}
