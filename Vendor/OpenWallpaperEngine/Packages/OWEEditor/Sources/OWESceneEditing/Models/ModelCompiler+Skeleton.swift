import Foundation
import simd

extension ModelCompiler {
    /// The `MDLS` bones of a skinned model: the root ("RootNode"), every node a skin deforms
    /// with and every ancestor of one, in the source's order (parents first), as WE's importer
    /// keeps them (the library's skinned imports: PaRappa's `windows_front.mdl` keeps RootNode,
    /// the mesh's object, the armature and its bones; docs/models-plan.md §1.3, capture 509 D).
    struct Skeleton {
        struct Bone {
            var name: String
            var parent: Int?
            var local: simd_float4x4
            var isBone: Bool
            var sourceNode: Int
        }

        var nodes: [Bone]
        /// Source node index → bone index.
        var map: [Int: Int]
        let rest: [simd_float4x4]

        init(_ source: ModelSource) {
            // The nodes the skins deform with, and the node of each mesh without a skin, which
            // moves with the model (capture 546: the static "Plinth" is a bone, flag 1, and its
            // mesh is bound to it).
            let skinBones = Set(source.meshes.flatMap { mesh -> [Int] in
                (mesh.influences ?? []).flatMap { i in (0..<4).compactMap { i.weights[$0] > 0 ? Int(i.nodes[$0]) : nil } }
            })
            let meshNodes = Set(source.meshes.compactMap { $0.influences == nil && !$0.positions.isEmpty ? $0.node : nil })
            let used = skinBones.union(meshNodes)
            func chain(_ node: Int, into set: inout Set<Int>) {
                var current: Int? = node
                while let index = current, set.insert(index).inserted { current = source.nodes[index].parent }
            }
            var skeleton = Set<Int>()
            for node in source.nodes.indices where source.nodes[node].isBone || skinBones.contains(node) { chain(node, into: &skeleton) }
            if !source.nodes.isEmpty { skeleton.insert(0) }
            var needed = skeleton
            for node in meshNodes { chain(node, into: &needed) }
            // Parents first by depth; at a depth the skeleton's nodes (the skins' bones and
            // their ancestors) before the other meshes' nodes, each in the file's order
            // (capture 546 keeps RootNode, Rig, Plinth, root, arm: the armature Rig before
            // the static Plinth, which the file lists first).
            var depth = Array(repeating: 0, count: source.nodes.count)
            for (index, node) in source.nodes.enumerated() {
                if let parent = node.parent, parent < index { depth[index] = depth[parent] + 1 }
            }
            let order = source.nodes.indices.filter { needed.contains($0) }.sorted {
                (depth[$0], skeleton.contains($0) ? 0 : 1, $0) < (depth[$1], skeleton.contains($1) ? 0 : 1, $1)
            }
            var bones: [Bone] = []
            var map: [Int: Int] = [:]
            for index in order {
                let node = source.nodes[index]
                map[index] = bones.count
                let name = node.parent == nil && node.name.isEmpty ? "RootNode" : node.name
                bones.append(Bone(name: name, parent: node.parent.flatMap { map[$0] }, local: node.local,
                                  isBone: node.isBone || used.contains(index), sourceNode: index))
            }
            nodes = bones
            self.map = map
            rest = PuppetMath.worlds(locals: bones.map(\.local), parents: bones.map(\.parent))
        }

        func index(of name: String) -> Int? { nodes.firstIndex { $0.name == name } }

        /// A corner's influences by bone index.
        func remap(_ influences: ModelSource.Influences) -> ModelSource.Influences {
            var out = influences
            for slot in 0..<4 { out.nodes[slot] = influences.weights[slot] > 0 ? UInt32(map[Int(influences.nodes[slot])] ?? 0) : 0 }
            return out
        }

        /// A mesh without a skin in a skinned model moves with its node (else the root).
        func influence(of mesh: ModelSource.Mesh) -> ModelSource.Influences {
            ModelSource.Influences(nodes: SIMD4(UInt32(mesh.node.flatMap { map[$0] } ?? 0), 0, 0, 0), weights: SIMD4(1, 0, 0, 0))
        }

