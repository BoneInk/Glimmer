import Metal
import simd

/// A Puppet Warp image layer's mesh (docs/models-plan.md §2.13, §4.3 P1): an image whose model JSON
/// names a `"puppet"` `.mdl` draws that mesh, textured by its own image, instead of its quad.
///
/// WE puts the mesh where the quad would be: in the scene for a layer without effects, or into the
/// image-sized buffer its effects start from (0x14020ae00 builds the geometry, 0x140206e5e and
/// 0x140209540 the materials). Here the mesh is always drawn into an image-sized albedo target
/// first, WE's `_rt_imageLayerAlbedo_<id>` (0x140207740): cleared to 0, identity model and view,
/// orthographic over the image's pixels. The layer then goes on as an ordinary image layer whose
/// image is that target: its effects, its prelighting (docs/lighting-plan.md §2.3) and its own
/// draw through its material read it. In the bind pose (every bone the identity) the target is the
/// picture the mesh assembles; M6/P2 pose the bones (`ScenePuppetPose`). A layer with effects
/// draws its bind pose there: its effects run in that layout, where their masks are painted (an
/// atlas rig's parts where the texture keeps them), and the posed mesh lays their output out
/// (`warp`) for the layer's draw, as WE draws a layer's effect output through its geometry.
///
/// The mesh is the rig's first mesh, the only one WE reads (0x14020aeb9). Its vertices are in the
/// image's pixels, y up, centred on the image (every library rig: `(uv − ½) · size` with v flipped,
/// or an atlas laid out anew). WE scales its texture coordinates by the image's share of a padded
/// texture (0x14020b040); the copy here does the same.
final class ScenePuppetPlan {
    /// The `.mdl` the model JSON names.
    let rigPath: String
    /// The layer material's mesh pass (`ImageMaterialPlanBuilder.buildPuppetMesh`).
    let material: ImageMaterialPlan
    let combos: ImagePuppetCombos
    let format: MDLVertexFormat
    /// The mesh's interleaved vertices, texture coordinates scaled to the image inside the texture.
    let vertexData: Data
    let indexData: Data
    let usesUInt32Indices: Bool
    let indexCount: Int
    /// The image in the mesh's units: its full-resolution pixels (before any texture reduction).
    let imageSize: SIMD2<Float>
    /// The image's texels inside its (possibly padded) texture, from its top-left corner.
    let contentPixels: SIMD2<Int>
    /// Bind-pose bone matrices, parents first (the pose M6 starts from).
    let skeleton: MDLSkeleton
    /// The rig's clips (`MDLA`), which the image's animation layers name.
    let clips: [MDLAnimation]
    /// The image's authored `animationlayers` (`ScenePuppetAnimator` plays them).
    let animationLayers: [WEAnimationLayer]
    /// The rig's attachment points (`MDAT`), which children name in `attachment`.
    let attachments: [MDLAttachment]
    /// The first mesh's blend shapes (`MDMP`) and flags: its "morph_<n>" texture and uniforms.
    let morphs: MDLMorphTargets?
    let meshFlags: UInt32
    /// Whether every vertex sits where its texture coordinate puts it in the image: then the bind
    /// pose is the texture as stored. A rig with the texture layout's positions
    /// (`MDLMesh.textureLayoutPositions`) is compared with them, any other by its coordinates
    /// (`isTextureLayout`).
    let bindPoseIsTextureLayout: Bool
    /// The order the parts draw in when the rig's clips key a bone's depth; nil draws the index
    /// buffer as it is.
    let drawOrder: ScenePuppetDrawOrder?
    /// The rig's texture channels, drawn over the image the mesh samples; nil without.
    let channels: ScenePuppetChannelPlan?
    /// The rig's clipping masks (`ScenePuppetClipPlan`); nil without.
    let clipping: ScenePuppetClipPlan?
    /// The rig's box (`MDLModel.bounds`), which a particle `collisionmodel` collides with when the
    /// rig has no per-bone boxes (0x1401d50ac reads the puppet's `.mdl` as a model's); nil unknown.
    let bounds: MDLBounds?

    var boneCount: Int { combos.boneCount }

