import Foundation
import simd
@testable import OpenWallpaperEngine

/// A wallpaper folder written by a test (`ModelAdversarialTests`): `project.json`, `scene.json`,
/// the model test materials and shaders (`Tests/Fixtures/ModelMaterials`), and `.mdl` files
/// written in WE's layout (`FixtureMDL`). Nothing from the Workshop.
struct ModelFixtureWallpaper {
    let directory: URL

    /// Writes the folder `name` under `scratch` with `objects` (JSON object texts) and `general`
    /// (the JSON members of `general`, without braces), looked at from `eye` towards the origin.
    init(in scratch: URL, name: String, objects: [String], general: String = #""clearcolor":"0 0 0""#,
         eye: String = "0 0 6", center: String = "0 0 0", files: [String: Data] = [:]) throws {
        let fm = FileManager.default
        directory = scratch.appending(path: name, directoryHint: .isDirectory)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        for folder in ["materials", "shaders"] {
            try fm.copyItem(at: Fixtures.url("ModelMaterials").appending(path: folder), to: directory.appending(path: folder))
        }
        let scene = """
            {"camera":{"center":"\(center)","eye":"\(eye)","up":"0 1 0"},
             "general":{\(general)},
             "objects":[\(objects.joined(separator: ",\n"))]}
            """
        try Data(scene.utf8).write(to: directory.appending(path: "scene.json"))
        let project = #"{"file":"scene.json","title":"model fixture \#(name)","type":"scene","general":{"properties":{}}}"#
        try Data(project.utf8).write(to: directory.appending(path: "project.json"))
        for (path, data) in files {
            let url = directory.appending(path: path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
    }
}

/// A `.mdl` in WE's `MDLV0013` layout (docs/models-plan.md §1): one vertex format for every mesh,
/// `materialsPerMesh` material paths per mesh, u16 or u32 indices (mesh flag 1), an optional
/// skeleton (`MDLS0001`) and attachment points (`MDAT0001`).
struct FixtureMDL {
    struct Mesh {
        var materials: [String]
        /// Interleaved in the format's order; integer attributes as their bit patterns.
        var vertices: [Float]
        var indices: [UInt32]
        var uint32Indices = false
    }

    struct Attachment {
        var bone: UInt16
        var name: String
        var matrix = matrix_identity_float4x4
    }

    /// A clip (`MDLA0005`): one track per bone, `frames + 1` samples each.
    struct Clip {
        var id: UInt64
        var name: String
        var fps: Float = 30
        var frames: UInt32
        /// MDLA clip flags (`MDLAnimation.Flag`: 0x400 Match loop, 0x1f800 the root-motion axes).
        var flags: UInt32 = 0
        /// Per bone, per sample: position, Euler angles (radians, X first), scale.
        var tracks: [[MDLBonePose]]
        /// The model editor's clip record (flag 0x1, written with it): source clip, frames, root bone.
        var reference: MDLAnimation.Reference?
    }

    /// A bone written as given (`MDLS0001`): its parent (0xFFFFFFFF for a root), bind matrix
    /// relative to it, and properties JSON (docs/models-plan.md §1.3).
    struct Bone {
        var name: String
        var parent: UInt32 = 0xFFFF_FFFF
        var matrix = matrix_identity_float4x4
        var properties = ""
    }

    var format: UInt32
    var materialsPerMesh: Int
    var meshes: [Mesh]
    var bones = 0
    /// Bones to write instead of `bones` identity children of the root.
    var skeleton: [Bone] = []
    var attachments: [Attachment] = []
    var clips: [Clip] = []

    static let positionNormal: UInt32 = 0x3
    /// Position, normal, blend indices and weights.
    static let skinned: UInt32 = 0x3 | 0x800000 | 0x1000000
    /// A texture coordinate (`a_TexCoord`, after the blend attributes in the vertex).
    static let uv: UInt32 = 0x8

    var data: Data {
        var w = SceneMorphTargetsTests.Writer()
        w.cstr("MDLV0013")
        w.u32(format)
        w.u32(UInt32(materialsPerMesh))
        w.u32(UInt32(meshes.count))
        for mesh in meshes {
            for index in 0..<materialsPerMesh { w.cstr(mesh.materials[min(index, mesh.materials.count - 1)]) }
            w.u32(mesh.uint32Indices ? 1 : 0)
            w.blob(mesh.vertices.flatMap { value -> [UInt8] in withUnsafeBytes(of: value.bitPattern.littleEndian) { Array($0) } })
            let indexBytes: [UInt8] = mesh.uint32Indices
                ? mesh.indices.flatMap { value -> [UInt8] in withUnsafeBytes(of: value.littleEndian) { Array($0) } }
                : mesh.indices.flatMap { value -> [UInt8] in withUnsafeBytes(of: UInt16(truncatingIfNeeded: value).littleEndian) { Array($0) } }
            w.blob(indexBytes)
        }
        if bones > 0 || !skeleton.isEmpty {
            // Every bone a child of the root, at the origin: the bind pose is the identity.
            let list = skeleton.isEmpty
                ? (0..<bones).map { Bone(name: "bone\($0)", parent: $0 == 0 ? 0xFFFF_FFFF : 0) } : skeleton
            w.section("MDLS0001") { s in
                s.u32(UInt32(list.count))
                for bone in list {
                    s.cstr(bone.name)
                    s.u32(1)
                    s.u32(bone.parent)
                    s.u32(64)
                    let m = bone.matrix
                    s.floats([m.columns.0, m.columns.1, m.columns.2, m.columns.3].flatMap { (c: SIMD4<Float>) -> [Float] in [c.x, c.y, c.z, c.w] })
                    s.cstr(bone.properties)
                }
            }
        }
        if !clips.isEmpty {
            let list = clips
            w.section("MDLA0005") { s in
                s.i32(Int32(list.count))
                for clip in list {
                    s.u64(clip.id)
                    s.cstr(clip.name)
                    s.cstr("loop")
                    s.f32(clip.fps)
                    s.u32(clip.frames)
                    s.u32(clip.reference == nil ? clip.flags : clip.flags | MDLAnimation.Flag.reference)
                    s.i32(Int32(clip.tracks.count))
                    for track in clip.tracks {
                        s.u32(0)
                        s.blob(track.flatMap { pose -> [UInt8] in
                            [pose.position.x, pose.position.y, pose.position.z, pose.euler.x, pose.euler.y, pose.euler.z,
                             pose.scale.x, pose.scale.y, pose.scale.z].flatMap { (value: Float) -> [UInt8] in
                                withUnsafeBytes(of: value.bitPattern.littleEndian) { Array($0) }
                            }
                        })
                    }
                    s.u32(0) // scalar tracks A (MDLA 3)
                    s.u8(0) // no scalar tracks B
                    s.u8(0) // no mesh tracks (MDLA 4)
                    s.floats([-1, -1, -1, 1, 1, 1]) // the clip's box (MDLA 5)
                    if let reference = clip.reference {
                        s.u16(reference.animation)
                        s.u32(reference.startFrame)
                        s.u32(reference.endFrame)
                        s.u32(reference.frameOffset)
                        s.u32(UInt32(bitPattern: reference.rootBone))
                    }
                    s.i32(0) // events
                }
            }
        }
        if !attachments.isEmpty {
            let points = attachments
            w.section("MDAT0001") { s in
                s.u16(UInt16(points.count))
                for point in points {
                    s.u16(point.bone)
                    s.cstr(point.name)
                    let m = point.matrix
                    s.floats([m.columns.0, m.columns.1, m.columns.2, m.columns.3].flatMap { (c: SIMD4<Float>) -> [Float] in [c.x, c.y, c.z, c.w] })
                }
            }
        }
        w.cstr("")
        return Data(w.bytes)
    }

    /// A cube of half-size `half` about `centre`, one quad per face with its outward normal, wound
    /// counter-clockwise about it (as `ModelRenderTests.cube`); with `bone`, each vertex also
    /// carries that blend index at full weight. `base` offsets the indices.
    static func cube(material: String, half: Float = 1, centre: SIMD3<Float> = .zero, bone: UInt32? = nil,
                     base: UInt32 = 0, size: SIMD3<Float>? = nil, uv: Bool = false) -> (vertices: [Float], indices: [UInt32]) {
        let faces: [(normal: SIMD3<Float>, u: SIMD3<Float>, v: SIMD3<Float>)] = [
            (SIMD3(1, 0, 0), SIMD3(0, 0, -1), SIMD3(0, 1, 0)), (SIMD3(-1, 0, 0), SIMD3(0, 0, 1), SIMD3(0, 1, 0)),
            (SIMD3(0, 1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, -1)), (SIMD3(0, -1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, 1)),
            (SIMD3(0, 0, 1), SIMD3(1, 0, 0), SIMD3(0, 1, 0)), (SIMD3(0, 0, -1), SIMD3(-1, 0, 0), SIMD3(0, 1, 0)),
        ]
        var floats: [Float] = []
        var indices: [UInt32] = []
        for (face, (normal, u, v)) in faces.enumerated() {
            for (corner, texel) in zip([-u - v, u - v, u + v, -u + v], [SIMD2<Float>(0, 1), SIMD2(1, 1), SIMD2(1, 0), SIMD2(0, 0)]) {
                let unit: SIMD3<Float> = normal + corner
                let position: SIMD3<Float> = centre + unit * (size.map { $0 / 2 } ?? SIMD3(repeating: half))
                floats += [position.x, position.y, position.z, normal.x, normal.y, normal.z]
                if let bone {
                    floats += [Float(bitPattern: bone), Float(bitPattern: 0), Float(bitPattern: 0), Float(bitPattern: 0)]
                    floats += [1, 0, 0, 0]
                }
                if uv { floats += [texel.x, texel.y] }
            }
            let first = base + UInt32(face * 4)
            indices += [first, first + 1, first + 2, first, first + 2, first + 3]
        }
        return (floats, indices)
    }

    /// One mesh: a cube in `material`, with texture coordinates, which WE's model shaders read (a
    /// mesh lacking an input its shader reads isn't drawn, docs/models-plan.md §5.11).
    static func cubeModel(material: String = "materials/facecolor.json", bones: Int = 0, bone: UInt32? = nil) -> FixtureMDL {
        let cube = Self.cube(material: material, bone: bone, uv: true)
        return FixtureMDL(format: (bones > 0 ? skinned : positionNormal) | uv, materialsPerMesh: 1,
                          meshes: [Mesh(materials: [material], vertices: cube.vertices, indices: cube.indices)], bones: bones)
    }
}
