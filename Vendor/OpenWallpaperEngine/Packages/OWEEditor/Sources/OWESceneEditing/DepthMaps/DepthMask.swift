import Foundation

/// A generated depth map shaped into an effect's grey mask (`"mode": "opacitymask"`), which the
/// layer's Create Mask from Depth Map writes into the effect's slot: white shows the effect and
/// black hides it, so by default the effect shows on what is near (a depth map's white).
///
/// - **Invert** swaps near and far, so the effect shows on the background instead.
/// - **Contrast** scales the grey around the middle (`(v − ½) × contrast + ½`, clamped): above 1
///   the mask gets harder, toward black and white; below 1 softer.
///
/// The mask is stored as WE's editor stores a painted one (`EditorAssetStore.saveEffectMask`).
///
/// **Layer Opacity** writes it into WE's Opacity effect (`effects/opacity`), added when the layer
/// has none: its shader multiplies the layer's alpha by `g_Texture1`'s red channel, a grey mask
/// (`"mode": "opacitymask"`) behind the `MASK` combo, so the layer shows where the mask is white
/// and is transparent where it is black.
public enum DepthMask {
    public static let contrastRange = 0.25...4.0
    public static let defaultContrast = 1.0

    /// WE's Opacity effect, which Layer Opacity adds when the layer has none.
    public static let opacityEffect = EffectCatalogEntry(file: "effects/opacity/effect.json", title: "Opacity",
                                                         group: "colorize", passCount: 1)

    /// Whether `file` is WE's Opacity effect.
    public static func isOpacityEffect(_ file: String) -> Bool {
        file.caseInsensitiveCompare(opacityEffect.file) == .orderedSame
    }

    /// `depth` (grey values, near is 255) shaped into the mask.
    public static func shaped(_ depth: [UInt8], invert: Bool, contrast: Double) -> [UInt8] {
        let table = lookup(invert: invert, contrast: contrast)
        return depth.map { table[Int($0)] }
    }

    /// The value each grey becomes.
    public static func lookup(invert: Bool, contrast: Double) -> [UInt8] {
        let factor = min(max(contrast, contrastRange.lowerBound), contrastRange.upperBound)
        return (0..<256).map { value in
            var v = Double(value) / 255
            if invert { v = 1 - v }
            v = (v - 0.5) * factor + 0.5
            return UInt8((min(max(v, 0), 1) * 255).rounded())
        }
    }
}

extension EditorAssetStore {
    /// Keeps an effect mask (a `.tex` file's contents) where WE's editor keeps a painted one,
    /// `materials/masks/<name>_mask_<hash>.tex`, and returns the path the effect's pass lists in
    /// its `textures` (`masks/<name>_mask_<hash>`). `name`: the sampling pass's material, as WE
    /// names them (`waterripple`, `blur_combine`). Named by its content, as every editor file is,
    /// so a mask it replaces stays on disk.
    public func saveEffectMask(_ tex: Data, name: String) throws -> String {
        let file = Self.assetName("\(name)_mask", data: tex).replacingOccurrences(of: "_mask-", with: "_mask_")
        try write(tex, to: "materials/masks/\(file).tex")
        return "masks/\(file)"
    }
}
