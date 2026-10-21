import Foundation

extension SceneEngineCombos {
    /// `HDR=1` on every material while the scene draws in HDR (`hdr`; docs/lighting-plan.md §2.6,
    /// 0x1401a6721): CombineLighting's and the emissive maps' overbright, `g_Brightness` in
    /// generic2, the ccsimple LUT's range. Nothing otherwise: `common_blending.h` tests
    /// `#ifdef HDR`, so an LDR material must not see the name at all.
    func hdrCombos(for material: [String: Int]) -> [String: Int] {
        hdr ? ["HDR": 1] : [:]
    }
}
