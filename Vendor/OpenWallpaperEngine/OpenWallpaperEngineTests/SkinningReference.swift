import Foundation
import simd
@testable import OpenWallpaperEngine

/// A CPU skinning reference written from WE's rules alone (docs/models-plan.md §1.3, §1.4, §2.8),
/// in double precision and apart from the app's `SceneSkeleton`/`SceneAnimationLayerStack`: one
/// clip played from time 0, sampled, posed and applied to the mesh. `Scripts/skinning-reference.py`
/// is the same reference in Python; the tests hold the app, this and the script to each other.
enum SkinningReference {
    struct Pose {
        var clockTime: Double
        var frame0: Int
        var frame1: Int
        var fraction: Double
        /// Per bone: `world · inverse(bindWorld)`, column-vector.
        var palette: [simd_double4x4]
    }

    /// The clip clock after one advance by `time` from 0 (0x1401a9f60): a loop wraps, a mirror
    /// turns at its end, a single clip stops at its duration. Float32, as WE's clock is (the frame
    /// split at a frame boundary depends on it).
    static func clockTime(_ clip: MDLAnimation, time: Double) -> Float {
        let time = Float(time)
        let duration = Float(clip.frames) / clip.fps
        guard duration > 0 else { return 0 }
        switch clip.mode {
        case .single: return min(time, duration)
        case .mirror: return time >= duration ? duration - fmodf(time, duration) : time
        case .loop:
            var t = time
            if t < 0 { t = fmodf(t + duration, duration) }
            if t >= duration { t = fmodf(t, duration) }
            return t
        }
    }

    static func pose(_ skeleton: MDLSkeleton, clip: MDLAnimation, time: Double) -> Pose {
        let bones = skeleton.bones
        let parents = bones.enumerated().map { index, bone in bone.parentIndex.flatMap { $0 < index ? $0 : nil } }
        let bindLocal = bones.map { simd_double4x4($0.matrix) }
        var bindWorld: [simd_double4x4] = []
        for index in bones.indices {
            bindWorld.append(parents[index].map { bindWorld[$0] * bindLocal[index] } ?? bindLocal[index])
        }
        let frameDuration = 1 / clip.fps
        let t = clockTime(clip, time: time)
        let frames = Int(clip.frames)
        let last = frames - 1
        let truncated = Int(t / frameDuration)
        let frame0 = min(truncated, last) <= 0 ? 0 : min(truncated, last)
        let frame1 = min(frame0 + 1, frames)
        let fraction = Double(fmodf(t, frameDuration) / frameDuration)
        var local: [simd_double4x4] = []
        for index in bones.indices {
            guard index < clip.boneTracks.count, !clip.boneTracks[index].isDisabled else {
                local.append(bindLocal[index])
                continue
            }
            let track = clip.boneTracks[index]
            let count = track.samples.count / 9
            func sample(_ frame: Int) -> (SIMD3<Double>, simd_quatd, SIMD3<Double>) {
                let base = max(0, min(frame, count - 1)) * 9
                let v = track.samples[base..<(base + 9)].map(Double.init)
                return (SIMD3(v[0], v[1], v[2]), euler(v[3], v[4], v[5]), SIMD3(v[6], v[7], v[8]))
            }
            let a = sample(frame0), b = sample(frame1)
            let translation = a.0 + (b.0 - a.0) * fraction
            let scale = a.2 + (b.2 - a.2) * fraction
            let target = simd_dot(a.1.vector, b.1.vector) < 0 ? -b.1.vector : b.1.vector
            let rotation = simd_quatd(vector: simd_normalize(a.1.vector * (1 - fraction) + target * fraction))
            let r = simd_double3x3(rotation)
            local.append(simd_double4x4(columns: (SIMD4(r.columns.0 * scale.x, 0), SIMD4(r.columns.1 * scale.y, 0),
                                                  SIMD4(r.columns.2 * scale.z, 0), SIMD4(translation, 1))))
        }
        var world: [simd_double4x4] = []
        for index in bones.indices {
            world.append(parents[index].map { world[$0] * local[index] } ?? local[index])
        }
        return Pose(clockTime: Double(t), frame0: frame0, frame1: frame1, fraction: fraction,
                    palette: zip(world, bindWorld).map { $0 * $1.inverse })
    }

