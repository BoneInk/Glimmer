import Foundation
import simd

/// Reads a `.mdl` the way WE's model loader does (0x140261880–0x140265a42; docs/models-plan.md §1,
/// dd-models/re-mdl/FORMAT.md), every version in the library: `MDLV` 4–23, `MDLS` 1–4, `MDLA`
/// 1–6, `MDAT0001`, `MDMP0001`, `MDLE0002`. `Scripts/mdl-reference.py` is its oracle.
///
/// Strict where WE is lenient about broken files: a read past the end, a wrong blob size and an
/// out-of-range index are errors (WE reads zeros or fast-fails). Where WE deliberately skips bytes
/// this does too: a section it doesn't finish reading (a newer version of a known one, an unknown
/// tag) continues at its stored end, and bytes after the terminating empty tag are ignored.
/// (The reference script rejects those two, which no library file has.)
public enum MDLReader {
    /// `log` hears each section it skips (an unknown tag), with where it is.
    public static func read(_ data: Data, log: (String) -> Void = { _ in }) throws -> MDLModel {
        try readWithMeshRanges(data, log: log).model
    }

    /// The model and where each mesh's record (its materials to its groups) lies in `data`, from
    /// 0: what a writer that keeps a mesh byte for byte copies.
    public static func readWithMeshRanges(_ data: Data, log: (String) -> Void = { _ in }) throws
        -> (model: MDLModel, meshRanges: [Range<Int>]) {
        var reader = MDLByteReader([UInt8](data))
        var meshRanges: [Range<Int>] = []
        var model = try readMeshes(&reader, ranges: &meshRanges)
        // 0x140262382: no sections before MDLV 13.
        if model.version >= 13 {
            try readSections(&reader, into: &model, log: log)
        }
        model.end = reader.offset
        model.trailingByteCount = reader.count - reader.offset
        return (model, meshRanges)
    }

    /// `atoi(tag + 4)` over ASCII digits (0x1402c82c0); 0 without any.
    public static func version(ofTag tag: ArraySlice<UInt8>) -> Int {
        var value = 0
        for byte in tag.dropFirst(4) {
            guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { break }
            let (tens, overflowed) = value.multipliedReportingOverflow(by: 10)
            let (sum, carried) = tens.addingReportingOverflow(Int(byte - UInt8(ascii: "0")))
            if overflowed || carried { return Int.max }
            value = sum
        }
        return value
    }

    // MARK: - MDLV

    private static func readMeshes(_ r: inout MDLByteReader, ranges: inout [Range<Int>]) throws -> MDLModel {
        let tagBytes = try r.cstringBytes()
        let tag = String(decoding: tagBytes, as: UTF8.self)
        guard tagBytes.starts(with: Array("MDLV".utf8)) else { throw MDLError.notAModel(tag: String(tag.prefix(16))) }
        let version = self.version(ofTag: tagBytes)
        let legacyFormat = try r.u32()
        let materialsPerMesh = try r.u32()
        let meshCount = try r.u32()
        var meshes: [MDLMesh] = []
        for index in 0..<Int(meshCount) {
            let start = r.offset
            meshes.append(try readMesh(&r, index: index, version: version, legacyFormat: legacyFormat,
                                       materials: Int(materialsPerMesh)))
            ranges.append(start..<r.offset)
        }
        return MDLModel(tag: tag, version: version, legacyFormat: legacyFormat, materialsPerMesh: materialsPerMesh,
                        meshes: meshes, end: 0, trailingByteCount: 0)
    }

