import Foundation

extension MDLReader {
    /// The `MDLA` section (0x1402639b2…0x140265486; docs/models-plan.md §1.4). The link,
    /// constraint and mesh counts come from the sections already read.
    public static func readAnimations(_ r: inout MDLByteReader, version: Int, model: MDLModel) throws -> [MDLAnimation] {
        let count = Int(try r.i32())
        var clips: [MDLAnimation] = []
        for index in 0..<max(count, 0) {
            clips.append(try readAnimation(&r, index: index, version: version, model: model))
        }
        return clips
    }

    private static func readAnimation(_ r: inout MDLByteReader, index: Int, version: Int,
                                      model: MDLModel) throws -> MDLAnimation {
        let links = model.skeleton?.links.count ?? 0
        let constraints = model.skeleton?.constraints.count ?? 0
        let id = try r.u64()
        let name = try r.cstring()
        let mode = try r.cstring()
        let fps = try r.f32()
        let frames = try r.u32()
        let flags = try r.u32()
        let samples = Int(frames) + 1
        let trackCount = Int(try r.i32())
        var boneTracks: [MDLAnimation.Track] = []
        for _ in 0..<max(trackCount, 0) {
            let trackFlags = try r.u32()
            boneTracks.append(.init(flags: trackFlags, samples: try track(&r, floats: 9 * samples, "bone track")))
        }
        var clip = MDLAnimation(id: id, name: name, modeName: mode, fps: fps, frames: frames, flags: flags,
                                boneTracks: boneTracks, events: [])
        if version >= 2 {
            clip.linkTracks = try (0..<links).map { _ in
                MDLAnimation.Track(flags: try r.u32(), samples: try track(&r, floats: 9 * samples, "link track"))
            }
            clip.constraintTracks = try scalarTracks(&r, count: constraints, samples: samples, "constraint track")
        }
        if version >= 3 {
            clip.scalarTracksA = try scalarTracks(&r, count: Int(try r.u32()), samples: samples, "scalar track")
            if try r.u8() != 0 {
                clip.scalarTracksB = try scalarTracks(&r, count: boneTracks.count, samples: samples, "scalar track")
            }
        }
        if version >= 4, try r.u8() != 0 {
            clip.meshTracks = try (0..<model.meshes.count).map { _ in try meshTrack(&r, samples: samples) }
        }
        if version >= 5 {
            let b = try r.f32s(6)
            clip.bounds = MDLBounds(min: SIMD3(b[0], b[1], b[2]), max: SIMD3(b[3], b[4], b[5]))
        }
        if version >= 6, try r.u8() != 0 {
            clip.scalarTracksC = try scalarTracks(&r, count: boneTracks.count, samples: samples, "scalar track")
        }
        if flags & MDLAnimation.Flag.reference != 0 {
            let animation = try r.u16()
            let values = try r.u32s(4)
            // 0x14026519a: WE fast-fails unless the clip it is relative to comes before it.
            guard Int(animation) < index else { throw MDLError.malformed("clip \(index) relative to clip \(animation)") }
            // 0x140265232…0x140265245: with root motion and without Match loop (which reads frames
            // 0 and `frames`), the Start and End frames must lie within this clip's frame count.
            if flags & MDLAnimation.Flag.rootMotion != 0, flags & MDLAnimation.Flag.matchLoop == 0,
               max(values[0], values[1]) > frames {
                throw MDLError.malformed("clip \(index)'s root-motion frames \(values[0])…\(values[1]) past its \(frames)")
            }
            clip.reference = .init(animation: animation, startFrame: values[0], endFrame: values[1],
                                   frameOffset: values[2], rootBone: Int32(bitPattern: values[3]))
        }
        let eventCount = Int(try r.i32())
        for _ in 0..<max(eventCount, 0) {
            let frame = try r.f32()
            clip.events.append(.init(frame: frame, name: try r.cstring()))
        }
        return clip
    }