    init(rigPath: String, material: ImageMaterialPlan, combos: ImagePuppetCombos, mesh: MDLMesh, vertexData: Data,
         imageSize: SIMD2<Float>, contentPixels: SIMD2<Int>, skeleton: MDLSkeleton, clips: [MDLAnimation] = [],
         animationLayers: [WEAnimationLayer] = [], attachments: [MDLAttachment] = [], morphs: MDLMorphTargets? = nil,
         channels: ScenePuppetChannelPlan? = nil, bounds: MDLBounds? = nil, clipping: ScenePuppetClipPlan? = nil) {
        self.rigPath = rigPath
        self.clipping = clipping
        self.bounds = bounds
        self.material = material
        self.combos = combos
        format = mesh.format
        self.vertexData = vertexData
        let drawOrder = ScenePuppetDrawOrder(mesh: mesh, skeleton: skeleton, clips: clips)
        self.drawOrder = drawOrder
        if drawOrder != nil || clipping != nil, !mesh.usesUInt32Indices {
            // Ranges draw from their own offsets, which Metal wants 4-byte aligned: u32 indices.
            indexData = mesh.indices.withUnsafeBytes { Data($0) }
            usesUInt32Indices = true
        } else {
            indexData = mesh.indexData
            usesUInt32Indices = mesh.usesUInt32Indices
        }
        indexCount = mesh.indexCount
        self.imageSize = imageSize
        self.contentPixels = contentPixels
        self.skeleton = skeleton
        self.clips = clips
        self.animationLayers = animationLayers
        self.attachments = attachments
        self.morphs = morphs
        meshFlags = mesh.flags
        self.channels = channels
        if let layout = mesh.textureLayoutPositions {
            bindPoseIsTextureLayout = Self.matches(mesh.vertexData, format: mesh.format, layout: layout)
        } else {
            bindPoseIsTextureLayout = Self.isTextureLayout(mesh.vertexData, format: mesh.format, imageSize: imageSize)
        }
    }

