import Foundation
import simd
import WEFormat

/// Reads an installed puppet's `.mdl` into the editor. The file is read by WEFormat's `MDLReader`,
/// the reader the player draws it with (every version WE's runtime reads: `MDLV` 4–23, `MDLS`
/// 1–4, `MDLA` 1–6; docs/models-plan.md §1), so the editor opens exactly what the wallpaper shows.
/// The puppet is the first mesh (the only one WE draws, 0x14020aeb9) with its skeleton, weights
/// and clips; what the editor doesn't edit is kept (`PuppetPreservedData`) or, for data no library
/// rig has (morph-weight tracks), left out. Constraints are Puppet Warp's blend rules
/// (`PuppetBlendRule`); IK sets with their links and link tracks are its kinematic chains and
/// their controllers (`PuppetBoneIK`).
public enum PuppetMDLReader {
    /// `imageSize`: the image's pixels (the mesh's space has no size of its own).
    public static func read(_ data: Data, imageSize: SIMD2<Float>, sourcePath: String? = nil) throws -> PuppetDocument {
        let (model, meshRanges) = try readModel(data)
        guard let first = model.meshes.first.map(RawMesh.init) else { throw PuppetMDLError.unsupported("no mesh") }
        var channels: [PuppetPreservedData.TextureChannelMesh] = []
        for (mesh, range) in zip(model.meshes, meshRanges).dropFirst()
        where mesh.flags & 2 != 0 && model.materialsPerMesh == 1 && model.version == 23 {
            // Texture channels, kept byte for byte for the writer's MDLV0023.
            let raw = RawMesh(mesh)
            channels.append(.init(material: raw.material, blendRows: mesh.flagsExtra ?? 1,
                                  channelCount: channelCount(raw), bytes: data.subdata(in: range.offset(by: data.startIndex))))
        }
        var document = PuppetDocument(imageSize: imageSize, material: first.material, sourcePath: sourcePath)
        try decode(first, into: &document)
        if !channels.isEmpty { document.preserved.textureChannels = channels }
        guard model.version >= 13 else { throw PuppetMDLError.unsupported("no skeleton") }
        var links: [LinkRecord] = []
        var constraints: [(bone: Int, rule: Int)?] = []
        if let skeleton = model.skeleton {
            (links, constraints) = read(skeleton, into: &document)
        }
        let boneCount = document.bones.count
        if let clips = model.animations, let version = model.animationsVersion {
            read(clips, version: version, links: links, constraints: constraints, into: &document)
        }
        for attachment in model.attachments ?? [] {
            document.preserved.attachments.append(.init(bone: Int(attachment.bone), name: attachment.name,
                                                        matrix: floats(attachment.matrix)))
        }
        if let morphs = model.sections.last(where: { $0.tag == "MDMP0001" }) {
            // The section's body as the file has it: after the tag, its NUL and the u32 end.
            let body = morphs.offset + morphs.tag.utf8.count + 1 + 4
            document.preserved.morphSection = data.subdata(in: (body..<morphs.end).offset(by: data.startIndex))
        }
        if let pose = model.referencePose, pose.count == boneCount {
            document.preserved.referencePose = pose.map(floats)
        }
        guard !document.bones.isEmpty else { throw PuppetMDLError.unsupported("no skeleton") }
        if document.preserved.morphSection != nil, document.preserved.morphIndices == nil { document.preserved.morphSection = nil }
        if document.preserved.morphSection == nil { document.preserved.morphIndices = nil }
        // Weights naming a bone the rig doesn't have count for nothing.
        document.weights = document.weights.map { PuppetWeight.normalized($0.filter { $0.bone < boneCount }) }
        return document
    }

    /// The model and where each mesh's record lies in the file, with `MDLReader`'s errors as the
    /// editor reports them.
    private static func readModel(_ data: Data) throws -> (MDLModel, [Range<Int>]) {
        do {
            return try MDLReader.readWithMeshRanges(data)
        } catch let error as MDLError {
            switch error {
            case .truncated(let what, let offset): throw PuppetMDLError.truncated(what, offset: offset)
            case .notAModel: throw PuppetMDLError.notAModel
            case .tooManyBones(let count): throw PuppetMDLError.malformed("\(count) bones")
            case .malformed(let reason): throw PuppetMDLError.malformed(reason)
            case .missing(let path): throw PuppetMDLError.malformed("no model file \(path)")
            }
        }
    }

