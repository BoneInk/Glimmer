/// The per-bone values a Puppet Warp clip keys besides the bones' transforms (docs/models-plan.md
/// §2.13): each bone's Opacity (`MDLAnimation.boneAlphaTracks`) and Depth offset
/// (`boneDepthTracks`), laid over each other by the layers as the texture channels are
/// (`SceneAnimationLayerStack.applyScalars`). Each list is empty when the rig keys none, and
/// starts every frame from the rest values, as the bones start from their bind pose [I].
struct SceneBoneScalars: Equatable {
    /// `g_BonesAlpha`: 1 at rest.
    var alpha: [Float] = []
    /// Added to each bone's depth: 0 at rest.
    var depth: [Float] = []
    /// The blend rules' weights (`SceneBlendRules`), one per constraint track: 0 until a layer
    /// sets them, then kept from frame to frame as WE keeps rig+0x250.
    var blendRules: [Float] = []

    /// The rest values for a rig of `boneCount` bones, with a list only where a clip keys it.
    static func rest(boneCount: Int, clips: [MDLAnimation]) -> SceneBoneScalars {
        SceneBoneScalars(alpha: clips.contains { !($0.boneAlphaTracks ?? []).isEmpty } ? Array(repeating: 1, count: boneCount) : [],
                         depth: clips.contains { !($0.boneDepthTracks ?? []).isEmpty } ? Array(repeating: 0, count: boneCount) : [])
    }
}

/// The order a puppet's parts draw in (Puppet Warp's "Limb Depth Order"; docs/models-plan.md
/// §2.13). The editor writes one index range per bone (`MDLMesh.BoneRange`) in order of the
/// bones' depths (`MDLSkeleton.boneDepths`), lowest first, so a later part draws over an earlier
/// one. A static depth is baked in that order: WE 2.8 draws a bone moved to the back with
/// "Move Limb to Back" (depth 100 → 0, level with the other part) where it was, over the other
/// part (capture 509 B, `b_clip_order`). A clip's keyed Depth offset reorders the ranges at run
/// time: with blue keyed −200 over its 100 for the first 30 frames, its part draws under red's
/// (`b_clip_keyed_order`). Here each bone's depth is its file depth plus its keyed offset, and the
/// ranges draw sorted by it, ties in file order [I: whether WE adds the track to the file depth
/// or replaces it gives the same order in that capture].
struct ScenePuppetDrawOrder: Equatable {
    /// An index range drawn as one call: `indexCount` indices from `firstIndex`.
    struct Range: Equatable {
        var firstIndex: Int
        var indexCount: Int
    }

    let ranges: [MDLMesh.BoneRange]
    /// Each bone's depth from the file, 0 for a bone without one.
    let depths: [Float]

    /// nil for a mesh without ranges that split its whole index buffer, or a rig whose clips key
    /// no depth (no depth tracks, and mesh flag 0x8, which WE's editor sets with them, off): its
    /// index buffer draws as it is.
    init?(mesh: MDLMesh, skeleton: MDLSkeleton, clips: [MDLAnimation]) {
        guard mesh.keyedDrawOrder || clips.contains(where: { !($0.boneDepthTracks ?? []).isEmpty }),
              let ranges = mesh.boneRanges(boneCount: skeleton.bones.count), !ranges.isEmpty else { return nil }
        // Every index in exactly one range, so reordering them draws every triangle once.
        var next = 0
        for range in ranges.sorted(by: { $0.firstIndex < $1.firstIndex }) {
            guard range.firstIndex == next else { return nil }
            next += range.indexCount
        }
        guard next == mesh.indexCount else { return nil }
        self.ranges = ranges
        let depths = skeleton.boneDepths ?? []
        self.depths = skeleton.bones.indices.map { $0 < depths.count ? Float(depths[$0]) : 0 }
    }

    /// The ranges in drawing order for the keyed `offsets` (one per bone; missing ones 0),
    /// adjacent ranges merged into one draw.
    func ranges(offsets: [Float]) -> [Range] {
        func depth(_ bone: Int) -> Float { (bone < depths.count ? depths[bone] : 0) + (bone < offsets.count ? offsets[bone] : 0) }
        let sorted = ranges.indices.sorted { a, b in
            let da = depth(ranges[a].bone), db = depth(ranges[b].bone)
            return da != db ? da < db : a < b
        }
        var out: [Range] = []
        for index in sorted where ranges[index].indexCount > 0 {
            let range = ranges[index]
            if let last = out.last, last.firstIndex + last.indexCount == range.firstIndex {
                out[out.count - 1].indexCount += range.indexCount
            } else {
                out.append(Range(firstIndex: range.firstIndex, indexCount: range.indexCount))
            }
        }
        return out
    }
}
