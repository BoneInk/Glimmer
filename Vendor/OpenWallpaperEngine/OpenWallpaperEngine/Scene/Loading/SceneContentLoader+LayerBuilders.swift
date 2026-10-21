//
//  SceneContentLoader+LayerBuilders.swift
//  Open Wallpaper Engine
//
//  An object's layer: image, puppet, solid, text and shape layers, and the objects scripts create.
//

import SwiftUI
import CoreText
import CryptoKit
import OWESceneEditing

extension SceneContentLoader {
    /// An object's layer: an image, text or shape layer, with its user bindings; nil for objects
    /// that draw nothing of their own (groups, particle systems, sounds).
    func buildLayer(_ object: WESceneObject, id: Int, wallpaperDir: URL, sceneSize: SIMD2<Float>,
                            context: SceneValueContext) -> SceneMetalLayer? {
        var layer = buildMetalLayer(object, id: id, wallpaperDir: wallpaperDir, sceneSize: sceneSize)
            ?? buildMetalTextLayer(object, id: id, wallpaperDir: wallpaperDir, sceneSize: sceneSize)
            ?? buildShapeLayer(object, id: id, wallpaperDir: wallpaperDir, sceneSize: sceneSize)
        layer?.bindings = SceneLayerBindings(object: object, builtWith: context)
        if layer?.fillsScene == false { layer?.tilt = SceneLocalTransform(object: object).tilt }
        return layer
    }

    // MARK: - Objects scripts create

    /// What the renderer runs the scene's scripts from; nil without a scene document.
    func scriptContent(wallpaperDir: URL, sceneSize: SIMD2<Float>) -> SceneScriptSceneContent? {
        guard let loadedDocument else { return nil }
        let storeKey = propertyStoreKey
        let modelData = SceneScriptModelDataStore()
        // Keyed on the install folder, not project.json (SceneScriptStorageKey); the key used before.
        let previousKey = loadedProjectId ?? Self.localWallpaperID(wallpaperDir)
        return SceneScriptSceneContent(
            wallpaperID: SceneScriptStorageKey.key(forWallpaperDirectory: wallpaperDir),
            document: loadedDocument.document, documentSignature: loadedDocument.signature,
            project: loadedProject,
            userValues: { WallpaperServices.shared.userProperties(wallpaper: storeKey) },
            file: { [weak self] path in self?.scriptFile(path, wallpaperDir: wallpaperDir) },
            modelData: modelData,
            legacyStorageID: SceneScriptStorageKey.legacyKeyToAdopt(previousKey: previousKey,
                                                                    wallpaperDirectory: wallpaperDir),
            makeLayer: { [weak self] json in
                self?.buildScriptLayer(json, wallpaperDir: wallpaperDir, sceneSize: sceneSize, modelData: modelData)
            })
    }

    /// A stable id for a wallpaper without a Workshop id: its directory's hash (timelines are keyed
    /// on it; `localStorage` uses `SceneScriptStorageKey`).
    static func localWallpaperID(_ directory: URL) -> String {
        SceneScriptStorageKey.localKey(forWallpaperDirectory: directory)
    }

    /// A file for the scripts (`createLayer` assets, texture animations). Called on a script
    /// thread, so it takes the scene lock like every other asset read.
    private func scriptFile(_ path: String, wallpaperDir: URL) -> Data? {
        sceneLock.lock()
        defer { sceneLock.unlock() }
        return assetData(named: path, wallpaperDir: wallpaperDir)
    }

