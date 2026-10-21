import simd

extension MDLReader {
    /// WE's bone limit: more fast-fails the process (0x140262501).
    public static let maximumBones = 128

    /// The `MDLS` section (0x1402624f4…0x14026395a; docs/models-plan.md §1.3).
    public static func readSkeleton(_ r: inout MDLByteReader, version: Int) throws -> MDLSkeleton {
        let boneCount = Int(try r.u32())
        guard boneCount <= maximumBones else { throw MDLError.tooManyBones(boneCount) }
        var bones: [MDLBone] = []
        for _ in 0..<boneCount {
            let name = try r.cstring()
            let flags = try r.u32()
            let parent = try r.u32()
            // 0x14026257e: capped(64), which the writer fills with `u32 64` and the matrix.
            let (length, matrix) = try r.capped(64)
            guard length == 64 else { throw MDLError.malformed("bone \(bones.count) matrix of \(length) bytes") }
            bones.append(MDLBone(name: name, flags: flags, parent: parent,
                                 matrix: MDLByteReader.matrix(floats(matrix)), properties: try r.cstring()))
        }
        var skeleton = MDLSkeleton(version: version, bones: bones)
        guard version >= 2 else { return skeleton }

        let linkCount = Int(try r.u16())
        for _ in 0..<linkCount {
            let name = try r.cstring()
            let bone = try r.u32()
            let type = try r.u32()
            skeleton.links.append(.init(name: name, bone: bone, type: type, matrix: try r.matrix()))
        }
        if try r.u8() != 0 {
            skeleton.bindMatrices = try (0..<boneCount).map { _ in try r.matrix() }
            skeleton.linkBindMatrices = try (0..<linkCount).map { _ in try r.matrix() }
        }
        let constraintCount = try r.u32()
        for _ in 0..<constraintCount {
            var constraint = MDLSkeleton.Constraint(bone: try r.u32(), a: try r.u32(), b: try r.u32(), flags: 0)
            guard Int(constraint.bone) < boneCount else {
                throw MDLError.malformed("constraint bone \(constraint.bone) >= \(boneCount)")
            }
            if version >= 4 { constraint.flags = try r.u32() }
            if constraint.flags & 2 != 0 {
                constraint.f0 = try r.f32()
                constraint.f1 = try r.f32()
            }
            skeleton.constraints.append(constraint)
        }
        let mapCount = Int(try r.u16())
        skeleton.mapIDs = try r.u32s(mapCount)
        for _ in 0..<mapCount {
            let entries = try r.u16()
            skeleton.maps.append(try (0..<entries).map { _ in MDLSkeleton.MapEntry(key: try r.u32(), value: try r.vector3()) })
        }
        let ikSetCount = try r.u16()
        for _ in 0..<ikSetCount {
            skeleton.ikSets.append(try readIKSet(&r, bones: boneCount, links: linkCount))
        }
        if try r.u8() != 0 {
            skeleton.boneVectors = try (0..<boneCount).map { _ in
                MDLSkeleton.BoneVector(vector: try r.vector3(), matrix: try r.matrix())
            }
        }
        if try r.u8() != 0 { skeleton.boneIndices = try r.u32s(boneCount) }
        if version >= 3, try r.u8() != 0 { skeleton.bonePriorities = try r.u32s(boneCount) }
        return skeleton
    }

    /// One IK set (0x140262bfe…): its bone, links and elements, every index in range (WE
    /// fast-fails otherwise, 0x140262cfe, 0x140262d8e, 0x140263023, 0x140263382, 0x1402633b8).
    private static func readIKSet(_ r: inout MDLByteReader, bones: Int, links: Int) throws -> MDLSkeleton.IKSet {
        let bone = try r.u32()
        guard Int(bone) < bones else { throw MDLError.malformed("IK set bone \(bone) >= \(bones)") }
        let setLinks = try r.u32s(Int(try r.u32()))
        if let bad = setLinks.first(where: { Int($0) >= links }) {
            throw MDLError.malformed("IK set link \(bad) >= \(links)")
        }
        var elements: [MDLSkeleton.IKSet.Element] = []
        for _ in 0..<(try r.u16()) {
            let elementBone = try r.u32()
            guard Int(elementBone) < bones else { throw MDLError.malformed("IK element bone \(elementBone) >= \(bones)") }
            var joints: [MDLSkeleton.IKSet.Joint] = []
            for _ in 0..<(try r.u16()) {
                let jointBone = try r.u32()
                let flags = try r.u32()
                let f0 = try r.f32()
                let f1 = try r.f32()
                let jointBones = try r.u32s(Int(try r.u16()))
                guard Int(jointBone) < bones, jointBones.allSatisfy({ Int($0) < bones }) else {
                    throw MDLError.malformed("IK joint bone out of range")
                }
                joints.append(.init(bone: jointBone, flags: flags, f0: f0, f1: f1, bones: jointBones))
            }
            elements.append(.init(bone: elementBone, joints: joints))
        }
        return MDLSkeleton.IKSet(bone: bone, links: setLinks, elements: elements)
    }
}