    private static func readMesh(_ r: inout MDLByteReader, index: Int, version: Int, legacyFormat: UInt32,
                                 materials count: Int) throws -> MDLMesh {
        var materials: [String] = []
        for _ in 0..<count { materials.append(try r.cstring()) }
        let flags = version >= 4 ? try r.u32() : 0
        let flagsExtra = flags & 2 != 0 ? try r.u32() : nil
        var bounds: MDLBounds?
        if version >= 17 {
            let b = try r.f32s(6)
            bounds = MDLBounds(min: SIMD3(b[0], b[1], b[2]), max: SIMD3(b[3], b[4], b[5]))
        }
        let format = MDLVertexFormat(rawValue: version >= 15 ? try r.u32() : legacyFormat)
        guard format.unknownBits == 0 else {
            throw MDLError.malformed("unknown vertex format bits 0x\(String(format.unknownBits, radix: 16))")
        }
        let vertices = try r.blob("vertices")
        let indices = try r.blob("indices")
        let vertexStride = format.stride
        guard vertexStride > 0, vertices.count % vertexStride == 0 else {
            throw MDLError.malformed("mesh \(index): vertex bytes \(vertices.count) not a multiple of stride \(vertexStride)")
        }
        let indexSize = flags & 1 != 0 ? 4 : 2
        guard indices.count % indexSize == 0 else {
            throw MDLError.malformed("mesh \(index): index bytes \(indices.count) not a multiple of \(indexSize)")
        }
        var mesh = MDLMesh(materials: materials, flags: flags, flagsExtra: flagsExtra, bounds: bounds, format: format,
                           vertexData: Data(vertices), indexData: Data(indices))
        if version >= 21 {
            // 0x140261b6b: the u32 before the blob is read and discarded.
            if try r.u8() != 0 {
                let discarded = try r.u32()
                mesh.extraPositions = .init(discarded: discarded, data: Data(try r.blob("extra positions")))
            }
            if try r.u8() != 0 {
                let block = try r.blob("vector4 block")
                guard block.count % 16 == 0 else { throw MDLError.malformed("vector4 block of \(block.count) bytes") }
                let floats = floats(block)
                mesh.vector4Block = stride(from: 0, to: floats.count, by: 4).map {
                    SIMD4(floats[$0], floats[$0 + 1], floats[$0 + 2], floats[$0 + 3])
                }
            }
        }
        if version >= 23 {
            let entries = mesh.vector4Block?.count ?? 0
            let count = try r.u32()
            var groups: [MDLMesh.Group] = []
            for _ in 0..<Int(count) {
                let id = try r.u64()
                let name = try r.cstring()
                let flags = try r.u32()
                let listA = try r.u32s(Int(try r.u32()))
                let listB = try r.u32s(Int(try r.u32()))
                // 0x140261cbe / 0x140261e6b: WE fast-fails on an index past the block.
                if let bad = (listA + listB).first(where: { Int($0) >= entries }) {
                    throw MDLError.malformed("mesh \(index): group index \(bad) >= vector4 block count \(entries)")
                }
                groups.append(.init(id: id, name: name, flags: flags, listA: listA, listB: listB))
            }
            mesh.groups = groups
        }
        return mesh
    }

    // MARK: - Sections

    private static func readSections(_ r: inout MDLByteReader, into model: inout MDLModel,
                                     log: (String) -> Void) throws {
        while true {
            let offset = r.offset
            let tagBytes = try r.cstringBytes()
            if tagBytes.isEmpty { return }
            let tag = String(decoding: tagBytes, as: UTF8.self)
            let end = try r.sectionEnd()
            guard end >= r.offset else {
                throw MDLError.malformed("section \(tag) at 0x\(String(offset, radix: 16)) ends before its body")
            }
            let version = self.version(ofTag: tagBytes)
            var skipped = false
            if tagBytes.starts(with: Array("MDLS".utf8)) {
                model.skeleton = try readSkeleton(&r, version: version)
            } else if tagBytes.starts(with: Array("MDLA".utf8)) {
                model.animations = try readAnimations(&r, version: version, model: model)
                model.animationsVersion = version
            } else if tagBytes.starts(with: Array("MDAT0001".utf8)) {
                model.attachments = try readAttachments(&r)
            } else if tagBytes.starts(with: Array("MDMP0001".utf8)) {
                model.morphTargets = try readMorphTargets(&r, model: model)
            } else if tagBytes.elementsEqual(Array("MDLE0002".utf8)) {
                model.referencePose = try readReferencePose(&r, bones: model.skeleton?.bones.count ?? 0)
            } else {
                skipped = true
                log("MDL: skipped unknown section \(tag) at 0x\(String(offset, radix: 16)) (\(end - r.offset) bytes)")
            }
            guard r.offset <= end else {
                throw MDLError.malformed("section \(tag) read to 0x\(String(r.offset, radix: 16)) past its end 0x\(String(end, radix: 16))")
            }
            model.sections.append(.init(tag: tag, offset: offset, end: end, parsedEnd: r.offset,
                                        skipped: skipped))
            r.seek(to: end)
        }
    }

    private static func readAttachments(_ r: inout MDLByteReader) throws -> [MDLAttachment] {
        let count = try r.u16()
        var out: [MDLAttachment] = []
        for _ in 0..<count {
            let bone = try r.u16()
            let name = try r.cstring()
            out.append(MDLAttachment(bone: bone, name: name, matrix: try r.matrix()))
        }
        return out
    }

    /// 0x140265909: `capped(bones · 64)`, which must hold exactly one matrix per bone.
    private static func readReferencePose(_ r: inout MDLByteReader, bones: Int) throws -> [simd_float4x4] {
        let (length, bytes) = try r.capped(64 * bones)
        guard length == 64 * bones else { throw MDLError.malformed("reference pose of \(length) bytes for \(bones) bones") }
        let values = floats(bytes)
        return (0..<bones).map { MDLByteReader.matrix(Array(values[(16 * $0)..<(16 * $0 + 16)])) }
    }

    /// Little-endian f32s of `bytes` (a multiple of 4 long).
    public static func floats(_ bytes: ArraySlice<UInt8>) -> [Float] {
        bytes.withUnsafeBytes { raw in
            (0..<(raw.count / 4)).map { Float(bitPattern: raw.loadUnaligned(fromByteOffset: 4 * $0, as: UInt32.self).littleEndian) }
        }
    }
}