        func children(of bone: Int) -> [Int] { nodes.indices.filter { nodes[$0].parent == bone } }

        /// The `MDLS0004` body: bones with their properties JSON (the configuration's
        /// constraint, `ModelCompiler.compiledConstraint`), no links, constraints, maps or IK sets, and the bone
        /// boxes; no draw-order arrays.
        func section(meshes: [CompiledMesh], config: ModelImportConfig) -> [UInt8] {
            var out = PuppetMDLOutput()
            out.u32(UInt32(nodes.count))
            for (index, bone) in nodes.enumerated() {
                out.cstring(bone.name)
                out.u32(bone.isBone ? 1 : 0)
                out.u32(bone.parent.map { UInt32($0) } ?? 0xFFFF_FFFF)
                out.u32(64)
                out.matrix(bone.local)
                var properties = ""
                if config.constraints[bone.name] != nil || config.constraintSettings[bone.name] != nil {
                    let child = children(of: index).first
                    let distance = child.map { simd_distance(origin(rest[$0]), origin(rest[index])) }
                    properties = PuppetMDLWriter.propertiesJSON(ModelCompiler.compiledConstraint(config, bone: bone.name,
                                                                                                 childDistance: distance))
                }
                out.cstring(properties)
            }
            out.u16(0) // links
            out.u8(0)  // no separate bind matrices
            out.u32(0) // constraints
            out.u16(0) // maps
            out.u16(0) // IK sets
            out.u8(1)  // the bone boxes
            for (center, half) in boxes(meshes) {
                out.f32s([half.x, half.y, half.z])
                out.matrix(simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(center, 1))))
            }
            out.u8(0)  // no draw order (Puppet Warp's arrays)
            out.u8(0)
            return out.bytes
        }

        /// Per bone, the box of the vertices it moves (any weight) in its bind space: its centre
        /// and half size; zero for a bone that moves none. PaRappa's doors match this exactly.
        func boxes(_ meshes: [CompiledMesh]) -> [(SIMD3<Float>, SIMD3<Float>)] {
            var low = Array(repeating: SIMD3<Float>(repeating: .greatestFiniteMagnitude), count: nodes.count)
            var high = Array(repeating: SIMD3<Float>(repeating: -.greatestFiniteMagnitude), count: nodes.count)
            let inverses = rest.map(\.inverse)
            for mesh in meshes {
                for (p, influence) in zip(mesh.positions, mesh.influences) {
                    for slot in 0..<4 where influence.weights[slot] > 0 {
                        let bone = Int(influence.nodes[slot])
                        guard bone < nodes.count else { continue }
                        let q = inverses[bone] * SIMD4(p, 1)
                        let local = SIMD3(q.x, q.y, q.z)
                        low[bone] = simd_min(low[bone], local)
                        high[bone] = simd_max(high[bone], local)
                    }
                }
            }
            return nodes.indices.map { bone in
                low[bone].x > high[bone].x ? (.zero, .zero) : ((low[bone] + high[bone]) / 2, (high[bone] - low[bone]) / 2)
            }
        }

        func origin(_ m: simd_float4x4) -> SIMD3<Float> { SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z) }

        // MARK: Animations

        /// A sampled animation by bone: `frames + 1` local transforms per bone.
        struct Track {
            var name: String
            var fps: Float
            var frames: Int
            var samples: [[PuppetTransform]]
        }

        /// The source's animations, then each additional file's, matched to these bones by name;
        /// a bone an animation doesn't have keeps its rest pose.
        func animations(_ source: ModelSource, additional: [ModelSource]) -> [Track] {
            var tracks: [Track] = []
            for animation in source.animations {
                tracks.append(Track(name: animation.name, fps: animation.fps, frames: animation.frames,
                                    samples: nodes.map { bone in
                                        let samples = animation.samples.indices.contains(bone.sourceNode) ? animation.samples[bone.sourceNode] : []
                                        return samples.isEmpty ? [PuppetTransform(matrix: bone.local)] : samples
                                    }))
            }
            for file in additional {
                for animation in file.animations {
                    tracks.append(Track(name: animation.name, fps: animation.fps, frames: animation.frames,
                                        samples: nodes.map { bone in
                                            let index = file.nodes.firstIndex { $0.name == bone.name }
                                            let samples = index.flatMap { animation.samples.indices.contains($0) ? animation.samples[$0] : nil } ?? []
                                            return samples.isEmpty ? [PuppetTransform(matrix: bone.local)] : samples
                                        }))
                }
            }
            return tracks
        }

        /// One `MDLA` record.
        struct Record {
            var id: UInt64
            var name: String
            var mode: String
            var fps: Float
            var frames: Int
            var flags: UInt32
            var samples: [[PuppetTransform]]
            var reference: (source: Int, start: Int, end: Int, offset: Int, rootBone: Int32)?
            var events: [(Float, String)]
        }

        /// The animations (`animationmapping`'s ids, else 1, 2, …) and then the configuration's
        /// clips cut from them.
        func records(_ tracks: [Track], config: ModelImportConfig) -> [Record] {
            let ids = config.animationIDs(tracks.map(\.name))
            var records: [Record] = zip(ids, tracks).map { id, track in
                return Record(id: id, name: track.name, mode: "loop", fps: track.fps, frames: max(track.frames, 1), flags: 0,
                              samples: track.samples, reference: nil, events: events(config, id))
            }
            for clip in config.clips {
                guard let sourceIndex = records.prefix(tracks.count).firstIndex(where: { $0.id == clip.animation }) else { continue }
                let source = records[sourceIndex]
                let start = min(max(clip.start, 0), source.frames)
                let end = min(max(clip.end, start), source.frames)
                let frames = max(end - start, 1)
                let samples = source.samples.map { bone in
                    (0...frames).map { frame in bone[min(start + frame, bone.count - 1)] }
                }
                // The clip record (0x1), Match loop (0x400) and the configuration's `motionflags`
                // as they are (capture 546: 43008 with Match loop is 0xAC01).
                var flags: UInt32 = 0x1 | clip.motionFlags & ~0x4FF
                if clip.matchLoop { flags |= 0x400 }
                let rootBone = clip.rootMotion.isEmpty ? -1 : Int32(index(of: clip.rootMotion) ?? -1)
                records.append(Record(id: clip.id, name: clip.name, mode: clip.mode, fps: clip.fps ?? source.fps, frames: frames,
                                      flags: flags, samples: samples,
                                      reference: (sourceIndex, start, end, max(clip.frameOffset, 0), rootBone),
                                      events: events(config, clip.id)))
            }
            return records
        }

        func events(_ config: ModelImportConfig, _ animation: UInt64) -> [(Float, String)] {
            config.events.filter { $0.animation == animation }.sorted { $0.frame < $1.frame }.map { ($0.frame, $0.name) }
        }

        func animationSection(_ records: [Record], meshes: [CompiledMesh], config: ModelImportConfig) -> [UInt8] {
            var out = PuppetMDLOutput()
            out.i32(Int32(records.count))
            for record in records {
                out.u64(record.id)
                out.cstring(record.name)
                out.cstring(record.mode)
                out.f32(record.fps)
                out.u32(UInt32(record.frames))
                out.u32(record.flags)
                out.i32(Int32(nodes.count))
                for bone in nodes.indices {
                    out.u32(0)
                    var blob = PuppetMDLOutput()
                    let samples = record.samples[bone]
                    for frame in 0...record.frames {
                        blob.f32s(samples[min(frame, samples.count - 1)].samples)
                    }
                    out.blob(blob.bytes)
                }
                // MDLA 2: no link or constraint tracks (none in the skeleton).
                out.u32(0) // MDLA 3: no texture-channel tracks
                out.u8(0)  //         no per-bone opacity
                out.u8(0)  // MDLA 4: no morph weights
                let (low, high) = animatedBounds(record, meshes: meshes)
                out.f32s([low.x, low.y, low.z, high.x, high.y, high.z])  // MDLA 5
                out.u8(0)  // MDLA 6: no per-bone depth
                if let reference = record.reference {
                    out.u16(UInt16(reference.source))
                    out.u32(UInt32(reference.start))
                    out.u32(UInt32(reference.end))
                    out.u32(UInt32(reference.offset))
                    out.i32(reference.rootBone)
                }
                out.i32(Int32(record.events.count))
                for (frame, name) in record.events {
                    out.f32(frame)
                    out.cstring(name)
                }
            }
            return out.bytes
        }

        /// The skinned meshes' box over every frame (`MDLA` 5): each frame's palette
        /// (`world(pose) · world(rest)⁻¹`) applied to every vertex.
        func animatedBounds(_ record: Record, meshes: [CompiledMesh]) -> (SIMD3<Float>, SIMD3<Float>) {
            let inverses = rest.map(\.inverse)
            var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude), high = -low
            for frame in 0...record.frames {
                let locals = nodes.indices.map { bone -> simd_float4x4 in
                    let samples = record.samples[bone]
                    return PuppetPoseTransform(samples[min(frame, samples.count - 1)]).matrix
                }
                let worlds = PuppetMath.worlds(locals: locals, parents: nodes.map(\.parent))
                let palette = zip(worlds, inverses).map { $0 * $1 }
                for mesh in meshes {
                    for (p, influence) in zip(mesh.positions, mesh.influences) {
                        var skinned = SIMD4<Float>.zero
                        for slot in 0..<4 where influence.weights[slot] > 0 {
                            skinned += palette[min(Int(influence.nodes[slot]), palette.count - 1)] * SIMD4(p, 1) * influence.weights[slot]
                        }
                        let q = SIMD3(skinned.x, skinned.y, skinned.z)
                        low = simd_min(low, q)
                        high = simd_max(high, q)
                    }
                }
            }
            return low.x > high.x ? (.zero, .zero) : (low, high)
        }
    }
}

