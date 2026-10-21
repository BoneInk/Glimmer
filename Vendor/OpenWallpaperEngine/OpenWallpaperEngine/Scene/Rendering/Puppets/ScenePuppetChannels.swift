import Foundation
import simd

/// A puppet's texture channels (Puppet Warp › Texture Channels): WE's editor compiles them into
/// the rig's `.mdl` as a second mesh with flag 0x2 (`MDLMesh.isTextureChannelMesh`): a quad per
/// channel element in the base image's pixels (y up, from its bottom-left corner), drawn through
/// its own material (`puppettexturechannels`, `g_Texture0` the channels' atlas, `g_Texture1` the
/// base image) with `a_TexCoordVec4` = (atlas uv, base image uv) and `a_BlendIndices.x` the
/// channel's entry in `g_BlendMap`. The puppet json's `texturechannels` block is the editor's
/// source; the runtime reads only the `.mdl` (no "texturechannels" string in wallpaper64.exe).
///
/// WE draws it into the puppet's image-sized albedo target before the puppet's mesh samples it
/// (0x140207740): the target (the base texture's size) cleared, the image copied in by a quad
/// (`materials/util/fullscreenlayer.json`, puppet+0x410), then the channel mesh (puppet+0x408
/// material, +0x3f8 mesh) orthographic over the texture's pixels, blended over it, with
/// `g_BlendMap` = the first `BLENDROWCOUNT` rows of the channel weights (puppet+0x350,
/// 0x1402079c5). A rig with such a mesh takes that path (0x1402095de: puppet+0x390, the first
/// flag-0x2 mesh, ≥ 0); its own mesh then samples the target. WE 2.8.42's RenderDoc capture of
/// the rope shows the three draws: the copy, the channel quad (stride 44: position, blend
/// indices, `a_TexCoordVec4`; `g_BlendMap` 0, `g_Texture1Resolution` 96 512 96 512) and the
/// puppet sampling the target, which at the default weight 0 is the image exactly.
final class ScenePuppetChannelPlan {
    /// The channel material's pass (`ImageMaterialPlanBuilder.buildPuppetTextureChannels`).
    let material: ImageMaterialPlan
    let format: MDLVertexFormat
    let vertexData: Data
    let indexData: Data
    let usesUInt32Indices: Bool
    let indexCount: Int
    /// `BLENDROWCOUNT`: the `vec4` rows of `g_BlendMap` the draw reads (the mesh's `flagsExtra`).
    let blendRows: Int
    /// The channels the quads name (the largest `a_BlendIndices.x` + 1).
    let channelCount: Int

    init(material: ImageMaterialPlan, mesh: MDLMesh, blendRows: Int) {
        self.material = material
        format = mesh.format
        vertexData = mesh.vertexData
        indexData = mesh.indexData
        usesUInt32Indices = mesh.usesUInt32Indices
        indexCount = mesh.indexCount
        self.blendRows = blendRows
        let indices = mesh.unsignedValues(.blendIndices) ?? []
        channelCount = stride(from: 0, to: indices.count, by: 4).map { Int(indices[$0]) + 1 }.max() ?? 0
    }

    /// `DOUBLEBUFFERED`: the shader discards where the channel's weight is ≤ 0.001 and mixes the
    /// base image with the channel by it elsewhere. Without it (WE's draw) the channel's alpha is
    /// scaled by its weight, clamped to 0…1, and its colour by `max(1, weight)`.
    var isDoubleBuffered: Bool { (material.pass.variant?.combos["DOUBLEBUFFERED"] ?? 0) != 0 }

    /// Whether the draw changes the image at weights `blendMap`. While every channel the quads
    /// name weighs ≤ 0 (≤ 0.001 double-buffered) each fragment is discarded or has alpha 0, and
    /// the draw, blended over the image, leaves it as it is: WE's capture at the default weight 0
    /// samples a target identical to the image.
    func drawsAnything(blendMap: [Float]) -> Bool {
        let threshold: Float = isDoubleBuffered ? 0.001 : 0
        return (0..<min(channelCount, blendMap.count)).contains { blendMap[$0] > threshold }
    }