    /// An object a script created (`thisScene.createLayer`), built like the scene's own: a layer,
    /// a particle system or a sound. Off the main thread, under the scene lock.
    private func buildScriptLayer(_ json: [String: SceneJSON], wallpaperDir: URL, sceneSize: SIMD2<Float>,
                                  modelData: SceneScriptModelDataStore) -> SceneScriptCreatedObject? {
        sceneLock.lock()
        defer { sceneLock.unlock() }
        defer { endBuildTextures() }
        let context = userValueContext
        let resolved: WESceneObject
        do {
            resolved = try UserPropertyBindingTable.decode(
                WESceneObject.self, from: UserPropertyBindingTable.resolving(.object(json), properties: userProperty))
        } catch {
            OWELog.error(.script, "createLayer: the object can't be decoded: \(error)")
            return nil
        }
        if resolved.particle != nil {
            guard let id = createdID(of: resolved) else { return nil }
            var systems = buildParticleFamily(resolved, id: id, wallpaperDir: wallpaperDir, sceneSize: sceneSize,
                                              pixelUnits: loadedScene.map(Self.particlesUsePixelUnits) ?? true,
                                              transforms: SceneTransformHierarchy(objects: [resolved]),
                                              cache: ParticleDefinitionCache(sharesParts: sharesParticleDefinitions))
            guard !systems.isEmpty else { return nil }
            // The scene's factor, or the family's own if it alone exceeds the budget.
            let own = ParticleBudget.scale(authored: systems.reduce(0) { $0 + ParticleBudget.capacity(of: $1) },
                                           budget: renderSettings.particleBudget.limit)
            for index in systems.indices { systems[index].budgetScale = min(particleBudgetScale, own) }
            let motion = SceneObjectMotion(object: resolved,
                                           bindings: SceneLayerBindings(object: resolved, builtWith: context))
            return .particles(systems, motion: motion)
        }
        if resolved.sound != nil {
            return soundBuilder(wallpaperDir: wallpaperDir).sounds(in: [resolved], context: context).first.map { .sound($0) }
        }
        if let model = resolved.model {
            // The renderer keys it by the id the script gave it.
            let object = SceneModelObject(id: "", name: resolved.name ?? "", order: Int.max, authored: model,
                                          animationLayers: resolved.animationLayers, renderValues: resolved.renderValues)
            let made: SceneModelObject?
            if case .loadedID(let token) = model.source {
                made = buildScriptModel(object, token: token, modelData: modelData, wallpaperDir: wallpaperDir)
            } else {
                made = buildModels([object], wallpaperDir: wallpaperDir).first
            }
            guard let built = made, built.plan != nil,
                  let node = SceneTransformHierarchy3D(objects: [resolved]).nodes.values.first else { return nil }
            let motion = SceneObjectMotion(object: resolved,
                                           bindings: SceneLayerBindings(object: resolved, builtWith: context))
            return .model(built, node: node, motion: motion)
        }
        guard let id = createdID(of: resolved) else { return nil }
        return buildLayer(resolved, id: id, wallpaperDir: wallpaperDir, sceneSize: sceneSize, context: context).map { .layer($0) }
    }

    /// The id `createLayer` gave the object it made (`SceneScriptSceneDescriber.layer`), which its
    /// layer or particle system is built with; nil (logged) for an object without one.
    private func createdID(of object: WESceneObject) -> Int? {
        guard let id = object.id else {
            OWELog.error(.script, "createLayer: \(object.name ?? "an object") has no id")
            return nil
        }
        return id
    }

    /// Finds the scene's sound files in the package, the folder, Workshop items and WE's assets.
    func soundBuilder(wallpaperDir: URL) -> SceneSoundContentBuilder {
        let parser = pkgParser
        let workshop = workshopAssets
        return SceneSoundContentBuilder(wallpaperDirectory: wallpaperDir,
                                        packagedData: { parser?.extractFile(named: $0) },
                                        workshopURL: { workshop.url(for: $0) },
                                        workshopData: { path in workshop.located(path).map { ($0.data, $0.source) } },
                                        packageURL: parser == nil ? nil : pkgURL)
    }

    /// An object's own `origin`, relative to its parent.
    private func localOrigin(for object: WESceneObject) -> SIMD2<Float> {
        SceneLocalTransform(object: object).origin
    }

    private func buildMetalLayer(_ object: WESceneObject, id: Int, wallpaperDir: URL, sceneSize: SIMD2<Float>) -> SceneMetalLayer? {
        var layer = buildImageLayer(object, id: id, wallpaperDir: wallpaperDir, sceneSize: sceneSize)
        layer?.systemImage = systemImage(of: object, id: id, wallpaperDir: wallpaperDir)
        return layer
    }