extension ModelCompiler {
    /// A bone's properties JSON as WE's compiler writes it from the configuration's constraint
    /// (`resourcecompiler64.exe` 0x1400b0270; capture 546): every setting the Model Editor saves
    /// (`ModelImportConfig.constraintConfig`) passed through, with
    /// - `tp`, the tip: the forward direction `a` times the tip size `s` (0: the distance to the
    ///   first child, else 100), as `"%.5f %.5f %.5f"`;
    /// - `lamin`/`lamax`, when both are strings, `rax`/`ray`/`raz` are bools and both limits'
    ///   z angles are non-zero: the z angle on each simulated axis, 0 on the others (WE's 3D
    ///   editor limits one angle; "0 0 ±π/2" with every axis on compiles to "±1.57080" thrice);
    /// - `tm` 10 when it isn't above 0.
    public static func compiledConstraint(_ config: ModelImportConfig, bone: String, childDistance: Float?) -> [String: SceneJSONValue] {
        var settings = config.constraintConfig(bone)
        let physics = config.constraints[bone]
        if let physics {
            settings.merge(physics.properties(childDistance: childDistance)) { old, new in ModelImportConfig.sameSetting(old, new) ? old : new }
        }
        if physics == nil {
            var tip = PuppetBonePhysics()
            tip.tipSize = Float(settings["s"]?.numberValue ?? 0)
            if case .string(let a)? = settings["a"] { tip.forward = PuppetPhysicsConstraint.vector(a) }
            settings["tp"] = .string(PuppetBonePhysics.tipString(tip.tip(childDistance: childDistance)))
        }
        func axis(_ key: String) -> Bool? { if case .bool(let on)? = settings[key] { return on } else { return nil } }
        if case .string(let low)? = settings["lamin"], case .string(let high)? = settings["lamax"],
           let x = axis("rax"), let y = axis("ray"), let z = axis("raz") {
            let lowZ = PuppetPhysicsConstraint.vector(low).z, highZ = PuppetPhysicsConstraint.vector(high).z
            if lowZ != 0, highZ != 0 {
                func limit(_ angle: Float) -> SIMD3<Float> { SIMD3(x ? angle : 0, y ? angle : 0, z ? angle : 0) }
                settings["lamin"] = .string(PuppetBonePhysics.tipString(limit(lowZ)))
                settings["lamax"] = .string(PuppetBonePhysics.tipString(limit(highZ)))
            }
        }
        if (settings["tm"]?.numberValue ?? 0) <= 0 { settings["tm"] = .number(10) }
        return settings
    }
}
