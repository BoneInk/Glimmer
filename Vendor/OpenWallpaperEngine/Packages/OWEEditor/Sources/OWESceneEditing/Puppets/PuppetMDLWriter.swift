import Foundation
import simd

/// Writes a document as WE's editor writes a puppet today (docs/models-plan.md §1): `MDLV0023`
/// with one mesh in the puppet format (`0x1800009`: position, four bone indices, four weights,
/// texture coordinate; `a_PositionVec4` instead of the position while the rig keeps blend
/// shapes), then the sections `MDLS0004` (bones, their properties JSON, the rest pose when it
/// differs, the per-bone blocks the rig had), `MDLA0006` (one track per bone, `frames + 1`
/// samples of position, Euler angles and scale), and the kept `MDAT0001`, `MDMP0001` and
/// `MDLE0002`, then the empty tag. Every field is laid out as the app's `MDLReader` reads it.
public enum PuppetMDLWriter {
    /// WE's limit (0x140262501).
    public static let maximumBones = 128
    public static let meshTag = "MDLV0023"
    public static let skeletonTag = "MDLS0004"
    public static let animationTag = "MDLA0006"

    public enum WriteError: Error, Equatable, LocalizedError {
        case problems([PuppetProblem])

        public var errorDescription: String? {
            "The puppet isn't finished: it needs a mesh, at most \(maximumBones) bones, and every vertex weighted."
        }
    }

    /// The `.mdl` bytes.
    public static func write(_ document: PuppetDocument) throws -> Data {
        let problems = document.problems
        guard problems.isEmpty else { throw WriteError.problems(problems) }
        var out = PuppetMDLOutput()
        writeMesh(document, into: &out)
        out.section(skeletonTag, skeleton(document))
        if !document.clips.isEmpty { out.section(animationTag, animations(document)) }
        if !document.preserved.attachments.isEmpty { out.section("MDAT0001", attachments(document)) }
        if let morphs = document.preserved.morphSection, document.preserved.morphIndices?.count == document.mesh.vertices.count {
            out.section("MDMP0001", [UInt8](morphs))
        }
        if let pose = document.preserved.referencePose, pose.count == document.bones.count {
            var body = PuppetMDLOutput()
            body.u32(UInt32(64 * pose.count))
            for matrix in pose { body.f32s(matrix) }
            out.section("MDLE0002", body.bytes)
        }
        out.cstring("")
        return Data(out.bytes)
    }

    // MARK: MDLV

    /// Whether the mesh is written with `a_PositionVec4` (its blend shapes' morph indices).
    static func hasMorphs(_ document: PuppetDocument) -> Bool {
        document.preserved.morphSection != nil && document.preserved.morphIndices?.count == document.mesh.vertices.count
    }

    static func format(_ document: PuppetDocument) -> UInt32 {
        hasMorphs(document) ? PuppetVertexLayout.puppet & ~PuppetVertexLayout.position | PuppetVertexLayout.positionVec4
            : PuppetVertexLayout.puppet
    }

