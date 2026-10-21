import Foundation
import simd

/// A Wallpaper Engine `.mdl` model: the meshes of its `MDLV` part and the sections after it
/// (docs/models-plan.md §1). Static models, animated models and Puppet Warp rigs all use it.
/// `MDLReader` reads every version WE's runtime reads.
public struct MDLModel: Equatable {
    /// A section after the meshes (`MDLV` 13 and later), where it sat in the file.
    public struct Section: Equatable {
        public var tag: String
        /// The tag's offset.
        public var offset: Int
        /// The stored end: the next tag's offset.
        public var end: Int
        /// Where reading it stopped (equal to `end` in every library file). WE skips to `end`.
        public var parsedEnd: Int
        /// A tag WE doesn't read.
        public var skipped: Bool

        public init(tag: String, offset: Int, end: Int, parsedEnd: Int, skipped: Bool) {
            self.tag = tag
            self.offset = offset
            self.end = end
            self.parsedEnd = parsedEnd
            self.skipped = skipped
        }
    }

    /// `MDLVnnnn`.
    public var tag: String
    /// The `nnnn` of the tag (`atoi(tag + 4)`).
    public var version: Int
    /// The vertex format of every mesh before `MDLV` 15.
    public var legacyFormat: UInt32
    public var materialsPerMesh: UInt32
    public var meshes: [MDLMesh]
    public var sections: [Section] = []
    public var skeleton: MDLSkeleton?
    /// The `MDLA` version, with `animations`.
    public var animationsVersion: Int?
    public var animations: [MDLAnimation]?
    public var attachments: [MDLAttachment]?
    /// One entry per mesh, when the file has an `MDMP0001` section.
    public var morphTargets: [MDLMorphTargets]?
    /// `MDLE0002`: one local matrix per bone. Puppet Warp's "Reference Pose" writes it: the
    /// reference pose becomes the bind pose (`MDLS`, with the mesh skinned into it) and this keeps
    /// the bones' locals from before (WE 2.8's capture 509 C). The wallpaper draws the bind pose;
    /// nothing here reads it.
    public var referencePose: [simd_float4x4]?
    /// Where WE's reader stops: after the meshes before `MDLV` 13, else after the empty tag.
    public var end: Int
    /// Bytes after `end` (old writers left 0x00 or 0xCD fill); WE never reads them.
    public var trailingByteCount: Int

    /// The model's box as WE builds it (`MDLBounds.union`).
    public var bounds: MDLBounds { MDLBounds.union(of: meshes.map(\.bounds)) }

    /// The clip with that `id` (what an animation layer's `animation` names).
    public func animation(id: UInt64) -> MDLAnimation? { animations?.first { $0.id == id } }

    /// The attachment with exactly that name (a scene object's `attachment`).
    public func attachment(named name: String) -> MDLAttachment? { attachments?.first { $0.name == name } }

    public init(tag: String, version: Int, legacyFormat: UInt32, materialsPerMesh: UInt32, meshes: [MDLMesh], sections: [Section] = [], skeleton: MDLSkeleton? = nil, animationsVersion: Int? = nil, animations: [MDLAnimation]? = nil, attachments: [MDLAttachment]? = nil, morphTargets: [MDLMorphTargets]? = nil, referencePose: [simd_float4x4]? = nil, end: Int, trailingByteCount: Int) {
        self.tag = tag
        self.version = version
        self.legacyFormat = legacyFormat
        self.materialsPerMesh = materialsPerMesh
        self.meshes = meshes
        self.sections = sections
        self.skeleton = skeleton
        self.animationsVersion = animationsVersion
        self.animations = animations
        self.attachments = attachments
        self.morphTargets = morphTargets
        self.referencePose = referencePose
        self.end = end
        self.trailingByteCount = trailingByteCount
    }
}