    /// The system texture an image object binds to its image's slot (0): its `instance`'s
    /// `usertextures`, else its material's first pass's (2963872291's album-art placeholder);
    /// nil (logged when it names one this app doesn't supply) for none.
    private func systemImage(of object: WESceneObject, id: Int, wallpaperDir: URL) -> SceneSystemTexture? {
        var userTextures: [SceneJSON?] = [object.instance?.usertextures]
        if let imagePath = object.image,
           let model: WEModel = loadJSON(path: imagePath, wallpaperDir: wallpaperDir),
           let materialPath = model.material,
           let material: WEMaterial = loadJSON(path: materialPath, wallpaperDir: wallpaperDir) {
            userTextures.append(material.passes?.first?.usertextures)
        }
        return SceneSystemTexture.bindings(in: userTextures, owner: "Layer \(id)")[0]
    }

    /// The picture or video a texture user property (`SceneUserTexture`) puts in an image
    /// object's image slot (0); nil keeps the authored image. The binding is recorded either way,
    /// so picking or clearing a file rebuilds the layer.
    private func userTexture(of object: WESceneObject, material: WEMaterial, id: Int,
                             wallpaperDir: URL) -> SceneMetalTextureSource? {
        guard let property = SceneUserTexture.property(in: [object.instance?.usertextures,
                                                            material.passes?.first?.usertextures], slot: 0) else { return nil }
        bindingTable.record(.asset(SceneUserTexture.documentPath(owner: id, slot: 0)),
                            json: SceneUserTexture.bindingDocument(property: property))
        guard let path = userProperty(property)?.trimmingCharacters(in: .whitespaces), !path.isEmpty,
              let source = SceneUserTexture.source(path: path, wallpaperDir: wallpaperDir,
                                                   device: MTLCreateSystemDefaultDevice()) else { return nil }
        if case .video(let stream) = source {
            embeddedVideoLock.withLock {
                embeddedVideoStreams.add(stream)
                stream.setHostRate(embeddedVideoRate)
            }
        }
        return source
    }