    private static func writeMesh(_ document: PuppetDocument, into out: inout PuppetMDLOutput) {
        let format = format(document)
        let morphs = hasMorphs(document) ? document.preserved.morphIndices : nil
        let vertexCount = document.mesh.vertices.count
        let wide = vertexCount > Int(UInt16.max)
        let channels = document.preserved.textureChannels ?? []
        out.cstring(meshTag)
        out.u32(PuppetVertexLayout.puppet) // the legacy format WE's editor still fills in
        out.u32(1)
        out.u32(UInt32(1 + channels.count))
        out.cstring(document.material)
        var flags = document.preserved.meshFlags & ~1
        if wide { flags |= 1 }
        if document.preserved.meshFlagsExtra == nil { flags &= ~2 }
        out.u32(flags)
        if flags & 2 != 0, let extra = document.preserved.meshFlagsExtra { out.u32(extra) }
        let bounds = boundsOf(document.mesh.vertices.map(\.position))
        let depths = document.mesh.vertices.map { $0.depth ?? 0 }
        out.f32s([bounds.min.x, bounds.min.y, depths.min() ?? 0, bounds.max.x, bounds.max.y, depths.max() ?? 0])
        out.u32(format)
        var vertices = PuppetMDLOutput()
        for (index, vertex) in document.mesh.vertices.enumerated() {
            vertices.f32s([vertex.position.x, vertex.position.y, vertex.depth ?? 0])
            if let morphs { vertices.f32(morphs[index]) }
            let entries = index < document.weights.count ? document.weights[index] : []
            for slot in 0..<4 { vertices.u32(slot < entries.count ? UInt32(entries[slot].bone) : 0) }
            for slot in 0..<4 { vertices.f32(slot < entries.count ? entries[slot].weight : 0) }
            vertices.f32s([vertex.uv.x, vertex.uv.y])
        }
        out.blob(vertices.bytes)
        var indices = PuppetMDLOutput()
        for triangle in document.mesh.triangles {
            for index in [triangle.x, triangle.y, triangle.z] {
                if wide { indices.u32(index) } else { indices.u16(UInt16(index)) }
            }
        }
        out.blob(indices.bytes)
        out.u8(0) // no second position set
        // The parts' index ranges as they were, while the triangles are the ones they split, split
        // again by limb for the clipping masks, which are groups over them.
        let (ranges, groups) = clippingRanges(document)
        if let ranges {
            out.u8(1)
            var block = PuppetMDLOutput()
            for range in ranges { for value in [range.x, range.y, range.z, range.w] { block.u32(value) } }
            out.blob(block.bytes)
        } else {
            out.u8(0)
        }
        out.u32(UInt32(groups.count))
        for group in groups {
            out.u64(group.id)
            out.cstring(group.texture)
            out.u32(group.flags)
            out.u32(UInt32(group.clipped.count))
            for range in group.clipped { out.u32(range) }
            out.u32(UInt32(group.masking.count))
            for range in group.masking { out.u32(range) }
        }
        // The texture channels' meshes as they were: their quads are in the image's pixels, not the puppet's mesh.
        for channel in channels { out.raw([UInt8](channel.bytes)) }
    }

    /// The flags of a clipping mask's group (`MDLClippingMask.Flags` in the app).
    public enum ClipFlags {
        public static let additive: UInt32 = 0x1
        public static let invert: UInt32 = 0x2
        public static let hidesMaskGeometry: UInt32 = 0x4
        /// The clipped limbs draw in their own place; WE 2.8.0.42's editor writes it with Invert
        /// mask (capture 532 g_mask_invert: 0xa) [I: whether anything else sets it].
        public static let drawsInPlace: UInt32 = 0x8
    }

    struct ClipGroup: Equatable {
        var id: UInt64
        var texture: String
        var flags: UInt32
        var clipped: [UInt32]
        var masking: [UInt32]
    }

    /// The ranges the mesh is written with and its clipping masks' groups (docs/models-plan.md
    /// §2.13a). Without a clipped limb: the loaded ranges while they fit, and no groups. With one,
    /// the ranges (the loaded ones, else one per run of triangles of the same bone, each triangle
    /// the bone weighing most on its corners) split where the limb changes, as WE's editor splits
    /// them, without reordering a triangle; a mask clips the ranges of its limbs and is drawn
    /// through those of the limbs it's painted over. Additive when one of its limbs is [I: WE
    /// keeps the blending per limb in its JSON and per mask in the `.mdl`].
    static func clippingRanges(_ document: PuppetDocument) -> (ranges: [SIMD4<UInt32>]?, groups: [ClipGroup]) {
        let triangles = document.mesh.triangles
        let loaded = document.preserved.boneRanges.flatMap { ranges in
            ranges.allSatisfy({ UInt64($0.z) + UInt64($0.w) <= UInt64(3 * triangles.count) && Int($0.x) < document.bones.count })
                ? ranges : nil
        }
        let islands = document.mesh.islands
        guard let clipping = document.clipping, clipping.isActive, clipping.limbs.count == Set(islands).count,
              !triangles.isEmpty else { return (loaded, []) }
        var base = loaded ?? []
        if base.isEmpty || base.reduce(0, { $0 + Int($1.w) }) != 3 * triangles.count {
            base = []
            for (index, triangle) in triangles.enumerated() {
                let bone = UInt32(heaviestBone(document, triangle))
                if let last = base.last, last.x == bone, Int(last.z + last.w) == 3 * index {
                    base[base.count - 1].w += 3
                } else {
                    base.append(SIMD4(bone, 0, UInt32(3 * index), 3))
                }
            }
        }
        var ranges: [SIMD4<UInt32>] = []
        var limbs: [Int] = []
        for range in base {
            var start = Int(range.z) / 3
            let end = start + Int(range.w) / 3
            while start < end {
                var next = start + 1
                while next < end, islands[next] == islands[start] { next += 1 }
                ranges.append(SIMD4(range.x, 0, UInt32(3 * start), UInt32(3 * (next - start))))
                limbs.append(islands[start])
                start = next
            }
        }
        var groups: [ClipGroup] = []
        for mask in clipping.masks {
            let clippedLimbs = Set(clipping.clippedLimbs(of: mask.id))
            guard !clippedLimbs.isEmpty else { continue }
            let masking = Set(mask.maskingLimbs)
            var flags: UInt32 = 0
            if clippedLimbs.contains(where: { clipping.limbs[$0]?.additive == true }) { flags |= ClipFlags.additive }
            if mask.invert { flags |= ClipFlags.invert | ClipFlags.drawsInPlace }
            if mask.hidesMaskGeometry { flags |= ClipFlags.hidesMaskGeometry }
            groups.append(ClipGroup(id: mask.id, texture: mask.texture, flags: flags,
                                    clipped: limbs.indices.filter { clippedLimbs.contains(limbs[$0]) }.map(UInt32.init),
                                    masking: limbs.indices.filter { masking.contains(limbs[$0]) }.map(UInt32.init)))
        }
        return (ranges, groups)
    }

