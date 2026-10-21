import Foundation
import simd

/// A text object's font effects: `outline`, `blur` and `dropshadow` with their sizes and colours.
///
/// WE draws them in its `font` shader from an MSDF glyph atlas (`shaders/font.frag`, `MSDF` with
/// `OUTLINE_ENABLED`, `BLUR_ENABLED`, `DROP_SHADOW_ENABLED`), whose atlas has 32 px per em and a
/// 24 px distance range (`MSDF_RANGE`). The engine sets the shader's values from the object
/// (`wallpaper64.exe` 0x1401b3b60…0x1401b3f5f): each size is in scene units, turned into atlas
/// pixels by 32 / pointsize · 0.24 (the em is pointsize · 300/72 scene units), then clamped:
/// outline ≤ 5.1, blur, shadow size and offsets ≤ 6, and outline + blur ≤ 5.1.
///
/// Here the glyphs' distance field comes from their coverage raster (`SceneDistanceField`) instead
/// of an MSDF atlas, and `render` evaluates the shader's math on it per pixel. The corners MSDF
/// keeps sharp are rounded by at most the raster's antialiasing.
struct SceneTextEffects: Equatable {
    struct Outline: Equatable {
        var thickness: Float
        var color: SIMD3<Float>
    }

    struct DropShadow: Equatable {
        var size: Float
        var opacity: Float
        var offset: SIMD2<Float>
        var color: SIMD3<Float>
    }

    var outline: Outline?
    /// `blursize`, when `blur` is on.
    var blur: Float?
    var dropShadow: DropShadow?

    /// What the engine enables and sets on the shader (0x1401b3b81…0x1401b3cf5): the outline from
    /// a thickness of 1, blur from above 0, the shadow from a size above 0 or any offset.
    struct ShaderValues: Equatable {
        var outlineEnabled = false
        var blurEnabled = false
        var dropShadowEnabled = false
        /// `g_RenderVar0.yzw`, atlas pixels.
        var outlineWidth: Float = 0
        var blurRadius: Float = 0
        var dropShadowRadius: Float = 0
        /// `g_RenderVar1.w`, `g_RenderVar2.w`, atlas pixels.
        var dropShadowOffset = SIMD2<Float>(0, 0)
    }

    /// `MSDF_RANGE`, `g_RenderVar0.x` (0x1401b3db8).
    static let distanceRange: Float = 24

    /// Atlas pixels per scene unit at `pointSize` (0x1401b3d9e…0x1401b3dc9, the size clamped to
    /// 1…256 as the atlas key's is, 0x1401b054a).
    static func atlasPixelsPerUnit(pointSize: Float) -> Float {
        32 / min(max(pointSize, 1), 256) * 0.24
    }

    /// Whether the object draws any effect.
    var isEmpty: Bool { outline == nil && blur == nil && dropShadow == nil }

    func shaderValues(pointSize: Float) -> ShaderValues {
        let scale = Self.atlasPixelsPerUnit(pointSize: pointSize)
        var values = ShaderValues()
        let thickness = outline?.thickness ?? 0
        let blurSize = blur ?? 0
        let shadowSize = dropShadow?.size ?? 0
        let offset = dropShadow?.offset ?? .zero
        values.outlineEnabled = thickness >= 1
        values.blurEnabled = blurSize > 0
        values.dropShadowEnabled = dropShadow != nil && (shadowSize > 0 || simd_length_squared(offset) > 1.1920929e-7)
        values.outlineWidth = min(scale * thickness, 5.1)
        values.blurRadius = min(scale * blurSize, 6)
        values.dropShadowRadius = min(scale * shadowSize, 6)
        values.dropShadowOffset = SIMD2(min(scale * offset.x, 6), min(scale * offset.y, 6))
        if values.blurRadius + values.outlineWidth > 5.1 {
            values.outlineWidth = max(5.1 - values.blurRadius, 0)
        }
        return values
    }

    /// The text with its effects as straight-alpha RGBA, from the glyphs' `coverage` (one byte per
    /// pixel, row 0 at the top) rasterised at `pixelsPerUnit` pixels per scene unit, which is also
    /// the pixels the text is shown at. `fill` is the text's colour; its opacity is applied when drawn.
    func render(coverage: [UInt8], width: Int, height: Int, pixelsPerUnit: Float, pointSize: Float,
                fill: SIMD3<Float>) -> [UInt8] {
        let values = shaderValues(pointSize: pointSize)
        let distances = SceneDistanceField.signedDistances(coverage: coverage, width: width, height: height)
        let atlasPerPixel = Self.atlasPixelsPerUnit(pointSize: pointSize) / max(pixelsPerUnit, 1e-6)
        let smooth = values.blurEnabled || values.dropShadowEnabled
        // The shadow samples the atlas `offset` atlas pixels up and left of the fragment.
        let shift = values.dropShadowOffset / atlasPerPixel
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        func atlasDistance(_ x: Float, _ y: Float) -> Float {
            let ix = Int(saturating: x.rounded(), in: 0...max(width - 1, 0)), iy = Int(saturating: y.rounded(), in: 0...max(height - 1, 0))
            let d = distances[iy * width + ix] * atlasPerPixel
            return min(max(d, -Self.distanceRange / 2), Self.distanceRange / 2)
        }
        func sample(_ distance: Float, _ threshold: Float, _ radius: Float) -> Float {
            if smooth {
                let half = max(radius, 0.5)
                return Self.smoothstep(-half, half, distance + threshold - 0.5)
            }
            return min(max(distance + threshold, 0), 1)
        }
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                let distance: Float, outlineWidth: Float, blurRadius: Float
                if values.blurEnabled {
                    distance = atlasDistance(Float(x), Float(y))
                    outlineWidth = values.outlineWidth
                    blurRadius = values.blurRadius
                } else {
                    // Screen pixels: the raster is at the size the text is shown.
                    distance = distances[i]
                    outlineWidth = values.outlineWidth / atlasPerPixel
                    blurRadius = 0
                }
                let fillCoverage = sample(distance, 0.5, blurRadius)
                var color = fill
                var alpha = fillCoverage
                if values.outlineEnabled, let outline {
                    color = outline.color + (fill - outline.color) * fillCoverage
                    alpha = sample(distance, 0.5 + outlineWidth, blurRadius)
                }
                if values.dropShadowEnabled, let dropShadow {
                    let shadowDistance = atlasDistance(Float(x) - shift.x, Float(y) - shift.y)
                    let threshold: Float = values.outlineEnabled ? 0.5 + values.outlineWidth : 0.5
                    let half = max(values.dropShadowRadius, 0.5)
                    let shadow = min(max(dropShadow.opacity
                        * Self.smoothstep(-half, half, shadowDistance + threshold - 0.5), 0), 1)
                    let outAlpha = alpha + shadow * (1 - alpha)
                    color = (color * alpha + dropShadow.color * shadow * (1 - alpha)) / max(outAlpha, 1e-6)
                    alpha = outAlpha
                }
                let base = i * 4
                rgba[base] = Self.byte(color.x)
                rgba[base + 1] = Self.byte(color.y)
                rgba[base + 2] = Self.byte(color.z)
                rgba[base + 3] = Self.byte(alpha)
            }
        }
        return rgba
    }

    static func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    private static func byte(_ value: Float) -> UInt8 {
        UInt8((min(max(value, 0), 1) * 255).rounded())
    }
}