    /// A matrix's 16 floats in the file's order.
    private static func floats(_ matrix: simd_float4x4) -> [Float] {
        [matrix.columns.0, matrix.columns.1, matrix.columns.2, matrix.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
    }

    // MARK: MDLV

    struct RawMesh {
        var material: String
        var flags: UInt32
        var flagsExtra: UInt32?
        var format: UInt32
        var vertices: Data
        var indices: Data
        /// The 16-byte records after the vertices (`MDLV` 21 and later), as u32s.
        var boneRanges: [SIMD4<UInt32>]?
        /// `MDLV` 23's groups: the clipping masks.
        var groups: [Group] = []

        init(_ mesh: MDLMesh) {
            material = mesh.materials.first ?? ""
            flags = mesh.flags
            flagsExtra = mesh.flagsExtra
            format = mesh.format.rawValue
            vertices = mesh.vertexData
            indices = mesh.indexData
            boneRanges = mesh.vector4Block?.map { SIMD4($0.x.bitPattern, $0.y.bitPattern, $0.z.bitPattern, $0.w.bitPattern) }
            groups = (mesh.groups ?? []).map {
                Group(id: $0.id, texture: $0.name, flags: $0.flags, clipped: $0.listA, masking: $0.listB)
            }
        }
    }

    struct Group {
        var id: UInt64
        var texture: String
        var flags: UInt32
        var clipped: [UInt32]
        var masking: [UInt32]
    }

    /// The channels a texture-channel mesh's quads name: the largest `a_BlendIndices.x` + 1.
    private static func channelCount(_ mesh: RawMesh) -> Int {
        let size = PuppetVertexLayout.stride(mesh.format)
        guard size > 0, let offset = PuppetVertexLayout.offset(of: PuppetVertexLayout.blendIndices, in: mesh.format) else { return 0 }
        let bytes = Array(mesh.vertices)
        return stride(from: 0, to: bytes.count - size + 1, by: size).map { base -> Int in
            let at = base + offset
            return Int(UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24) + 1
        }.max() ?? 0
    }

    private static func decode(_ mesh: RawMesh, into document: inout PuppetDocument) throws {
        let stride = PuppetVertexLayout.stride(mesh.format)
        guard stride > 0, mesh.vertices.count % stride == 0 else { throw PuppetMDLError.malformed("vertex stride") }
        let positionOffset = PuppetVertexLayout.offset(of: PuppetVertexLayout.position, in: mesh.format)
        let vec4Offset = PuppetVertexLayout.offset(of: PuppetVertexLayout.positionVec4, in: mesh.format)
        guard let position = positionOffset ?? vec4Offset else { throw PuppetMDLError.unsupported("no positions") }
        let texCoord = [PuppetVertexLayout.texCoord, PuppetVertexLayout.texCoordVec3, PuppetVertexLayout.texCoordVec4]
            .lazy.compactMap { PuppetVertexLayout.offset(of: $0, in: mesh.format) }.first
        let blendIndices = PuppetVertexLayout.offset(of: PuppetVertexLayout.blendIndices, in: mesh.format)
        let blendWeights = PuppetVertexLayout.offset(of: PuppetVertexLayout.blendWeights, in: mesh.format)
        let count = mesh.vertices.count / stride
        let bytes = Array(mesh.vertices)
        func u32(_ at: Int) -> UInt32 {
            UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
        }
        func f32(_ at: Int) -> Float { Float(bitPattern: u32(at)) }
        var vertices: [PuppetVertex] = []
        var weights: [[PuppetWeight]] = []
        var morphs: [Float] = []
        for vertex in 0..<count {
            let base = vertex * stride
            let point = SIMD2(f32(base + position), f32(base + position + 4))
            let uv = texCoord.map { SIMD2(f32(base + $0), f32(base + $0 + 4)) } ?? document.textureCoordinate(of: point)
            let depth = f32(base + position + 8)
            vertices.append(PuppetVertex(position: point, uv: uv, depth: depth == 0 ? nil : depth))
            if positionOffset == nil, vec4Offset != nil { morphs.append(f32(base + position + 12)) }
            var entries: [PuppetWeight] = []
            if let blendIndices, let blendWeights {
                for slot in 0..<4 {
                    entries.append(PuppetWeight(bone: Int(u32(base + blendIndices + 4 * slot)),
                                                weight: f32(base + blendWeights + 4 * slot)))
                }
            }
            weights.append(PuppetWeight.normalized(entries))
        }
        let indexSize = mesh.flags & 1 != 0 ? 4 : 2
        guard mesh.indices.count % (3 * indexSize) == 0 else { throw PuppetMDLError.malformed("index count") }
        let indexBytes = Array(mesh.indices)
        var triangles: [SIMD3<UInt32>] = []
        for triangle in 0..<(indexBytes.count / (3 * indexSize)) {
            var corners = SIMD3<UInt32>.zero
            for corner in 0..<3 {
                let at = (3 * triangle + corner) * indexSize
                corners[corner] = indexSize == 4
                    ? UInt32(indexBytes[at]) | UInt32(indexBytes[at + 1]) << 8 | UInt32(indexBytes[at + 2]) << 16 | UInt32(indexBytes[at + 3]) << 24
                    : UInt32(indexBytes[at]) | UInt32(indexBytes[at + 1]) << 8
            }
            guard Int(corners.max()) < count else { throw PuppetMDLError.malformed("index past the vertices") }
            triangles.append(corners)
        }
        document.mesh = PuppetMesh(vertices: vertices, triangles: triangles)
        document.weights = weights
        document.preserved.meshFlags = mesh.flags & ~1
        document.preserved.meshFlagsExtra = mesh.flagsExtra
        if !morphs.isEmpty { document.preserved.morphIndices = morphs }
        if let ranges = mesh.boneRanges, !ranges.isEmpty, ranges.allSatisfy({ UInt64($0.z) + UInt64($0.w) <= UInt64(3 * triangles.count) }) {
            document.preserved.boneRanges = ranges
            document.clipping = clipping(mesh.groups, ranges: ranges, mesh: document.mesh)
        }
    }

    /// The first mesh's groups as the file has them (tests, diagnostics).
    static func rawGroups(_ data: Data) throws -> [Group] {
        try readModel(data).0.meshes.first.map(RawMesh.init)?.groups ?? []
    }

    /// The groups as clipping masks over the mesh's limbs: each range lies in one island (WE's
    /// editor splits them so), the island of its first triangle. nil without groups, or with one
    /// that names a range the mesh doesn't have.
    static func clipping(_ groups: [Group], ranges: [SIMD4<UInt32>], mesh: PuppetMesh) -> PuppetClipping? {
        guard !groups.isEmpty else { return nil }
        let islands = mesh.islands
        func limb(_ range: UInt32) -> Int? {
            guard Int(range) < ranges.count, ranges[Int(range)].w > 0 else { return nil }
            let triangle = Int(ranges[Int(range)].z) / 3
            return triangle < islands.count ? islands[triangle] : nil
        }
        guard groups.allSatisfy({ ($0.clipped + $0.masking).allSatisfy { Int($0) < ranges.count } }) else { return nil }
        var clipping = PuppetClipping(masks: [], limbs: Array(repeating: nil, count: Set(islands).count))
        for group in groups {
            clipping.masks.append(PuppetClipping.Mask(
                id: group.id, name: "", texture: group.texture,
                invert: group.flags & PuppetMDLWriter.ClipFlags.invert != 0,
                hidesMaskGeometry: group.flags & PuppetMDLWriter.ClipFlags.hidesMaskGeometry != 0,
                maskingLimbs: Array(Set(group.masking.compactMap(limb))).sorted()))
            for island in Set(group.clipped.compactMap(limb)) {
                clipping.limbs[island] = PuppetClipping.Limb(mask: group.id, additive: group.flags & PuppetMDLWriter.ClipFlags.additive != 0)
            }
        }
        return clipping
    }

    // MARK: MDLS

    /// The bones, then the skeleton's links (for the clips' link tracks) and where each constraint
    /// went as a blend rule (for the clips' constraint tracks).
    private static func read(_ skeleton: MDLSkeleton,
                             into document: inout PuppetDocument) -> (links: [LinkRecord], constraints: [(bone: Int, rule: Int)?]) {
        let count = skeleton.bones.count
        var propertiesText: [String] = []
        document.bones = skeleton.bones.enumerated().map { index, file in
            propertiesText.append(file.properties)
            var bone = PuppetBone(name: file.name,
                                  parent: file.parent == 0xFFFF_FFFF || Int(file.parent) >= index ? nil : Int(file.parent),
                                  local: PuppetTransform(matrix: file.matrix), flags: file.flags)
            if let object = Self.properties(file.properties) {
                bone.physics = PuppetBonePhysics(properties: object)
                bone.otherProperties = bone.physics == nil ? object : object.filter { !PuppetBonePhysics.keys.contains($0.key) }
            }
            return bone
        }
        guard skeleton.version >= 2 else { return ([], []) }
        var linkRecords = skeleton.links.map {
            LinkRecord(bone: Int($0.bone), type: $0.type, rest: SIMD2($0.matrix.columns.3.x, $0.matrix.columns.3.y))
        }
        for (index, matrix) in (skeleton.bindMatrices ?? []).enumerated() {
            let rest = PuppetTransform(matrix: matrix)
            if !rest.isClose(to: document.bones[index].local, tolerance: 1e-6) { document.bones[index].rest = rest }
        }
        // Constraints: blend rules (docs/models-plan.md §2.15), each placed on its bone; one on a
        // flag-0x2 bone hangs on a link (IK), which the editor leaves out, as one out of range.
        var constraints: [(bone: Int, rule: Int)?] = []
        for constraint in skeleton.constraints {
            let bone = Int(constraint.bone), target = Int(constraint.b)
            guard bone < count, target < count, bone != target, document.bones[bone].flags & 2 == 0 else {
                constraints.append(nil)
                continue
            }
            let floats = constraint.f0.flatMap { f0 in constraint.f1.map { SIMD2(f0, $0) } }
            var rules = document.bones[bone].blendRules ?? []
            rules.append(PuppetBlendRule(target: target, flags: constraint.flags, floats: floats))
            document.bones[bone].blendRules = rules
            constraints.append((bone, rules.count - 1))
        }
        // IK sets: each joint's end bone with `ik` in its properties is a kinematic chain (a rope
        // with joint flag 0x4); the links on that bone are its controllers.
        for joint in skeleton.ikSets.lazy.flatMap(\.elements).flatMap(\.joints) {
            let bone = Int(joint.bone)
            guard bone < count, document.bones[bone].ik == nil,
                  let ik = PuppetBoneIK(properties: Self.properties(propertiesText[bone]) ?? [:],
                                        rope: joint.flags & 0x4 != 0) else { continue }
            document.bones[bone].ik = ik
            document.bones[bone].otherProperties = document.bones[bone].otherProperties
                .filter { !PuppetBoneIK.keys.contains($0.key) }
            for index in linkRecords.indices where linkRecords[index].bone == bone {
                linkRecords[index].chainEnd = bone
                if linkRecords[index].type == 1 { document.bones[bone].ik!.orientationRest = linkRecords[index].rest }
            }
        }
        if let boxes = skeleton.boneVectors {
            document.preserved.boneBoxes = boxes.map { .init(vector: $0.vector, matrix: floats($0.matrix)) }
        }
        document.preserved.boneIndices = skeleton.boneIndices
        document.preserved.bonePriorities = skeleton.bonePriorities
        return (linkRecords, constraints)
    }

    /// A link as `MDLS` has it: its bone, type (0 the IK target, 1 the orientation controller)
    /// and rest place; `chainEnd` is the chain it controls once the IK sets are read.
    struct LinkRecord {
        var bone: Int
        var type: UInt32
        var rest: SIMD2<Float>
        var chainEnd: Int?
    }

    /// A bone's properties JSON as an object; nil when empty or not an object.
    static func properties(_ text: String) -> [String: SceneJSONValue]? {
        guard !text.isEmpty, let data = text.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              case .object(let object)? = SceneJSONValue(any: any) else { return nil }
        return object
    }

    // MARK: MDLA

    private static func read(_ clips: [MDLAnimation], version: Int, links: [LinkRecord],
                             constraints: [(bone: Int, rule: Int)?], into document: inout PuppetDocument) {
        for file in clips {
            let id = file.id
            let samples = Int(file.frames) + 1
            var tracks: [PuppetTrack] = file.boneTracks.prefix(document.bones.count).map { track in
                guard !track.isDisabled else { return PuppetTrack() }
                let transforms = (0..<samples).map { PuppetTransform(samples: track.samples[(9 * $0)..<(9 * $0 + 9)]) }
                return PuppetTrack(keys: PuppetClipBaker.keys(from: transforms))
            }
            while tracks.count < document.bones.count { tracks.append(PuppetTrack()) }
            if version >= 2 {
                for (link, track) in zip(links, file.linkTracks ?? []) {
                    let values = track.samples
                    guard !track.isDisabled, values.count == 9 * samples, let bone = link.chainEnd,
                          document.bones[bone].ik != nil else { continue }
                    // The controller's keys: its place each frame less its rest place.
                    let keys = (0..<samples).map { frame in
                        PuppetBoneIK.Key(offset: SIMD2(values[9 * frame], values[9 * frame + 1]) - link.rest,
                                         angle: values[9 * frame + 5])
                    }
                    guard keys.contains(where: { simd_length($0.offset) > 1e-4 || abs($0.angle) > 1e-6 }) else { continue }
                    let kept = Set(PuppetBlendRule.keys(from: keys.map(\.offset.x)).keys)
                        .union(PuppetBlendRule.keys(from: keys.map(\.offset.y)).keys)
                        .union(PuppetBlendRule.keys(from: keys.map(\.angle)).keys)
                    for frame in kept {
                        document.bones[bone].ik!.setKey(link.type == 1 ? .orientation : .target, clip: id, frame: frame,
                                                        to: keys[frame])
                    }
                }
                for (placement, track) in zip(constraints, file.constraintTracks ?? []) {
                    guard let placement, track.tag & 1 == 0, !track.samples.isEmpty else { continue }
                    document.bones[placement.bone].blendRules?[placement.rule].weights[id] = PuppetBlendRule.keys(from: track.samples)
                }
            }
            let flags = file.flags
            var clip = PuppetClip(id: id, name: file.name, mode: PuppetClip.Mode(rawValue: file.modeName) ?? .loop,
                                  fps: file.fps, frames: Int(file.frames), tracks: tracks,
                                  otherFlags: flags & ~PuppetClip.RootMotion.ownedFlags)
            let channelTracks = (file.scalarTracksA ?? []).map { PuppetChannelTrack(tag: $0.tag, samples: $0.samples) }
            if !channelTracks.isEmpty { clip.channelTracks = channelTracks }
            // One per bone the document kept; a bone past the file's tracks at rest.
            let boneCount = document.bones.count
            func perBone(_ tracks: [MDLAnimation.ScalarTrack]?, rest: Float) -> [PuppetChannelTrack]? {
                tracks.map { tracks in
                    (0..<boneCount).map {
                        tracks.indices.contains($0) ? PuppetChannelTrack(tag: tracks[$0].tag, samples: tracks[$0].samples)
                            : PuppetChannelTrack(tag: 0, samples: [rest])
                    }
                }
            }
            clip.boneAlphaTracks = perBone(file.boneAlphaTracks, rest: 1)
            clip.boneDepthTracks = perBone(file.boneDepthTracks, rest: 0)
            if PuppetClip.Mode(rawValue: file.modeName) == nil { clip.modeName = file.modeName }
            if flags & PuppetClip.RootMotion.ownedFlags != 0 {
                var motion = PuppetClip.RootMotion(matchLoop: flags & PuppetClip.RootMotion.matchLoopFlag != 0,
                                                   positionX: flags & PuppetClip.RootMotion.positionXFlag != 0,
                                                   positionY: flags & PuppetClip.RootMotion.positionYFlag != 0,
                                                   positionZ: flags & PuppetClip.RootMotion.positionZFlag != 0,
                                                   rotationY: flags & PuppetClip.RootMotion.rotationYFlag != 0)
                if let reference = file.reference {
                    motion.sourceClip = Int(reference.animation)
                    motion.startFrame = Int(reference.startFrame)
                    motion.endFrame = Int(reference.endFrame)
                    motion.frameOffset = Int(reference.frameOffset)
                    let root = reference.rootBone
                    motion.rootBone = root >= 0 && Int(root) < document.bones.count ? Int(root) : nil
                }
                clip.rootMotion = motion
            }
            clip.events = file.events.map { PuppetClipEvent(frame: $0.frame, name: $0.name) }
            document.clips.append(clip)
        }
    }
}

private extension Range where Bound == Int {
    /// The range moved by `offset` (a `Data` slice's indices start at its `startIndex`).
    func offset(by offset: Int) -> Range<Int> { (lowerBound + offset)..<(upperBound + offset) }
}
