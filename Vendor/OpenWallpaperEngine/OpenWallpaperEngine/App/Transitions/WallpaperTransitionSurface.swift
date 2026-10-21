import CoreVideo
import IOSurface
import Metal

/// The IOSurfaces a transition's frames are drawn into for a layer's contents (and the live
/// screen saver's frames, `ScreenSaverFramePublisher`).
enum WallpaperTransitionSurface {
    /// How many a player uses in turn.
    static let count = 3

    /// An IOSurface of `size` can't be made.
    struct Failure: Error, CustomStringConvertible {
        let size: SIMD2<Int>

        var description: String { "can't allocate a \(size.x)×\(size.y) frame" }
    }

    /// A BGRA IOSurface of `size` in sRGB and a render target over it. A `global` surface can be
    /// looked up by id from another process (`IOSurfaceLookup`, the `.saver`'s only way to it).
    static func make(_ size: SIMD2<Int>, device: MTLDevice, global: Bool = false) throws -> (surface: IOSurface, texture: MTLTexture) {
        var properties: [IOSurfacePropertyKey: Any] = [
            .width: size.x, .height: size.y, .bytesPerElement: 4,
            .pixelFormat: kCVPixelFormatType_32BGRA,
        ]
        // `kIOSurfaceIsGlobal` is deprecated (any process may read a global surface) but is what
        // the screen saver's sandboxed host can reach; its key is spelled out to avoid the warning.
        if global { properties[IOSurfacePropertyKey(rawValue: "IOSurfaceIsGlobal")] = true }
        guard let surface = IOSurface(properties: properties) else { throw Failure(size: size) }
        if let space = CGColorSpace(name: CGColorSpace.sRGB)?.copyPropertyList() {
            IOSurfaceSetValue(surface, kIOSurfaceColorSpace, space)
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: size.x,
                                                                  height: size.y, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
        guard let texture = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0) else {
            throw Failure(size: size)
        }
        return (surface, texture)
    }
}
