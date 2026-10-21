import simd

/// The `MDLS` section, versions 1–4 (docs/models-plan.md §1.3): the bones, then (version 2 and
/// later) links, bind matrices, constraints, u32-keyed maps, IK sets and per-bone blocks. Every
/// library file with version 2 or later has links, constraints, maps and IK sets empty.
public struct MDLSkeleton: Equatable {
    /// A "link" record (0x80 bytes at model+0x78; the writer's `controllers` [I]).
    public struct Link: Equatable {
        public var name: String
        public var bone: UInt32
        /// 0 or 1: which of WE's two bone → link maps it goes in.
        public var type: UInt32
        public var matrix: simd_float4x4

        public init(name: String, bone: UInt32, type: UInt32, matrix: simd_float4x4) {
            self.name = name
            self.bone = bone
            self.type = type
            self.matrix = matrix
        }
    }

    /// A constraint: Puppet Warp's blend rule (the editor's `blendrules`; WE 2.8's capture 533,
    /// docs/models-plan.md §2.15; `SceneBlendRules`), unless the bone has flag 0x2.
    public struct Constraint: Equatable {
        public var bone: UInt32
        /// The weight the clips key: the index of the clips' constraint track.
        public var a: UInt32
        /// The target bone.
        public var b: UInt32
        /// Read from version 4 on, else 0. Bit 1: the two floats follow (the editor's `amin` and
        /// `amax`, which WE's compiler leaves out of a blend rule).
        public var flags: UInt32
        public var f0: Float?
        /// WE clamps it to at least FLT_EPSILON when it uses it; this is the file's value.
        public var f1: Float?

        public init(bone: UInt32, a: UInt32, b: UInt32, flags: UInt32, f0: Float? = nil, f1: Float? = nil) {
            self.bone = bone
            self.a = a
            self.b = b
            self.flags = flags
            self.f0 = f0
            self.f1 = f1
        }
    }

    /// One `u32 key → 12 bytes` entry of the maps WE keeps at model+0xf0 [?].
    public struct MapEntry: Equatable {
        public var key: UInt32
        public var value: SIMD3<Float>

        public init(key: UInt32, value: SIMD3<Float>) {
            self.key = key
            self.value = value
        }
    }

    public struct IKSet: Equatable {
        public struct Joint: Equatable {
            public var bone: UInt32
            /// Bit 2 sets the IK set's flag at +0x38.
            public var flags: UInt32
            public var f0: Float
            public var f1: Float
            public var bones: [UInt32]

            public init(bone: UInt32, flags: UInt32, f0: Float, f1: Float, bones: [UInt32]) {
                self.bone = bone
                self.flags = flags
                self.f0 = f0
                self.f1 = f1
                self.bones = bones
            }
        }

        public struct Element: Equatable {
            public var bone: UInt32
            public var joints: [Joint]

            public init(bone: UInt32, joints: [Joint]) {
                self.bone = bone
                self.joints = joints
            }
        }

        public var bone: UInt32
        /// Indices into `links`.
        public var links: [UInt32]
        public var elements: [Element]

        public init(bone: UInt32, links: [UInt32], elements: [Element]) {
            self.bone = bone
            self.links = links
            self.elements = elements
        }
    }

    /// The optional per-bone `{vec3, mat4}` block (model+0x1a0) [?].
    public struct BoneVector: Equatable {
        public var vector: SIMD3<Float>
        public var matrix: simd_float4x4

        public init(vector: SIMD3<Float>, matrix: simd_float4x4) {
            self.vector = vector
            self.matrix = matrix
        }
    }

    public var version: Int
    public var bones: [MDLBone]
    /// Version 2 and later, else empty (as are the lists below).
    public var links: [Link] = []
    /// One per bone, when the file has the optional block (model+0x48).
    public var bindMatrices: [simd_float4x4]?
    /// One per link, with `bindMatrices` (model+0x90).
    public var linkBindMatrices: [simd_float4x4]?
    public var constraints: [Constraint] = []
    public var mapIDs: [UInt32] = []
    /// One map per `mapIDs` entry, in file order.
    public var maps: [[MapEntry]] = []
    public var ikSets: [IKSet] = []
    public var boneVectors: [BoneVector]?
    /// One bone index per bone (model+0x1d0, which WE clamps to the last bone): in Puppet Warp
    /// rigs, the bones by draw depth, the order of the mesh's `BoneRange`s.
    public var boneIndices: [UInt32]?
    /// Version 3 and later: one u32 per bone (model+0x1e8), each bone's draw depth as a signed
    /// integer (`boneDepths`).
    public var bonePriorities: [UInt32]?

    /// `bonePriorities` as WE's editor writes them: Puppet Warp's "Limb Depth Order", the bone's
    /// Calculated depth (default 100 per bone in order, plus its Depth offset; "Move Limb to Back"
    /// takes 100 off, WE 2.8's capture 509 B), signed (−100 is 0xFFFFFF9C). The editor already
    /// sorts the mesh's index ranges by it, lowest first, so a static depth needs nothing at run
    /// time; a clip's keyed Depth offset (`MDLAnimation.boneDepthTracks`) reorders them.
    public var boneDepths: [Int32]? { bonePriorities?.map { Int32(bitPattern: $0) } }

    /// Each bone's bind pose in model space: `local · world(parent)` in WE's row-vector order,
    /// that is `world(parent) · local` for these column-vector matrices [I, consistent in the
    /// data]. Parents come before their children in every library file; a bone whose parent is
    /// out of range, or not yet computed, is taken as a root.
    public var bindPoseWorldMatrices: [simd_float4x4] {
        var world: [simd_float4x4] = []
        world.reserveCapacity(bones.count)
        for (index, bone) in bones.enumerated() {
            if let parent = bone.parentIndex, parent < index {
                world.append(world[parent] * bone.matrix)
            } else {
                world.append(bone.matrix)
            }
        }
        return world
    }

    public init(version: Int, bones: [MDLBone], links: [Link] = [], bindMatrices: [simd_float4x4]? = nil, linkBindMatrices: [simd_float4x4]? = nil, constraints: [Constraint] = [], mapIDs: [UInt32] = [], maps: [[MapEntry]] = [], ikSets: [IKSet] = [], boneVectors: [BoneVector]? = nil, boneIndices: [UInt32]? = nil, bonePriorities: [UInt32]? = nil) {
        self.version = version
        self.bones = bones
        self.links = links
        self.bindMatrices = bindMatrices
        self.linkBindMatrices = linkBindMatrices
        self.constraints = constraints
        self.mapIDs = mapIDs
        self.maps = maps
        self.ikSets = ikSets
        self.boneVectors = boneVectors
        self.boneIndices = boneIndices
        self.bonePriorities = bonePriorities
    }
}