    /// Whether every vertex's position is within a pixel of `layout`'s (the texture layout WE's
    /// editor keeps beside a mesh it moved off it, docs/models-plan.md §1.2).
    static func matches(_ vertexData: Data, format: MDLVertexFormat, layout: [SIMD3<Float>]) -> Bool {
        guard let position = MDLVertexAttribute.named("a_Position").flatMap(format.offset(of:)) else { return true }
        let stride = format.stride
        let count = stride > 0 ? vertexData.count / stride : 0
        guard count == layout.count else { return false }
        return vertexData.withUnsafeBytes { raw in
            func float(_ at: Int) -> Float { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: at, as: UInt32.self))) }
            for vertex in 0..<count {
                let base = vertex * stride + position
                let point = SIMD2(float(base), float(base + 4))
                if simd_reduce_max(simd_abs(point - SIMD2(layout[vertex].x, layout[vertex].y))) > 1 { return false }
            }
            return true
        }
    }

    /// Whether every vertex of `vertexData` (texture coordinates unscaled) is at `(uv − ½)·size`,
    /// v flipped, within a pixel: the rig's bind pose is its texture's layout. A rig that
    /// rearranges an atlas assembles its parts elsewhere. True without positions or coordinates.
    static func isTextureLayout(_ vertexData: Data, format: MDLVertexFormat, imageSize: SIMD2<Float>) -> Bool {
        guard let position = MDLVertexAttribute.named("a_Position").flatMap(format.offset(of:)),
              let texCoord = MDLVertexAttribute.all[7...9].lazy.compactMap(format.offset(of:)).first else { return true }
        let stride = format.stride
        let count = stride > 0 ? vertexData.count / stride : 0
        return vertexData.withUnsafeBytes { raw in
            func float(_ at: Int) -> Float { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: at, as: UInt32.self))) }
            for vertex in 0..<count {
                let base = vertex * stride
                let point = SIMD2(float(base + position), float(base + position + 4))
                let uv = SIMD2(float(base + texCoord), float(base + texCoord + 4))
                let expected = SIMD2((uv.x - 0.5) * imageSize.x, (0.5 - uv.y) * imageSize.y)
                if simd_reduce_max(simd_abs(point - expected)) > 1 { return false }
            }
            return true
        }
    }

    /// The mesh posed by `pose` (skinned as the vertex stage skins it; blend shapes left out), its
    /// bounds in the image's pixels (centred, y up). nil without plain positions, blend indices
    /// and weights.
    func posedBounds(_ pose: ScenePuppetPose) -> (min: SIMD2<Float>, max: SIMD2<Float>)? {
        guard let position = MDLVertexAttribute.named("a_Position").flatMap(format.offset(of:)),
              let indices = MDLVertexAttribute.named("a_BlendIndices").flatMap(format.offset(of:)),
              let weights = MDLVertexAttribute.named("a_BlendWeights").flatMap(format.offset(of:)) else { return nil }
        let stride = format.stride
        let count = stride > 0 ? vertexData.count / stride : 0
        guard count > 0 else { return nil }
        var low = SIMD2<Float>(repeating: .greatestFiniteMagnitude), high = -low
        vertexData.withUnsafeBytes { raw in
            func float(_ at: Int) -> Float { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: at, as: UInt32.self))) }
            for vertex in 0..<count {
                let base = vertex * stride
                let p = SIMD4<Float>(float(base + position), float(base + position + 4), float(base + position + 8), 1)
                var weightsOf = SIMD4<Float>.zero, bonesOf = SIMD4<UInt32>.zero
                for k in 0..<4 {
                    weightsOf[k] = float(base + weights + 4 * k)
                    bonesOf[k] = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: base + indices + 4 * k, as: UInt32.self))
                }
                // The material's own skinning draws the image (weights as stored) and the warp
                // stage lays effect output out (renormalised): the bounds hold both.
                for skinned in [Self.skin(p, weights: weightsOf, bones: bonesOf, pose: pose),
                                Self.skin(p, weights: weightsOf, bones: bonesOf, pose: pose, renormalised: false)] {
                    let point = SIMD2(skinned.x, skinned.y)
                    guard point.x.isFinite, point.y.isFinite else { continue }
                    low = simd_min(low, point)
                    high = simd_max(high, point)
                }
            }
        }
        return low.x <= high.x ? (low, high) : nil
    }

    /// `p` skinned by `pose` as the warp stage skins it (ScenePuppet.metal): Σ wᵢ · bones[iᵢ] · p
    /// over the bones the pose holds, renormalised so the weights used sum to 1 (vertices shared by
    /// two parts land together); a vertex with no usable weight stays at `p`.
    /// Not `renormalised`: Σ wᵢ · bones[iᵢ] · p as stored, as the material's vertex stage skins.
    static func skin(_ p: SIMD4<Float>, weights: SIMD4<Float>, bones: SIMD4<UInt32>, pose: ScenePuppetPose,
                     renormalised: Bool = true) -> SIMD4<Float> {
        var skinned = SIMD4<Float>.zero
        var total: Float = 0
        for k in 0..<4 {
            let bone = Int(bones[k])
            guard weights[k] > 0, bone < pose.bones.count else { continue }
            skinned += weights[k] * (pose.bones[bone] * p)
            total += weights[k]
        }
        guard renormalised else { return skinned }
        return total > 0 ? skinned / total : p
    }

    /// The animator that poses this rig from the image's animation layers; `objectID` is the
    /// image's scene object id, whose layers' timelines run in the wallpaper's `SceneAnimationSet`.
    func makeAnimator(objectID: Int? = nil) -> ScenePuppetAnimator {
        ScenePuppetAnimator(skeleton: skeleton, clips: clips, layers: animationLayers,
                            morphRig: SceneMorphRig.puppet(morphs, meshFlags: meshFlags), objectID: objectID,
                            drawOrder: drawOrder) { [rigPath] layer in
            OWELog.error(.scene, "Puppet rig \(rigPath) has no clip \(layer.animation.map(String.init) ?? "(none)") for "
                         + "animation layer \(layer.name ?? "?"); WE makes no layer for it")
        }
    }

    /// The plan for `model`, the rig of an image drawing `source` (the material's `textures[0]`),
    /// `imageSize` pixels at full resolution. Throws when WE's draw can't be reproduced: no mesh, no
    /// skeleton (`BONECOUNT` 0 declares an empty bone array, which no shader compiles), an albedo
    /// that is a sprite sheet or a video, or a material that doesn't translate.
    static func make(model: MDLModel, rigPath: String, materialPath: String, source: SceneMetalTextureSource,
                     imageSize: SIMD2<Float>, animationLayers: [WEAnimationLayer] = [],
                     builder: ImageMaterialPlanBuilder) throws -> ScenePuppetPlan {
        guard let mesh = model.meshes.first, mesh.vertexCount > 0, mesh.indexCount > 0 else {
            throw ScenePuppetError.unsupported("\(rigPath) has no mesh")
        }
        // Every index drawn must name one of the mesh's vertices, so the draws read inside its buffer.
        if let largest = SceneModelRenderer.largestIndex(mesh.indexData, uint32: mesh.usesUInt32Indices, count: mesh.indexCount),
           largest >= mesh.vertexCount {
            throw ScenePuppetError.unsupported("\(rigPath) indexes vertex \(largest) of its \(mesh.vertexCount)")
        }
        guard let skeleton = model.skeleton, !skeleton.bones.isEmpty else {
            throw ScenePuppetError.unsupported("\(rigPath) has no skeleton")
        }
        guard imageSize.x > 0, imageSize.y > 0 else { throw ScenePuppetError.unsupported("an empty image") }
        let texture: SIMD2<Int>
        let content: SIMD2<Int>
        switch source {
        case let .dxt(compressed):
            texture = SIMD2(compressed.width, compressed.height)
            content = SIMD2(compressed.contentWidth, compressed.contentHeight)
        case let .image(image):
            let size = SceneMetalTextureSource.pixelSize(of: image)
            content = SIMD2(Int(size.x), Int(size.y))
            // A raw .tex image is uploaded as its padded allocation.
            if let raw = TEXRawImageRep.of(image), raw.isPadded {
                texture = SIMD2(raw.rowPixels, raw.allocationRows)
            } else {
                texture = content
            }
        case .animated:
            // WE prelights a sprite-sheet puppet through its `SPRITESHEET` albedo copy (0x14020a27e).
            throw ScenePuppetError.unsupported("a sprite-sheet albedo")
        case .video:
            throw ScenePuppetError.unsupported("a video albedo")
        case let .uploaded(info):
            // Plans are made from loaded content; an uploaded image keeps the sizes they read.
            let sheet = info.sheetPixelSize ?? SIMD2<Double>(info.pixelSize)
            texture = SIMD2(Int(sheet.x), Int(sheet.y))
            content = SIMD2(Int(info.pixelSize.x), Int(info.pixelSize.y))
        }
        guard content.x > 0, content.y > 0, texture.x >= content.x, texture.y >= content.y else {
            throw ScenePuppetError.unsupported("an empty texture")
        }
        let combos = ImagePuppetCombos(mesh: mesh, boneCount: skeleton.bones.count)
        guard let material = try builder.buildPuppetMesh(materialPath: materialPath, puppet: combos),
              material.pass.variant != nil else {
            throw ScenePuppetError.unsupported("\(materialPath) draws no image")
        }
        let fraction = SIMD2(Float(content.x) / Float(texture.x), Float(content.y) / Float(texture.y))
        // Channels that can't draw leave the image as it is; the rig still draws.
        var channels: ScenePuppetChannelPlan?
        do {
            channels = try ScenePuppetChannelPlan.make(model: model, rigPath: rigPath, builder: builder)
        } catch {
            OWELog.error(.scene, "Puppet rig \(rigPath) draws without its texture channels: \(error)")
        }
        // Masks that can't draw leave their parts unclipped; the rig still draws.
        var clipping: ScenePuppetClipPlan?
        do {
            clipping = try ScenePuppetClipPlan.make(mesh: mesh, boneCount: skeleton.bones.count, materialPath: materialPath,
                                                    combos: combos, layerBlending: material.pass.blending,
                                                    builder: builder, rigPath: rigPath)
        } catch {
            OWELog.error(.scene, "Puppet rig \(rigPath) draws without its clipping masks: \(error)")
        }
        return ScenePuppetPlan(rigPath: rigPath, material: material, combos: combos, mesh: mesh,
                               vertexData: scaledTexCoords(mesh, by: fraction), imageSize: imageSize,
                               contentPixels: content, skeleton: skeleton, clips: model.animations ?? [],
                               animationLayers: animationLayers, attachments: model.attachments ?? [],
                               morphs: model.morphTargets?.first { $0.mesh == 0 }, channels: channels,
                               bounds: model.bounds, clipping: clipping)
    }

    /// The vertices with the first texture coordinate's u and v multiplied by `scale`, as WE's copy
    /// does (0x14020afc4…0x14020b100: the offset past position … blend weights, two floats a vertex).
    static func scaledTexCoords(_ mesh: MDLMesh, by scale: SIMD2<Float>) -> Data {
        let texCoords = MDLVertexAttribute.all[7...9]
        guard scale != SIMD2(repeating: 1), texCoords.contains(where: mesh.format.contains) else { return mesh.vertexData }
        let offset = MDLVertexAttribute.all[..<7].reduce(0) { mesh.format.contains($1) ? $0 + $1.byteSize : $0 }
        let stride = mesh.format.stride
        var data = mesh.vertexData
        data.withUnsafeMutableBytes { raw in
            for vertex in 0..<mesh.vertexCount {
                for component in 0..<2 {
                    let at = vertex * stride + offset + 4 * component
                    let value = Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: at, as: UInt32.self)))
                    raw.storeBytes(of: (value * scale[component]).bitPattern.littleEndian, toByteOffset: at, as: UInt32.self)
                }
            }
        }
        return data
    }
}
