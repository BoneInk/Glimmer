import Foundation

/// A Puppet Warp clipping mask (docs/models-plan.md §2.13a): one `MDLV` 23 group record
/// (`MDLMesh.Group`), which WE's editor writes from the puppet JSON's `clippingmasks` (WE 2.8's
/// captures 532 and 532c). Its lists index the mesh's ranges (`MDLMesh.boneRanges`): the editor
/// splits a bone's range where its triangles change vertex island, so each range lies in one
/// island, and an island assigned to a mask (`vertexislands[i].clippingmaskid`) is the mask's
/// clipped ranges.
///
/// WE's reader (0x140261c0d…0x140262025) keeps a record of 0x50 bytes: id, the clipped ranges
/// (+0x08), the masking ranges (+0x20), the texture (+0x38), the clipped draw's blending (+0x40:
/// 2, additive, with flag 0x1, else 1, translucent), the flags (+0x44) and the parent (+0x48).
public struct MDLClippingMask: Equatable {
    /// The record's flags, as the editor writes them from the mask's settings.
    public struct Flags: OptionSet, Equatable {
        public let rawValue: UInt32
        /// The clipped parts draw additive (the limb's "Additive blending"; 0x140261c45 → +0x40 = 2).
        public static let additive = Flags(rawValue: 0x1)
        /// The mask's coverage is inverted: the clear colour is 1 and `g_RenderVar0.x` is 1
        /// (0x14020d72e, 0x14020d787), which `clippingmaskimage4` turns into `1 − r` ("Invert mask").
        public static let invert = Flags(rawValue: 0x2)
        /// The masking parts aren't drawn themselves, only into the mask (0x14020ba27; "Hide mask
        /// geometry", capture 532 g_mask_hide: flags 4, the red limb gone).
        public static let hidesMaskGeometry = Flags(rawValue: 0x4)
        /// The clipped parts draw at their own place in the draw order, not right after the last
        /// masking part (0x14020b622 marks them, 0x14020c11e draws them). WE's editor wrote it with
        /// "Invert mask" (capture 532 g_mask_invert: flags 0xa) [I: what else sets it].
        public static let drawsInPlace = Flags(rawValue: 0x8)

        public init(rawValue: UInt32) {
            self.rawValue = rawValue
        }
    }

    public var id: UInt64
    /// The mask texture (the puppet JSON's `texture`, e.g. `masks/clipping_mask_608392ae`), a
    /// single-channel `.tex` relative to `materials/`, painted in texture space.
    public var texture: String
    public var flags: Flags
    /// Ranges drawn only where the mask covers them (WE's +0x08).
    public var clippedRanges: [Int]
    /// Ranges the mask is drawn through (+0x20): the limbs the mask was painted over.
    public var maskRanges: [Int]
    /// The mask this one nests in (+0x48): every one of its masking ranges is clipped by that
    /// mask, so its coverage is intersected with that mask's. nil at the top.
    public var parent: Int?

    /// The mesh's masks, nested as WE nests them (0x140262032…0x1402622c9): a mask whose masking
    /// ranges are all clipped ranges of another mask has that one, the first such, as its parent;
    /// one whose parent chain comes back to a mask already on it has none ("A clipping mask is
    /// incorrectly nested within another clipping mask"). Empty without groups.
    public static func masks(of mesh: MDLMesh) -> [MDLClippingMask] {
        var masks = (mesh.groups ?? []).map {
            MDLClippingMask(id: $0.id, texture: $0.name, flags: Flags(rawValue: $0.flags),
                            clippedRanges: $0.listA.map(Int.init), maskRanges: $0.listB.map(Int.init), parent: nil)
        }
        guard masks.count > 1 else { return masks }
        for index in masks.indices where !masks[index].maskRanges.isEmpty {
            let ranges = masks[index].maskRanges
            guard let parent = masks.indices.first(where: { other in
                other != index && ranges.allSatisfy(masks[other].clippedRanges.contains)
            }) else { continue }
            masks[index].parent = parent
            // The walk starts at the parent and stops at the first mask seen twice.
            var seen = Set<Int>(), next: Int? = parent
            while let current = next {
                if !seen.insert(current).inserted {
                    masks[index].parent = nil
                    break
                }
                next = masks[current].parent
            }
        }
        return masks
    }

    public init(id: UInt64, texture: String, flags: Flags, clippedRanges: [Int], maskRanges: [Int], parent: Int? = nil) {
        self.id = id
        self.texture = texture
        self.flags = flags
        self.clippedRanges = clippedRanges
        self.maskRanges = maskRanges
        self.parent = parent
    }
}