    /// q = qz·qy·qx from half angles (0x1402640c0).
    static func euler(_ x: Double, _ y: Double, _ z: Double) -> simd_quatd {
        let cx = cos(x / 2), sx = sin(x / 2), cy = cos(y / 2), sy = sin(y / 2), cz = cos(z / 2), sz = sin(z / 2)
        return simd_quatd(ix: sx * cy * cz - cx * sy * sz, iy: cx * sy * cz + sx * cy * sz,
                          iz: cx * cy * sz - sx * sy * cz, r: cx * cy * cz + sx * sy * sz)
    }

    /// `Σ wᵢ · palette[indexᵢ] · (p, 1)` for every vertex of a mesh with blend indices and weights.
    static func skin(_ mesh: MDLMesh, palette: [simd_double4x4]) -> [SIMD3<Double>]? {
        let format = mesh.format
        guard let indices = MDLVertexAttribute.named("a_BlendIndices"), let weights = MDLVertexAttribute.named("a_BlendWeights"),
              let indexOffset = format.offset(of: indices), let weightOffset = format.offset(of: weights) else { return nil }
        let position = [MDLVertexAttribute.named("a_Position"), MDLVertexAttribute.named("a_PositionVec4")]
            .compactMap { $0 }.first { format.offset(of: $0) != nil }
        guard let position, let positionOffset = format.offset(of: position) else { return nil }
        let stride = format.stride
        return mesh.vertexData.withUnsafeBytes { raw -> [SIMD3<Double>] in
            func float(_ at: Int) -> Double { Double(Float(bitPattern: raw.loadUnaligned(fromByteOffset: at, as: UInt32.self))) }
            func uint(_ at: Int) -> Int { Int(raw.loadUnaligned(fromByteOffset: at, as: UInt32.self)) }
            return (0..<mesh.vertexCount).map { vertex in
                let base = vertex * stride
                let p = SIMD4(float(base + positionOffset), float(base + positionOffset + 4), float(base + positionOffset + 8), 1)
                var sum = SIMD4<Double>.zero
                for k in 0..<4 {
                    let w = float(base + weightOffset + 4 * k), bone = uint(base + indexOffset + 4 * k)
                    guard w != 0, bone < palette.count else { continue }
                    sum += w * (palette[bone] * p)
                }
                return SIMD3(sum.x, sum.y, sum.z)
            }
        }
    }
}

extension simd_double4x4 {
    init(_ m: simd_float4x4) {
        self.init(columns: (SIMD4<Double>(m.columns.0), SIMD4<Double>(m.columns.1), SIMD4<Double>(m.columns.2),
                            SIMD4<Double>(m.columns.3)))
    }
}

extension simd_float4x4 {
    init(converting m: simd_double4x4) {
        self.init(columns: (SIMD4<Float>(m.columns.0), SIMD4<Float>(m.columns.1), SIMD4<Float>(m.columns.2),
                            SIMD4<Float>(m.columns.3)))
    }
}

/// One line of `Scripts/skinning-reference.py`'s output.
struct SkinningReferenceEntry: Decodable {
    struct Pose: Decodable {
        var time: Double
        var clockTime: Double
        var frame0: Int
        var frame1: Int
        var fraction: Double
        /// 16 floats per bone, column-major.
        var palette: [Double]
        /// By mesh index: x, y, z per vertex.
        var positions: [String: [Double]]
    }

    var file: String
    var item: String?
    var clip: String
    var clipID: UInt64
    var bones: Int
    var poses: [Pose]

    static func load(_ url: URL) throws -> [SkinningReferenceEntry] {
        try String(decoding: Data(contentsOf: url), as: UTF8.self).split(separator: "\n").map {
            try JSONDecoder().decode(SkinningReferenceEntry.self, from: Data($0.utf8))
        }
    }
}