    /// A blob of exactly `floats` f32s (WE fast-fails on another size, 0x140263c8c).
    private static func track(_ r: inout MDLByteReader, floats count: Int, _ what: String) throws -> [Float] {
        let size = Int(try r.u32())
        try r.need(size, what)
        guard size == 4 * count else { throw MDLError.malformed("\(what) of \(size) bytes, not \(4 * count)") }
        return floats(try r.raw(size, what))
    }

    private static func scalarTracks(_ r: inout MDLByteReader, count: Int, samples: Int,
                                     _ what: String) throws -> [MDLAnimation.ScalarTrack] {
        try (0..<count).map { _ in
            MDLAnimation.ScalarTrack(tag: try r.u32(), samples: try track(&r, floats: samples, what))
        }
    }

    private static func meshTrack(_ r: inout MDLByteReader, samples: Int) throws -> MDLAnimation.MeshTrack {
        var mesh = MDLAnimation.MeshTrack(flags: try r.u32())
        if mesh.flags & 1 != 0 {
            mesh.weight = try r.f32()
            mesh.morphTracks = try (0..<(try r.u16())).map { _ in
                MDLAnimation.MeshTrack.MorphTrack(morph: try r.u16(), samples: try track(&r, floats: samples, "morph weight track"))
            }
        }
        return mesh
    }

    /// The `MDMP0001` section (0x1402656e5…0x140265886; docs/models-plan.md §1.5): per mesh, its
    /// targets, with the blobs the mesh's flags select.
    public static func readMorphTargets(_ r: inout MDLByteReader, model: MDLModel) throws -> [MDLMorphTargets] {
        let bones = model.skeleton?.bones.count ?? 0
        return try model.meshes.enumerated().map { index, mesh in
            let count = try r.u16()
            var morphs = MDLMorphTargets(mesh: index, targets: [])
            guard count > 0 else { return morphs }
            morphs.weight = try r.f32()
            var vertices = Int(try r.u32())
            for _ in 0..<count {
                let id = try r.u64()
                let name = try r.cstring()
                let positions = try r.blob("morph positions")
                vertices = min(vertices, positions.count / 6)  // 0x14026578f
                guard positions.count == 6 * vertices else {
                    throw MDLError.malformed("morph positions of \(positions.count) bytes for \(vertices) vertices")
                }
                var target = MDLMorphTargets.Target(id: id, name: name, positions: snorms(positions))
                if mesh.flags & 0x400 != 0 { target.normals = snorms(try morphBlob(&r, 6 * vertices, "morph normals")) }
                if mesh.flags & 0x800 != 0 { target.tangents = snorms(try morphBlob(&r, 6 * vertices, "morph tangents")) }
                if mesh.flags & 0x1000 != 0 { target.extra = Data(try morphBlob(&r, 2 * vertices, "morph extra")) }
                if mesh.flags & 0x2000 != 0 {
                    let modifier = MDLMorphTargets.Target.Modifier(bone: try r.u32(), mode: try r.u32(),
                                                                  startDistance: try r.f32(), endDistance: try r.f32())
                    guard Int(modifier.bone) < bones else { throw MDLError.malformed("morph modifier bone \(modifier.bone) >= \(bones)") }
                    target.modifier = modifier
                }
                morphs.targets.append(target)
            }
            morphs.vertexCount = UInt32(vertices)
            return morphs
        }
    }

    private static func morphBlob(_ r: inout MDLByteReader, _ size: Int, _ what: String) throws -> ArraySlice<UInt8> {
        let blob = try r.blob(what)
        guard blob.count == size else { throw MDLError.malformed("\(what) of \(blob.count) bytes, not \(size)") }
        return blob
    }

    /// The blob's 16-bit signed normalised values (`MDLMorphTargets.positions`).
    private static func snorms(_ bytes: ArraySlice<UInt8>) -> [Float] {
        bytes.withUnsafeBytes { raw in
            (0..<(raw.count / 2)).map {
                MDLMorphTargets.float(snormBits: raw.loadUnaligned(fromByteOffset: 2 * $0, as: UInt16.self).littleEndian)
            }
        }
    }
}