    /// `g_BlendMap` from the channel weights: `blendRows` × 4 floats, 0 past the weights.
    func blendMapComponents(_ weights: [Float]) -> [Float] {
        (0..<(4 * blendRows)).map { $0 < weights.count ? weights[$0] : 0 }
    }

    /// The plan for the rig's first mesh with flag 0x2, nil without one. Throws when its
    /// material can't draw: no material, a vertex layout WE's shader can't read or a material
    /// that doesn't translate.
    static func make(model: MDLModel, rigPath: String, builder: ImageMaterialPlanBuilder) throws -> ScenePuppetChannelPlan? {
        guard let mesh = model.meshes.first(where: \.isTextureChannelMesh) else { return nil }
        guard let materialPath = mesh.materials.first, !materialPath.isEmpty else {
            throw ScenePuppetError.unsupported("\(rigPath)'s texture channels name no material")
        }
        guard mesh.vertexCount > 0, mesh.indexCount > 0 else { return nil }
        if let largest = SceneModelRenderer.largestIndex(mesh.indexData, uint32: mesh.usesUInt32Indices, count: mesh.indexCount),
           largest >= mesh.vertexCount {
            throw ScenePuppetError.unsupported("\(rigPath)'s texture channels index vertex \(largest) of \(mesh.vertexCount)")
        }
        guard mesh.format.contains(.position), mesh.format.contains(.blendIndices),
              let texCoordVec4 = MDLVertexAttribute.named("a_TexCoordVec4"), mesh.format.contains(texCoordVec4) else {
            throw ScenePuppetError.unsupported("\(rigPath)'s texture channels have vertex format \(mesh.format)")
        }
        // WE keeps 16 weights (puppet+0x350…0x38f): at most 4 rows.
        let rows = Int(mesh.flagsExtra ?? 1)
        guard rows >= 1, rows <= SceneAnimationLayerStack.maximumTextureChannels / 4 else {
            throw ScenePuppetError.unsupported("\(rigPath)'s texture channels have \(rows) blend rows")
        }
        guard let material = try builder.buildPuppetTextureChannels(materialPath: materialPath, blendRows: rows),
              material.pass.variant != nil else {
            throw ScenePuppetError.unsupported("\(materialPath) draws no texture channels")
        }
        return ScenePuppetChannelPlan(material: material, mesh: mesh, blendRows: rows)
    }
}

extension SceneAnimationLayerStack {
    /// The channel weights WE keeps per puppet (puppet+0x350…0x38f).
    static let maximumTextureChannels = 16

    /// Lays one layer's texture-channel tracks (`MDLAnimation.scalarTracksA`) over `channels`
    /// with its weight, as the puppet update does (0x1401fefa0…0x1401ffa2e): each track lerped
    /// between the layer's two frames, then a layer of weight 1 sets the channel, an additive one
    /// adds `value · w` and any other lerps from the channel's value by `w`. Channels past the
    /// clip's tracks keep theirs.
    func applyChannels(_ layer: SceneAnimationLayer, weight: Float, to channels: inout [Float]) {
        applyScalars(layer, \.scalarTracksA, weight: weight, to: &channels)
    }

    /// Lays one layer's scalar tracks of the list `list` over `values` (one per track, in order)
    /// as `applyChannels` describes; WE's puppet update samples every scalar list alike.
    func applyScalars(_ layer: SceneAnimationLayer, _ list: KeyPath<MDLAnimation, [MDLAnimation.ScalarTrack]?>,
                      weight: Float, to channels: inout [Float]) {
        let (clip, first) = source(of: layer.clip)
        guard weight != 0, let tracks = clip[keyPath: list], !tracks.isEmpty else { return }
        let position = layer.clock.samplePosition
        let t = position.fraction
        for (channel, track) in tracks.enumerated() where channel < channels.count && !track.samples.isEmpty {
            let last = track.samples.count - 1
            let a = track.samples[max(0, min(Int(position.frame0) + first, last))]
            let b = track.samples[max(0, min(Int(position.frame1) + first, last))]
            let value = (1 - t) * a + t * b
            if layer.additive {
                channels[channel] += value * weight
            } else if weight == 1 {
                channels[channel] = value
            } else {
                channels[channel] += (value - channels[channel]) * weight
            }
        }
    }
}