    private func buildImageLayer(_ object: WESceneObject, id: Int, wallpaperDir: URL, sceneSize: SIMD2<Float>) -> SceneMetalLayer? {
        guard let imagePath = object.image,
              let model: WEModel = loadJSON(path: imagePath, wallpaperDir: wallpaperDir),
              let materialPath = model.material,
              let material: WEMaterial = loadJSON(path: materialPath, wallpaperDir: wallpaperDir) else {
            return nil
        }
        if model.solidlayer == true {
            var layer = buildSolidLayer(object, id: id, wallpaperDir: wallpaperDir, sceneSize: sceneSize)
            layer.solidBlending = blendingOverride(for: object)?.rawValue ?? material.passes?.first?.blending ?? "normal"
            // `flat` has no `BLENDMODE`: a blend mode composites the fill through WE's material for it.
            if let mode = object.colorBlendMode, mode != 0 {
                layer.imageMaterial = buildBlendComposite(mode, object: object, id: id, wallpaperDir: wallpaperDir)
            } else {
                layer.imageMaterial = buildImageMaterial(materialPath, object: object, id: id, wallpaperDir: wallpaperDir)
            }
            return layer
        }
        guard let textureName = material.passes?.first?.textures?.first ?? nil,
              let source = loadMetalTexture(named: textureName, materialDir: materialPath, wallpaperDir: wallpaperDir,
                                            colour: true) else {
            return nil
        }
        let sceneInput = textureName == "_rt_FullFrameBuffer" || textureName == "_rt_MipMappedFrameBuffer"
        let size: SIMD2<Float>
        if model.fullscreen == true {
            size = sceneSize
        } else if let sizeString = object.size {
            let value = sizeString.parseVector2()
            size = SIMD2<Float>(Float(value.0), Float(value.1))
        } else if let declared = model.declaredSize {
            // The model's own size (WE's templates), not its first texture's.
            size = declared
        } else {
            // In pixels, and for a .tex the image's own size, not the padded allocation around it;
            // for a sprite sheet one frame's.
            if case let .animated(animation) = source, animation.images.isEmpty { return nil }
            size = source.unsizedLayerSize * textureReductionApplied(named: textureName, materialDir: materialPath,
                                                                     wallpaperDir: wallpaperDir)
        }
        let position: SIMD2<Float> = model.fullscreen == true
            ? sceneSize / 2
            : localOrigin(for: object)
        let rotation = Float(object.angles?.parseVector3().2 ?? 0)
        let staticScale = object.scale?.parseVector3() ?? (1, 1, 1)
        let objectColor = object.color?.parseVector3() ?? (1, 1, 1)
        let effectPlans = buildEffectPlans(object.effects ?? [], objectID: id, wallpaperDir: wallpaperDir)
        var layer = SceneMetalLayer(id: String(id), name: object.name ?? String(id), source: source, position: position, size: size,
                       scale: SIMD2<Float>(Float(staticScale.0), Float(staticScale.1)),
                       opacity: Float(object.alpha ?? 1),
                       brightness: Float(object.brightness ?? 1), color: SIMD4<Float>(Float(objectColor.0), Float(objectColor.1), Float(objectColor.2), 1), text: nil,
                       parallaxDepth: Self.parallaxDepth(of: object),
                       perspective: object.perspective ?? false,
                               rotation: rotation)
        layer.weEffects = effectPlans.plans
        layer.sceneInput = sceneInput
        layer.clearsSceneAlpha = sceneInput && object.copybackground == false
        if case .animated = source { layer.textureKey = textureName }
        layer.alignment = model.fullscreen == true ? nil : object.alignment
        layer.fillsScene = model.fullscreen == true
        // A layer whose image is the scene only exists to run effects on it; WE skips it without any.
        if sceneInput, effectPlans.plans.isEmpty { return nil }
        if !sceneInput, let picked = userTexture(of: object, material: material, id: id, wallpaperDir: wallpaperDir) {
            // Drawn in the authored image's place and size; its frames aren't the image's.
            layer.source = picked
            layer.textureKey = nil
        }
        if !sceneInput {
            // A puppet is lit like any image: its mesh draws the image (`layer.puppet`) that its
            // effects, prelighting and own draw read.
            layer.imageMaterial = buildImageMaterial(materialPath, object: object, id: id, wallpaperDir: wallpaperDir,
                                                     prelit: !effectPlans.plans.isEmpty)
        }
        if let rig = model.puppet, !sceneInput {
            let imageSize = source.pixelSize * textureReductionApplied(named: textureName, materialDir: materialPath,
                                                                       wallpaperDir: wallpaperDir)
            layer.puppet = buildPuppet(rig, materialPath: materialPath, object: object, id: id, source: source,
                                       imageSize: imageSize, wallpaperDir: wallpaperDir)
        }
        return layer
    }

    /// A Puppet Warp image's mesh (`ScenePuppetPlan`); nil (logged) draws the image unwarped.
    private func buildPuppet(_ rig: String, materialPath: String, object: WESceneObject, id: Int, source: SceneMetalTextureSource,
                             imageSize: SIMD2<Float>, wallpaperDir: URL) -> ScenePuppetPlan? {
        guard let translator = effectTranslator else { return nil }
        let builder = ImageMaterialPlanBuilder(
            translator: translator,
            readFile: { [weak self] path in self?.assetData(named: path, wallpaperDir: wallpaperDir) },
            loadTexture: { [weak self] name, path in self?.loadMetalTexture(named: name, materialDir: path, wallpaperDir: wallpaperDir) },
            sceneEngineCombos: sceneEngineCombos)
        do {
            let model = try MDLModel.load(path: rig, package: pkgParser, directory: wallpaperDir)
            return try ScenePuppetPlan.make(model: model, rigPath: rig, materialPath: materialPath, source: source,
                                            imageSize: imageSize, animationLayers: object.animationLayers,
                                            builder: builder)
        } catch {
            OWELog.error(.scene, "Puppet layer \(id) draws its image unwarped, rig \(rig): \(error)")
            return nil
        }
    }

