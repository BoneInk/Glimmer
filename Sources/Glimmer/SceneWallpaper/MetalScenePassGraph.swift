import Foundation
import CoreGraphics

/// Independent, experimental Metal contract. These are local operations, NOT a
/// decoder for Wallpaper Engine material JSON, shaders or built-in effects.
/// A render is limited to 128 Mi estimated sample-work units (clears plus
/// clipped quad AABBs; linear sampling counts four taps), 256 MiB of textures,
/// and a conservative 512 MiB peak estimate including CPU copies/readback.
/// Opaque driver/ImageIO scratch is not represented as a process RSS hard cap.
enum MetalSceneBlend: String, CaseIterable { case sourceOver, copy, additive }
enum MetalSceneSampling { case nearest, linear }
struct MetalSceneTexture {
    let width: Int
    let height: Int
    /// Tightly packed, top-to-bottom RGBA8, straight alpha, encoded color bytes.
    let rgba: Data
}
struct MetalSceneDraw {
    let source: String
    /// Maps a centered local quad into target pixels; target pixels are y-up.
    let transform: SceneAffineTransform
    let size: SceneVector2
    var tint = SceneVector3(x: 1, y: 1, z: 1)
    var opacity: Double = 1
    var sampling: MetalSceneSampling = .nearest
    var blend: MetalSceneBlend = .sourceOver
}
struct MetalScenePass {
    let target: String
    let width: Int
    let height: Int
    /// Straight-alpha clear color; converted to premultiplied RGBA before clear.
    var clear = SIMD4<Double>(0, 0, 0, 0)
    /// Optional pixel-edge bounds (left, top, right, bottom). No antialias promise.
    var clip: SIMD4<Double>? = nil
    let draws: [MetalSceneDraw]
}
struct MetalSceneReadback {
    let width: Int
    let height: Int
    /// Top-to-bottom RGBA8 premultiplied pixels. No implicit sRGB conversion.
    let rgba: Data
    let deviceName: String
    func makeImage() throws -> CGImage {
        guard let provider = CGDataProvider(data: rgba as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                  bitsPerPixel: 32, bytesPerRow: width * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw SceneWallpaperFailure(message: "Metal readback image creation failed.") }
        return image
    }
}
