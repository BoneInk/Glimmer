import Cocoa
import MetalKit
import CryptoKit

struct LayerUniform {
    var position: SIMD2<Float>
    var size: SIMD2<Float>
    var sceneSize: SIMD2<Float>
    var opacity: Float
    var particleShape: Float
    var rotation: Float
    var color: SIMD4<Float>
    var uvOrigin: SIMD2<Float>
    var uvAxisX: SIMD2<Float>
    var uvAxisY: SIMD2<Float>
    var effects: SIMD4<Float>
    var blur: Float
    var colorEffects: SIMD4<Float>
    var transform: SIMD4<Float>
    var transformScaleY: Float
    var bloomTint: SIMD4<Float> = SIMD4<Float>(repeating: 1)
    /// Full-extent quad axes (y-up scene space). Zero means build the quad from size and rotation.
    var quadAxisX: SIMD2<Float> = .zero
    var quadAxisY: SIMD2<Float> = .zero
}

struct DXTDecodeUniform {
    var width: UInt32
    var height: UInt32
    var blockColumns: UInt32
    var format: UInt32
}