    /// `models/util/solidlayer*.json`: WE's `flat` shader fills the quad with the object's `color`.
    /// The colour is baked into a generated texture so authored effects see the coloured image, as
    /// they do in WE; `alpha` stays on the layer and is applied when the quad is drawn.
    private func buildSolidLayer(_ object: WESceneObject, id: Int, wallpaperDir: URL,
                                 sceneSize: SIMD2<Float>) -> SceneMetalLayer {
        let authoredSize = object.size.map { value -> SIMD2<Float> in
            let parsed = value.parseVector2()
            return SIMD2<Float>(Float(parsed.0), Float(parsed.1))
        }
        // An authored size is the quad's even when it is zero: WE draws nothing of an empty quad
        // (2963872291's 'Player Options', a 0×0 host for the music player's scripts). Only a
        // layer without a size takes the scene's.
        let size = authoredSize ?? sceneSize
        let color = object.color?.parseVector3() ?? (1, 1, 1)
        let staticScale = object.scale?.parseVector3() ?? (1, 1, 1)
        var layer = SceneMetalLayer(id: String(id), name: object.name ?? String(id),
                       source: .image(Self.solidImage(red: color.0, green: color.1, blue: color.2)),
                       position: localOrigin(for: object),
                       size: size,
                       scale: SIMD2<Float>(Float(staticScale.0), Float(staticScale.1)),
                       opacity: Float(object.alpha ?? 1),
                       brightness: Float(object.brightness ?? 1), color: SIMD4<Float>(repeating: 1), text: nil,
                       parallaxDepth: Self.parallaxDepth(of: object),
                       perspective: object.perspective ?? false,
                       rotation: Float(object.angles?.parseVector3().2 ?? 0))
        layer.weEffects = buildEffectPlans(object.effects ?? [], objectID: id, wallpaperDir: wallpaperDir).plans
        layer.alignment = object.alignment
        layer.solidFill = SIMD4(Float(color.0), Float(color.1), Float(color.2), 1)
        // The colour is the image: a bound colour rebuilds the layer.
        bindingTable.baked(.objectField(.color), of: .object(id))
        return layer
    }

    /// A 1x1 opaque image of one colour; the quad stretches it to the layer's size. Its texel is
    /// the colour's value as authored, like WE's `util/white` tinted by `g_Color4`. Drawing it with
    /// AppKit would convert it to the display's colour space (e.g. Display P3) and shift it.
    static func solidImage(red: Double, green: Double, blue: Double) -> NSImage {
        pixelImage([red, green, blue, 1])
    }