    /// The bone weighing most on the triangle's corners (the lowest on a tie; 0 without weights).
    private static func heaviestBone(_ document: PuppetDocument, _ triangle: SIMD3<UInt32>) -> Int {
        var totals: [Int: Float] = [:]
        for corner in [triangle.x, triangle.y, triangle.z] where Int(corner) < document.weights.count {
            for entry in document.weights[Int(corner)] where entry.bone < document.bones.count { totals[entry.bone, default: 0] += entry.weight }
        }
        return totals.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key ?? 0
    }

    static func boundsOf(_ points: [SIMD2<Float>]) -> (min: SIMD2<Float>, max: SIMD2<Float>) {
        guard var low = points.first else { return (.zero, .zero) }
        var high = low
        for point in points {
            low = simd_min(low, point)
            high = simd_max(high, point)
        }
        return (low, high)
    }

    // MARK: MDLS

    /// Each bone's properties: its physics compiled as WE's compiler writes them over the keys
    /// the editor doesn't edit.
    public static func boneProperties(_ document: PuppetDocument) -> [[String: SceneJSONValue]] {
        let worlds = document.bindWorlds
        return document.bones.indices.map { index in
            let bone = document.bones[index]
            var properties = bone.otherProperties
            if let physics = bone.physics {
                let child = document.children(of: index).first
                let distance = child.map { simd_distance(PuppetMath.origin(of: worlds[$0]), PuppetMath.origin(of: worlds[index])) }
                for (key, value) in physics.properties(childDistance: distance) { properties[key] = value }
            }
            if let ik = bone.ik {
                for (key, value) in ik.properties { properties[key] = value }
            }
            return properties
        }
    }

