import Foundation

/// The meshes of a `.mdl` (`MDLV` 4–23, docs/models-plan.md §1.2), enough to compare the
/// importer's output with WE's own compiled models; the app's `MDLReader` checks the rest.
struct MDLTestMesh {
    var materials: [String]
    var flags: UInt32
    var format: UInt32
    var vertices: Data
    var indices: Data
}

struct MDLTestBone {
    var name: String
    var flags: UInt32
    var parent: UInt32
    var matrix: [Float]
    var properties: String
}

struct MDLTestAnimation {
    var id: UInt64
    var name: String
    var mode: String
    var fps: Float
    var frames: UInt32
    var flags: UInt32
    /// Per bone, `frames + 1` samples of 9 floats.
    var tracks: [[Float]]
    var bounds: [Float]
    var reference: (source: UInt16, start: UInt32, end: UInt32, offset: UInt32, rootBone: Int32)?
    var events: [(Float, String)]
}

struct MDLTestModel {
    var tag: String
    var legacyFormat: UInt32
    var meshes: [MDLTestMesh]
    /// The section tags after the meshes (`MDLV` 13 and later).
    var sections: [String]
    var bones: [MDLTestBone] = []
    /// Per bone: the box's half size and centre (`MDLS`'s per-bone block).
    var boneBoxes: [(half: [Float], matrix: [Float])] = []
    var animations: [MDLTestAnimation] = []
    var attachments: [(bone: UInt16, name: String, matrix: [Float])] = []
}

enum MDLTestReader {
    struct Truncated: Error {}

    static func read(_ data: Data) throws -> MDLTestModel {
        var r = Cursor(bytes: [UInt8](data))
        let tag = try r.cstring()
        let version = Int(tag.dropFirst(4)) ?? 0
        let legacy = try r.u32()
        let materialsPerMesh = try r.u32()
        let count = try r.u32()
        var meshes: [MDLTestMesh] = []
        for _ in 0..<count {
            let materials = try (0..<materialsPerMesh).map { _ in try r.cstring() }
            let flags = version >= 4 ? try r.u32() : 0
            if flags & 2 != 0 { _ = try r.u32() }
            if version >= 17 { _ = try r.bytes(24) }
            let format = version >= 15 ? try r.u32() : legacy
            let vertices = try r.blob()
            let indices = try r.blob()
            if version >= 21 {
                if try r.u8() != 0 { _ = try r.u32(); _ = try r.blob() }
                if try r.u8() != 0 { _ = try r.blob() }
            }
            if version >= 23 {
                for _ in 0..<(try r.u32()) {
                    _ = try r.bytes(8); _ = try r.cstring(); _ = try r.u32()
                    _ = try r.bytes(4 * Int(try r.u32())); _ = try r.bytes(4 * Int(try r.u32()))
                }
            }
            meshes.append(MDLTestMesh(materials: materials, flags: flags, format: format, vertices: vertices, indices: indices))
        }
        var model = MDLTestModel(tag: tag, legacyFormat: legacy, meshes: meshes, sections: [])
        if version >= 13 {
            while r.offset < r.bytes.count {
                let section = try r.cstring()
                if section.isEmpty { break }
                model.sections.append(section)
                let end = Int(try r.u32())
                if section == "MDLS0004" { try readSkeleton(&r, into: &model) }
                if section == "MDLA0006" { try readAnimations(&r, into: &model) }
                if section == "MDAT0001" {
                    for _ in 0..<(try r.u16()) {
                        model.attachments.append((try r.u16(), try r.cstring(), try r.floats(16)))
                    }
                }
                guard section.hasPrefix("MDL") || section.hasPrefix("MDA") else { throw Truncated() }
                if r.offset != end, ["MDLS0004", "MDLA0006", "MDAT0001"].contains(section) { throw Truncated() }
                r.offset = end
            }
        }
        return model
    }

    /// `MDLS0004` as the importer writes it: bones, no links, bind matrices, constraints, maps or
    /// IK sets, the bone boxes and no draw-order arrays.
    static func readSkeleton(_ r: inout Cursor, into model: inout MDLTestModel) throws {
        let count = Int(try r.u32())
        for _ in 0..<count {
            let name = try r.cstring()
            let flags = try r.u32()
            let parent = try r.u32()
            guard try r.u32() == 64 else { throw Truncated() }
            model.bones.append(MDLTestBone(name: name, flags: flags, parent: parent, matrix: try r.floats(16), properties: try r.cstring()))
        }
        guard try r.u16() == 0, try r.u8() == 0, try r.u32() == 0, try r.u16() == 0, try r.u16() == 0 else { throw Truncated() }
        if try r.u8() != 0 {
            for _ in 0..<count { model.boneBoxes.append((try r.floats(3), try r.floats(16))) }
        }
        guard try r.u8() == 0, try r.u8() == 0 else { throw Truncated() }
    }

    static func readAnimations(_ r: inout Cursor, into model: inout MDLTestModel) throws {
        let count = Int(try r.u32())
        for _ in 0..<count {
            let idLow = UInt64(try r.u32()), idHigh = UInt64(try r.u32())
            var animation = MDLTestAnimation(id: idLow | idHigh << 32, name: try r.cstring(), mode: try r.cstring(), fps: try r.f32(),
                                             frames: try r.u32(), flags: try r.u32(), tracks: [], bounds: [], reference: nil, events: [])
            let tracks = Int(try r.u32())
            for _ in 0..<tracks {
                _ = try r.u32()
                let size = Int(try r.u32())
                guard size == 36 * (Int(animation.frames) + 1) else { throw Truncated() }
                animation.tracks.append(try r.floats(size / 4))
            }
            guard try r.u32() == 0, try r.u8() == 0, try r.u8() == 0 else { throw Truncated() }
            animation.bounds = try r.floats(6)
            guard try r.u8() == 0 else { throw Truncated() }
            if animation.flags & 1 != 0 {
                animation.reference = (try r.u16(), try r.u32(), try r.u32(), try r.u32(), Int32(bitPattern: try r.u32()))
            }
            for _ in 0..<(try r.u32()) { animation.events.append((try r.f32(), try r.cstring())) }
            model.animations.append(animation)
        }
    }

    struct Cursor {
        var bytes: [UInt8]
        var offset = 0

        mutating func bytes(_ count: Int) throws -> [UInt8] {
            guard count >= 0, offset + count <= bytes.count else { throw Truncated() }
            defer { offset += count }
            return Array(bytes[offset..<(offset + count)])
        }

        mutating func u8() throws -> UInt8 { try bytes(1)[0] }

        mutating func u16() throws -> UInt16 {
            let b = try bytes(2)
            return UInt16(b[0]) | UInt16(b[1]) << 8
        }

        mutating func f32() throws -> Float { Float(bitPattern: try u32()) }

        mutating func floats(_ count: Int) throws -> [Float] { try (0..<count).map { _ in try f32() } }

        mutating func u32() throws -> UInt32 {
            let b = try bytes(4)
            return UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
        }

        mutating func blob() throws -> Data { Data(try bytes(Int(try u32()))) }

        mutating func cstring() throws -> String {
            guard let end = bytes[offset...].firstIndex(of: 0) else { throw Truncated() }
            defer { offset = end + 1 }
            return String(decoding: bytes[offset..<end], as: UTF8.self)
        }
    }
}
