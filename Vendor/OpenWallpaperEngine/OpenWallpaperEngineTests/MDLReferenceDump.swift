import CryptoKit
import Foundation
import simd
@testable import OpenWallpaperEngine

/// An `MDLModel` as the JSON `Scripts/mdl-reference.py` writes for a file (its `Dumper`), so the
/// two decodes compare field for field. Arrays of numbers longer than `inline` elements become
/// `{"count", "sha256"}` of their packed little-endian values, as the script writes them.
struct MDLReferenceDump {
    typealias Object = [String: Any]

    let inline: Int?

    // MARK: - Values

    private enum Kind { case f32, u32, u8 }

    private func array(_ values: [UInt32], _ kind: Kind) -> Any {
        if let inline, values.count > inline {
            var bytes: [UInt8] = []
            bytes.reserveCapacity(values.count * (kind == .u8 ? 1 : 4))
            for value in values {
                if kind == .u8 {
                    bytes.append(UInt8(value))
                } else {
                    withUnsafeBytes(of: value.littleEndian) { bytes += $0 }
                }
            }
            return ["count": Int64(values.count), "sha256": Digest.hex(SHA256.hash(data: bytes))]
        }
        switch kind {
        case .f32: return values.map { Float(bitPattern: $0) as Any }
        case .u32, .u8: return values.map { Int64($0) as Any }
        }
    }

    private func floats(_ values: [Float]) -> Any { array(values.map(\.bitPattern), .f32) }
    private func unsigned(_ values: [UInt32]) -> Any { array(values, .u32) }
    private func bytes(_ data: Data) -> Any { array(data.map(UInt32.init), .u8) }