    static func propertiesJSON(_ properties: [String: SceneJSONValue]) -> String {
        guard !properties.isEmpty else { return "" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(properties) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func skeleton(_ document: PuppetDocument) -> [UInt8] {
        var out = PuppetMDLOutput()
        let properties = boneProperties(document)
        // The kinematic chains as WE's compiler lays them out (`PuppetKinematicsLayout`): flag
        // 0x2 on every chain bone, the controllers as links, the lengths, maps and IK sets.
        let layout = PuppetKinematicsLayout(document)
        out.u32(UInt32(document.bones.count))
        for (index, bone) in document.bones.enumerated() {
            out.cstring(bone.name)
            out.u32(bone.flags & ~2 | (layout.chainBones.contains(index) ? 2 : 0))
            out.u32(bone.parent.map { UInt32($0) } ?? 0xFFFF_FFFF)
            out.u32(64)
            out.matrix(bone.local.matrix)
            out.cstring(propertiesJSON(properties[index]))
        }
        out.u16(UInt16(layout.links.count))
        for link in layout.links {
            out.cstring("")
            out.u32(UInt32(link.bone))
            out.u32(link.type)
            out.matrix(Self.linkMatrix(link.rest))
        }
        let hasRest = document.bones.contains { $0.rest != nil }
        out.u8(hasRest ? 1 : 0)
        if hasRest {
            for bone in document.bones { out.matrix((bone.rest ?? bone.local).matrix) }
            for link in layout.links { out.matrix(Self.linkMatrix(link.rest)) }
        }
        // Blend rules (docs/models-plan.md §2.15): bone, weight index, target, flags, floats.
        let order = document.blendRuleOrder
        out.u32(UInt32(order.count))
        for (index, place) in order.enumerated() {
            let rule = document.bones[place.bone].blendRules![place.rule]
            out.u32(UInt32(place.bone))
            out.u32(UInt32(index))
            out.u32(UInt32(rule.target))
            let floats = rule.flags & 2 != 0 ? rule.floats : nil
            out.u32(floats == nil ? rule.flags & ~2 : rule.flags)
            if let floats { out.f32s([floats.x, floats.y]) }
        }
        if layout.isEmpty {
            out.u16(0) // maps
            out.u16(0) // IK sets
        } else {
            // Each bone's length to its parent as the map's u32 id, and its children's directions.
            out.u16(UInt16(document.bones.count))
            for length in layout.lengths { out.u32(length.bitPattern) }
            for axes in layout.restAxes {
                out.u16(UInt16(axes.count))
                for entry in axes {
                    out.u32(UInt32(entry.child))
                    out.f32s([entry.axis.x, entry.axis.y, entry.axis.z])
                }
            }
            out.u16(UInt16(layout.sets.count))
            for set in layout.sets {
                out.u32(UInt32(set.bone))
                out.u32(UInt32(set.links.count))
                for link in set.links { out.u32(UInt32(link)) }
                out.u16(1) // one element, on the set's own bone
                out.u32(UInt32(set.bone))
                out.u16(UInt16(set.joints.count))
                for joint in set.joints {
                    out.u32(UInt32(joint.bone))
                    out.u32(joint.flags)
                    out.f32(joint.length)
                    out.f32(0)
                    out.u16(UInt16(joint.bones.count))
                    for bone in joint.bones { out.u32(UInt32(bone)) }
                }
            }
        }
        let count = document.bones.count
        if let boxes = document.preserved.boneBoxes, boxes.count == count {
            out.u8(1)
            for box in boxes {
                out.f32s([box.vector.x, box.vector.y, box.vector.z])
                out.f32s(box.matrix)
            }
        } else {
            out.u8(0)
        }
        if let indices = document.preserved.boneIndices, indices.count == count {
            out.u8(1)
            for index in indices { out.u32(min(index, UInt32(count - 1))) }
        } else {
            out.u8(0)
        }
        if let priorities = document.preserved.bonePriorities, priorities.count == count {
            out.u8(1)
            for priority in priorities { out.u32(priority) }
        } else {
            out.u8(0)
        }
        return out.bytes
    }

    /// A controller's rest matrix: a translation.
    static func linkMatrix(_ place: SIMD2<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(place.x, place.y, 0, 1)
        return m
    }

    // MARK: MDLA

    private static func animations(_ document: PuppetDocument) -> [UInt8] {
        var out = PuppetMDLOutput()
        let rest = document.restLocals
        let rig = PuppetRig(document)
        let layout = PuppetKinematicsLayout(document)
        out.i32(Int32(document.clips.count))
        for (index, clip) in document.clips.enumerated() {
            let frames = max(clip.frames, 1)
            var flags = clip.flags
            var record: PuppetClip.RootMotion?
            if let motion = clip.rootMotion, let source = motion.sourceClip, source < index {
                record = motion
            } else {
                flags &= ~PuppetClip.RootMotion.referenceFlag
            }
            out.u64(clip.id)
            out.cstring(clip.name)
            out.cstring(clip.modeName ?? clip.mode.rawValue)
            out.f32(clip.fps)
            out.u32(UInt32(frames))
            out.u32(flags)
            out.i32(Int32(document.bones.count))
            for bone in document.bones.indices {
                let samples = PuppetClipBaker.samples(of: clip, bone: bone, rest: rest[bone])
                out.u32(samples == nil ? 1 : 0)
                var blob = PuppetMDLOutput()
                for frame in 0...frames {
                    blob.f32s((samples.map { $0[min(frame, $0.count - 1)] } ?? rest[bone]).samples)
                }
                out.blob(blob.bytes)
            }
            // A2: each controller's place a frame (rest plus its keyed offset, its keyed angle);
            // one constraint track per blend rule, its weight a sample a frame.
            for index in layout.links.indices {
                out.u32(0)
                var blob = PuppetMDLOutput()
                for frame in 0...frames {
                    let key = layout.linkPose(index, document: document, clip: clip.id, frame: Float(frame))
                    blob.f32s([key.offset.x, key.offset.y, 0, 0, 0, key.angle, 1, 1, 1])
                }
                out.blob(blob.bytes)
            }
            for place in document.blendRuleOrder {
                out.u32(0)
                var blob = PuppetMDLOutput()
                for value in document.bones[place.bone].blendRules![place.rule].samples(clip: clip.id, frames: frames) {
                    blob.f32(value)
                }
                out.blob(blob.bytes)
            }
            // A3: the texture channels' tracks, one sample a frame (the last held past its end).
            let channelTracks = clip.channelTracks ?? []
            out.u32(UInt32(channelTracks.count))
            for track in channelTracks {
                out.u32(track.tag)
                var blob = PuppetMDLOutput()
                for frame in 0...frames { blob.f32(track.sample(frame)) }
                out.blob(blob.bytes)
            }
            // A3: each bone's keyed Opacity, when the clip has it.
            writeBoneScalars(clip.boneAlphaTracks, bones: document.bones.count, frames: frames, rest: 1, into: &out)
            out.u8(0)  // A4: no morph-weight tracks
            let bounds = animatedBounds(document, rig: rig, clip: index)
            out.f32s([bounds.min.x, bounds.min.y, 0, bounds.max.x, bounds.max.y, 0])
            // A6: each bone's keyed Depth offset, when the clip has it.
            writeBoneScalars(clip.boneDepthTracks, bones: document.bones.count, frames: frames, rest: 0, into: &out)
            if let record, let source = record.sourceClip {
                // 0x140265232: with root motion and without Match loop the frames must lie in the clip.
                let limit = frames
                let start = record.matchLoop ? record.startFrame : min(max(record.startFrame, 0), limit)
                let end = record.matchLoop ? record.endFrame : min(max(record.endFrame, 0), limit)
                out.u16(UInt16(source))
                out.u32(UInt32(max(start, 0)))
                out.u32(UInt32(max(end, 0)))
                out.u32(UInt32(max(record.frameOffset, 0)))
                out.i32(record.rootBone.map { Int32($0) } ?? -1)
            }
            out.i32(Int32(clip.events.count))
            for event in clip.events {
                out.f32(event.frame)
                out.cstring(event.name)
            }
        }
        return out.bytes
    }

    /// `u8` 0 without `tracks`, else `u8` 1 and one track per bone (`rest` for a bone without
    /// one), a sample per frame, the last held past its end.
    private static func writeBoneScalars(_ tracks: [PuppetChannelTrack]?, bones: Int, frames: Int, rest: Float,
                                         into out: inout PuppetMDLOutput) {
        guard let tracks else {
            out.u8(0)
            return
        }
        out.u8(1)
        for bone in 0..<bones {
            let track = tracks.indices.contains(bone) ? tracks[bone] : PuppetChannelTrack(tag: 0, samples: [rest])
            out.u32(track.tag)
            var blob = PuppetMDLOutput()
            for frame in 0...frames { blob.f32(track.samples.isEmpty ? rest : track.sample(frame)) }
            out.blob(blob.bytes)
        }
    }

    /// The posed mesh's box over every frame of the clip (`MDLA` 5's animated box).
    static func animatedBounds(_ document: PuppetDocument, rig: PuppetRig, clip: Int) -> (min: SIMD2<Float>, max: SIMD2<Float>) {
        var points: [SIMD2<Float>] = []
        let frames = max(document.clips[clip].frames, 1)
        for frame in 0...frames {
            let palette = rig.palette(worlds: rig.worlds(clip: clip, frame: Float(frame)))
            let skinned = PuppetRig.skin(document, palette: palette)
            let box = boundsOf(skinned)
            points += [box.min, box.max]
        }
        return boundsOf(points)
    }

    // MARK: MDAT

    private static func attachments(_ document: PuppetDocument) -> [UInt8] {
        var out = PuppetMDLOutput()
        out.u16(UInt16(document.preserved.attachments.count))
        for attachment in document.preserved.attachments {
            out.u16(UInt16(attachment.bone))
            out.cstring(attachment.name)
            out.f32s(attachment.matrix)
        }
        return out.bytes
    }
}