    /// A 1x1 image holding `rgba` (0...1 each) as straight-alpha bytes, without colour management.
    static func pixelImage(_ rgba: [Double]) -> NSImage {
        let bytes = rgba.map { UInt8((min(max($0.isFinite ? $0 : 0, 0), 1) * 255).rounded()) }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue).union(.byteOrder32Big),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            preconditionFailure("a 1x1 RGBA8 image is always representable")
        }
        return NSImage(cgImage: image, size: NSSize(width: 1, height: 1))
    }

    /// Text is laid out and rasterised by the renderer every frame (its string can change); the
    /// layer's source is only a placeholder. `size` is the block before auto-sizing.
    private func buildMetalTextLayer(_ object: WESceneObject, id: Int, wallpaperDir: URL, sceneSize: SIMD2<Float>) -> SceneMetalLayer? {
        guard let text = object.textValue else { return nil }
        let sizeValue = object.size?.parseVector2() ?? (0, 0)
        let textScale = object.scale?.parseVector3() ?? (1, 1, 1)
        let color = object.color?.parseVector3() ?? (1, 1, 1)
        // Padding is authored as "32" or "32 32"; a scalar applies to both axes. Absent, WE's 32.
        let paddingParts = (object.padding ?? "").split(separator: " ").compactMap { Float($0) }
        let firstPadding = paddingParts.first ?? WETextDefaults.padding
        let padding = SIMD2<Float>(firstPadding, paddingParts.count > 1 ? paddingParts[1] : firstPadding)
        var textConfig = SceneMetalText(value: text, font: registerFont(object.font),
                                         pointSize: CGFloat(object.pointsize ?? WETextDefaults.pointSize),
                                         horizontalAlignment: object.horizontalalign,
                                         verticalAlignment: object.verticalalign,
                                         padding: padding,
                                         maxWidth: object.limitwidth == true
                                            ? Float(object.maxwidth ?? WETextDefaults.maxWidth) : nil,
                                         maxRows: object.limitrows == true ? object.maxrows ?? WETextDefaults.maxRows : nil,
                                         useEllipsis: object.limituseellipsis ?? false,
                                         anchor: object.anchor, blockAlign: object.blockalign ?? false,
                                         effects: object.textEffects.effects)
        textConfig.maxWidthValue = Float(object.maxwidth ?? WETextDefaults.maxWidth)
        textConfig.maxRowsValue = object.maxrows ?? WETextDefaults.maxRows
        textConfig.fonts = textFontLoader()
        textConfig.opaqueBackground = object.opaquebackground ?? false
        if let color = object.backgroundcolor?.parseVector3() {
            textConfig.backgroundColor = SIMD3(Float(color.0), Float(color.1), Float(color.2))
        }
        textConfig.backgroundBrightness = Float(object.backgroundbrightness ?? 1)
        let spacingParts = (object.spacing ?? "").split(separator: " ").compactMap { Float($0) }
        if let first = spacingParts.first {
            textConfig.spacing = SIMD2(first, spacingParts.count > 1 ? spacingParts[1] : first)
        }
        var layer = SceneMetalLayer(id: String(id), name: object.name ?? String(id),
                               source: .image(transparentPlaceholderImage),
                               position: localOrigin(for: object),
                               size: SIMD2<Float>(Float(sizeValue.0), Float(sizeValue.1)),
                               scale: SIMD2<Float>(Float(textScale.0), Float(textScale.1)),
                               opacity: Float(object.alpha ?? 1),
                               brightness: Float(object.brightness ?? 1), color: SIMD4<Float>(Float(color.0), Float(color.1), Float(color.2), 1), text: textConfig, parallaxDepth: Self.parallaxDepth(of: object),
                               perspective: object.perspective ?? false,
                               rotation: Float(object.angles?.parseVector3().2 ?? 0))
        // No alignment: the lines sit around the origin by `horizontalalign` and `verticalalign` as
        // WE places them (`SceneTextLayout.baselineOrigins`), in a block centred on them (`boxCenter`).
        // WE runs a text object's effects on its rasterised text; the renderer rasterises before effects run.
        layer.weEffects = buildEffectPlans(object.effects ?? [], objectID: id, wallpaperDir: wallpaperDir).plans
        // Drawn through WE's `font` material, which reads its texture as coverage: effects' output
        // isn't that, and `font` has no blend-mode combo, so those layers keep the native draw.
        // Text with font effects draws its coloured raster (`SceneTextEffects`), not coverage.
        if layer.weEffects.isEmpty, (object.colorBlendMode ?? 0) == 0, !textConfig.rastersInColor {
            layer.imageMaterial = buildTextMaterial(object, id: id, wallpaperDir: wallpaperDir)
        }
        return layer
    }

    /// A `shape` object (the light-shaft presets' `"shape": "quad"`): an image object without an
    /// image that only hosts its effects. WE builds it as an image subclass (0x1401907af) whose load
    /// (0x14025fac0) sizes it as a square the scene's orthographic height on each side, and which
    /// writes `DIRECTDRAW` 1 into the combos of every pass of its effects before they load
    /// (0x14025ff50, called per pass at 0x1401e7ad2), so an effect draws on nothing, not on an image.
    private func buildShapeLayer(_ object: WESceneObject, id: Int, wallpaperDir: URL, sceneSize: SIMD2<Float>) -> SceneMetalLayer? {
        guard object.shape != nil, let effects = object.effects, !effects.isEmpty else { return nil }
        let plans = buildEffectPlans(effects, objectID: id, wallpaperDir: wallpaperDir,
                                     objectCombos: Self.shapeEffectCombos).plans
        guard !plans.isEmpty else { return nil }
        let position = localOrigin(for: object)
        let size: SIMD2<Float>
        if let sizeString = object.size {
            let value = sizeString.parseVector2()
            size = SIMD2<Float>(Float(value.0), Float(value.1))
        } else {
            size = Self.shapeSize(sceneSize: sceneSize)
        }
        // Its transform is any object's (the base class 0x1401e6980 reads `scale` as for an image).
        let staticScale = object.scale?.parseVector3() ?? (1, 1, 1)
        var layer = SceneMetalLayer(id: String(id), name: object.name ?? String(id),
                       source: .image(transparentPlaceholderImage), position: position, size: size,
                       scale: SIMD2<Float>(Float(staticScale.0), Float(staticScale.1)),
                       opacity: Float(object.alpha ?? 1),
                       brightness: 1, color: SIMD4<Float>(repeating: 1), text: nil, parallaxDepth: Self.parallaxDepth(of: object), perspective: object.perspective ?? false,
                       rotation: Float(object.angles?.parseVector3().2 ?? 0))
        layer.weEffects = plans
        layer.alignment = object.alignment
        layer.solidFill = SIMD4(1, 1, 1, 0)
        // Its last pass adds to the scene (the shape class's blend state, 0x140260790).
        layer.additive = true
        return layer
    }

    /// The combos a shape object writes into each pass of its effects (0x14025ff50).
    static let shapeEffectCombos = ["DIRECTDRAW": 1]

    /// A shape object's size: the scene's orthographic height on both sides (0x14025fac0 reads
    /// the height the scene stored from `orthogonalprojection` at 0x1401875fb).
    static func shapeSize(sceneSize: SIMD2<Float>) -> SIMD2<Float> {
        SIMD2<Float>(repeating: sceneSize.y)
    }

    /// A fully transparent 1x1 placeholder texture for procedural shape layers (e.g. light shafts) that
    /// have no authored image of their own; only the effect's computed alpha should ever become visible.
    var transparentPlaceholderImage: NSImage {
        Self.pixelImage([1, 1, 1, 0])
    }

    /// The name a text object's `font` is registered under (`SceneTextFontLoader`).
    private func registerFont(_ path: String?) -> String? {
        textFontLoader().register(path)
    }

    /// This wallpaper's font loader, made on first use after a load of a different wallpaper.
    private func textFontLoader() -> SceneTextFontLoader {
        if let fontLoader { return fontLoader }
        let loader = SceneTextFontLoader(package: pkgParser, directory: loadedWallpaperDirectory)
        fontLoader = loader
        return loader
    }

    func isObjectVisible(_ object: WESceneObject, at index: Int) -> Bool {
        SceneUserVisibility.Site(object, at: index).isShown(userProperty)
    }

    func isEffectVisible(_ effect: WEObjectEffect) -> Bool {
        Self.isEffectVisible(effect, userProperty: userProperty)
    }

    /// An effect bound to a user property follows it; with the property missing it keeps its
    /// authored `visible` (default true), as objects do.
    static func isEffectVisible(_ effect: WEObjectEffect, userProperty: (String) -> String?) -> Bool {
        SceneUserVisibility.Gate(visible: effect.visible, condition: effect.visibleCondition,
                                 property: effect.visibleUserProperty).isShown(userProperty)
    }

    /// An object's `parallaxDepth` (WE's 1 1 when absent), as the layer carries it.
    static func parallaxDepth(of object: WESceneObject) -> SIMD3<Float> {
        let value = object.parallaxDepthValue
        return SIMD3<Float>(Float(value.0), Float(value.1), Float(value.2))
    }

    /// How every object that isn't a drawn layer (groups, particle systems) moves, so its
    /// children and its own particles follow it live.
    func objectMotions(_ objects: [WESceneObject], besides layers: [SceneMetalLayer],
                               context: SceneValueContext) -> [String: SceneObjectMotion] {
        let layerIDs = Set(layers.map(\.id))
        var motions: [String: SceneObjectMotion] = [:]
        for object in objects {
            guard let id = object.id.map(String.init), !layerIDs.contains(id) else { continue }
            motions[id] = SceneObjectMotion(object: object,
                                            bindings: SceneLayerBindings(object: object, builtWith: context))
        }
        return motions
    }
}