    private static func list(_ values: [Float]) -> [Any] { values.map { $0 as Any } }
    private static func vector(_ v: SIMD3<Float>) -> [Any] { list([v.x, v.y, v.z]) }
    private static func matrixValues(_ m: simd_float4x4) -> [Float] {
        [m.columns.0, m.columns.1, m.columns.2, m.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
    }
    private static func matrix(_ m: simd_float4x4) -> [Any] { list(matrixValues(m)) }
    private static func box(_ b: MDLBounds) -> [String: Any] { ["min": vector(b.min), "max": vector(b.max)] }
    private static func optional(_ value: Any?) -> Any { value ?? NSNull() }
    private static func int(_ value: some BinaryInteger) -> Any { Int64(value) }

    // MARK: - Model

    func model(_ m: MDLModel) -> [String: Any] {
        [
            "tag": m.tag, "version": Self.int(m.version), "legacy_format": Self.int(m.legacyFormat),
            "materials_per_mesh": Self.int(m.materialsPerMesh), "bounds": Self.box(m.bounds),
            "meshes": m.meshes.map(mesh),
            "sections": m.sections.map { s -> Object in
                ["tag": s.tag, "offset": Self.int(s.offset), "end": Self.int(s.end), "parsed_end": Self.int(s.parsedEnd),
                 "skipped": s.skipped]
            },
            "skeleton": Self.optional(m.skeleton.map(skeleton)),
            "animations_version": Self.optional(m.animationsVersion.map { Self.int($0) }),
            "animations": Self.optional(m.animations.map { $0.map(animation) }),
            "attachments": Self.optional(m.attachments.map { list in
                list.map { a -> Object in ["bone": Self.int(a.bone), "name": a.name, "matrix": Self.matrix(a.matrix)] }
            }),
            "morphs": Self.optional(m.morphTargets.map { $0.map(morphs) }),
            "reference_pose": Self.optional(m.referencePose.map { floats($0.flatMap(Self.matrixValues)) }),
            "end": Self.int(m.end), "trailing_bytes": Self.int(m.trailingByteCount),
        ]
    }

    private func mesh(_ me: MDLMesh) -> Any {
        var attributes: [String: Any] = [:]
        for element in me.format.elements {
            let values = me.unsignedValues(element.attribute) ?? []
            attributes[element.attribute.name] = [Self.int(element.offset),
                                                  element.attribute.componentType == .uint32 ? unsigned(values) : array(values, .f32)] as [Any]
        }
        return [
            "materials": me.materials, "flags": Self.int(me.flags), "flags_extra": Self.optional(me.flagsExtra.map { Self.int($0) }),
            "bounds": Self.optional(me.bounds.map(Self.box)), "format": Self.int(me.format.rawValue),
            "stride": Self.int(me.format.stride), "vertex_count": Self.int(me.vertexCount), "index_size": Self.int(me.indexSize),
            "index_count": Self.int(me.indexCount), "attributes": attributes, "indices": unsigned(me.indices),
            "blob1": Self.optional(me.extraPositions.map { ["u32": Self.int($0.discarded), "bytes": bytes($0.data)] as Object }),
            "blob16": Self.optional(me.vector4Block.map { floats($0.flatMap { [$0.x, $0.y, $0.z, $0.w] }) }),
            "groups": Self.optional(me.groups.map { groups in
                groups.map { g -> Object in
                    ["id": g.id, "name": g.name, "flags": Self.int(g.flags), "list_a": unsigned(g.listA), "list_b": unsigned(g.listB)]
                }
            }),
        ] as [String: Any]
    }

    private func skeleton(_ sk: MDLSkeleton) -> Any {
        var out: [String: Any] = [
            "version": Self.int(sk.version),
            "bones": sk.bones.map { b -> Object in
                ["name": b.name, "flags": Self.int(b.flags), "parent": Self.int(b.parent), "matrix": Self.matrix(b.matrix),
                 "props": b.properties]
            },
        ]
        for key in ["links", "bind_matrices", "link_bind_matrices", "constraints", "ni_ids", "ni_maps", "ik_sets",
                    "bone_vectors", "bone_u32_a", "bone_u32_b"] { out[key] = NSNull() }
        guard sk.version >= 2 else { return out }
        out["links"] = sk.links.map { l -> Object in
            ["name": l.name, "bone": Self.int(l.bone), "type": Self.int(l.type), "matrix": Self.matrix(l.matrix)]
        }
        out["bind_matrices"] = Self.optional(sk.bindMatrices.map { floats($0.flatMap(Self.matrixValues)) })
        out["link_bind_matrices"] = Self.optional(sk.linkBindMatrices.map { floats($0.flatMap(Self.matrixValues)) })
        out["constraints"] = sk.constraints.map { c -> Object in
            ["bone": Self.int(c.bone), "a": Self.int(c.a), "b": Self.int(c.b), "flags": Self.int(c.flags),
             "f0": Self.optional(c.f0), "f1": Self.optional(c.f1)]
        }
        out["ni_ids"] = unsigned(sk.mapIDs)
        out["ni_maps"] = sk.maps.map { map -> [[Any]] in map.map { [Self.int($0.key), Self.vector($0.value)] as [Any] } }
        out["ik_sets"] = sk.ikSets.map { set -> Object in
            ["bone": Self.int(set.bone), "links": unsigned(set.links),
             "elements": set.elements.map { e -> Object in
                 ["bone": Self.int(e.bone),
                  "joints": e.joints.map { j -> Object in
                      ["bone": Self.int(j.bone), "flags": Self.int(j.flags), "f0": j.f0, "f1": j.f1, "bones": unsigned(j.bones)]
                  }]
             }]
        }
        out["bone_vectors"] = Self.optional(sk.boneVectors.map { vectors in
            floats(vectors.flatMap { [$0.vector.x, $0.vector.y, $0.vector.z] + Self.matrixValues($0.matrix) })
        })
        out["bone_u32_a"] = Self.optional(sk.boneIndices.map(unsigned))
        out["bone_u32_b"] = Self.optional(sk.bonePriorities.map(unsigned))
        return out
    }

    private func tracks(_ tracks: [MDLAnimation.Track]) -> Any {
        ["flags": unsigned(tracks.map(\.flags)), "samples": floats(tracks.flatMap(\.samples))] as Object
    }

    private func scalars(_ tracks: [MDLAnimation.ScalarTrack]?, _ key: String) -> Any {
        guard let tracks else { return NSNull() }
        return [key: unsigned(tracks.map(\.tag)), "samples": floats(tracks.flatMap(\.samples))] as Object
    }

    private func animation(_ a: MDLAnimation) -> Any {
        [
            "id": a.id, "name": a.name, "mode": a.modeName, "fps": a.fps, "frames": Self.int(a.frames),
            "flags": Self.int(a.flags), "bone_tracks": tracks(a.boneTracks),
            "link_tracks": Self.optional(a.linkTracks.map(tracks)), "constraint_tracks": scalars(a.constraintTracks, "value"),
            "scalar_tracks_a": scalars(a.scalarTracksA, "skipped"), "scalar_tracks_b": scalars(a.scalarTracksB, "skipped"),
            "scalar_tracks_c": scalars(a.scalarTracksC, "skipped"),
            "mesh_tracks": Self.optional(a.meshTracks.map { meshes in
                meshes.map { mt -> Object in
                    ["flags": Self.int(mt.flags), "f": Self.optional(mt.weight),
                     "morph_tracks": Self.optional(mt.morphTracks.map { list in
                         list.map { ["morph": Self.int($0.morph), "samples": floats($0.samples)] as Object }
                     })]
                }
            }),
            "bounds": Self.optional(a.bounds.map { Self.list([$0.min.x, $0.min.y, $0.min.z, $0.max.x, $0.max.y, $0.max.z]) }),
            "reference": Self.optional(a.reference.map { r -> Object in
                ["anim": Self.int(r.animation), "u0": Self.int(r.startFrame), "u1": Self.int(r.endFrame),
                 "u2": Self.int(r.frameOffset), "u3": Self.int(UInt32(bitPattern: r.rootBone))]
            }),
            "events": a.events.map { ["frame": $0.frame, "name": $0.name] as Object },
        ] as [String: Any]
    }

    private func morphs(_ mm: MDLMorphTargets) -> Any {
        [
            "mesh": Self.int(mm.mesh), "f": Self.optional(mm.weight), "vertex_count": Self.optional(mm.vertexCount.map { Self.int($0) }),
            "targets": mm.targets.map { t -> Object in
                ["id": t.id, "name": t.name, "positions": floats(t.positions),
                 "normals": Self.optional(t.normals.map(floats)), "tangents": Self.optional(t.tangents.map(floats)),
                 "u16": Self.optional(t.extra.map(bytes)),
                 "modifier": Self.optional(t.modifier.map { m -> Object in
                     ["bone": Self.int(m.bone), "mode": Self.int(m.mode), "f0": m.startDistance, "f1": m.endDistance]
                 })]
            },
        ] as [String: Any]
    }

    /// The script's error kind for an `MDLError`.
    static func kind(of error: Error) -> String {
        switch error as? MDLError {
        case .truncated?: return "truncated"
        case .notAModel?: return "not_mdlv"
        case .tooManyBones?: return "too_many_bones"
        default: return "malformed"
        }
    }

    // MARK: - Comparison

    /// Where `actual` (this dump) differs from `expected` (the script's JSON, as
    /// `JSONSerialization` reads it), at most `limit` paths. Floats compare as f32.
    static func differences(_ expected: Any, _ actual: Any, path: String = "", limit: Int = 20) -> [String] {
        var out: [String] = []
        compare(expected, actual, path, &out, limit)
        return out
    }

    private static func compare(_ e: Any, _ a: Any, _ path: String, _ out: inout [String], _ limit: Int) {
        guard out.count < limit else { return }
        func fail() { out.append("\(path): expected \(e), got \(a)") }
        switch a {
        case let a as [String: Any]:
            guard let e = e as? [String: Any] else { return fail() }
            if Set(e.keys) != Set(a.keys) {
                out.append("\(path): keys \(e.keys.sorted()) vs \(a.keys.sorted())")
                return
            }
            for key in a.keys.sorted() { compare(e[key]!, a[key]!, path + "/" + key, &out, limit) }
        case let a as [Any]:
            guard let e = e as? [Any], e.count == a.count else { return fail() }
            for (index, (x, y)) in zip(e, a).enumerated() { compare(x, y, "\(path)[\(index)]", &out, limit) }
        case let a as String:
            if e as? String != a { fail() }
        case let a as Bool:
            if (e as? NSNumber)?.boolValue != a { fail() }
        case let a as Float:
            guard let e = e as? NSNumber, Float(e.doubleValue) == a else { return fail() }
        case let a as Int64:
            if (e as? NSNumber)?.stringValue != String(a) { fail() }
        case let a as UInt64:
            if (e as? NSNumber)?.stringValue != String(a) { fail() }
        case is NSNull:
            if !(e is NSNull) { fail() }
        default:
            out.append("\(path): unexpected value \(a)")
        }
    }
}
