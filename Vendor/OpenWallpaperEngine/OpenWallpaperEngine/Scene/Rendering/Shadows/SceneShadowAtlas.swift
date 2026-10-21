import Metal
import simd

/// `_rt_shadowAtlas` (docs/models-plan.md §2.10; `wallpaper64.exe` 0x1401935dc…0x1401939ed): one
/// depth texture holding every shadow map of the frame, laid out by WE's shelf packer, grown when
/// a frame needs more room and never shrunk. Depth-only (D3D's R32 typeless, a D32_FLOAT view to
/// draw and an R32_FLOAT view to sample; `depth32Float` here), cleared to 0, WE's far plane: the
/// casters' reversed depth is larger nearer the light, and a lookup outside every map (or before
/// any caster drew) reads 0, which every receiver's depth passes, so it is lit.
///
/// Call on the render thread.
final class SceneShadowAtlas {
    static let name = "_rt_shadowAtlas"
    static let pixelFormat = MTLPixelFormat.depth32Float

    private let device: MTLDevice
    /// The atlas as it stands; nil until a frame first needs one.
    private(set) var texture: MTLTexture?
    /// A 2×2 atlas cleared to 0, bound where a material samples the atlas and no map was drawn
    /// yet (every lookup reads "lit").
    private var cleared: MTLTexture?
    private var clearedPending = false

    init(device: MTLDevice) {
        self.device = device
    }

    /// The atlas's size so far, which a frame's layout never shrinks (`SceneShadowAtlasLayout`).
    var extent: SIMD2<Int> { texture.map { SIMD2($0.width, $0.height) } ?? .zero }

    /// The atlas at `extent` (grown, keeping neither content nor layout: every map is redrawn each
    /// frame); nil when the texture can't be made (logged).
    func texture(extent: SIMD2<Int>) -> MTLTexture? {
        if let texture, texture.width >= extent.x, texture.height >= extent.y { return texture }
        let size = simd_max(self.extent, extent)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.pixelFormat, width: max(size.x, 2),
                                                                  height: max(size.y, 2), mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        guard let made = device.makeTexture(descriptor: descriptor) else {
            OWELog.error(.scene, "Can't make \(Self.name) of \(size.x)×\(size.y); shadows are skipped")
            return nil
        }
        made.label = Self.name
        texture = made
        return made
    }

    /// The texture a material's `_rt_shadowAtlas` reads this frame: the atlas, or the cleared
    /// stand-in until a frame drew one. The stand-in is cleared on `commandBuffer` the first time.
    func bound(commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        if let texture { return texture }
        if cleared == nil {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.pixelFormat, width: 2, height: 2,
                                                                      mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            cleared = device.makeTexture(descriptor: descriptor)
            cleared?.label = "\(Self.name) (cleared)"
            clearedPending = cleared != nil
        }
        if clearedPending, let cleared {
            let pass = MTLRenderPassDescriptor()
            pass.depthAttachment.texture = cleared
            pass.depthAttachment.loadAction = .clear
            pass.depthAttachment.clearDepth = 0
            pass.depthAttachment.storeAction = .store
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
            encoder.label = "\(Self.name) clear"
            encoder.endEncoding()
            clearedPending = false
        }
        return cleared
    }

    /// WE's comparison sampler for the atlas (0x140099980, key bit 27): linear comparison
    /// (`COMPARISON_MIN_MAG_MIP_LINEAR`), border addressing with a (0, 0, 0, 0) border, and the
    /// test GREATER: a receiver is lit where its depth is greater than the map's.
    static func makeSampler(device: MTLDevice) -> MTLSamplerState? {
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.mipFilter = .notMipmapped
        descriptor.sAddressMode = .clampToBorderColor
        descriptor.tAddressMode = .clampToBorderColor
        descriptor.borderColor = .transparentBlack
        descriptor.compareFunction = .greater
        descriptor.label = "\(name) comparison"
        return device.makeSamplerState(descriptor: descriptor)
    }

    /// A shadow map's side for the user's shadows setting (0x14025d3e0): 256 at low and medium,
    /// 512 at high, 1024 at ultra. A point light's cell and each directional cascade are one map.
    ///
    /// "Cheaper shadows" (`reduced`) draws each map at half that side, a quarter of the texels to
    /// rasterise and clear, never below `minimumReducedSize`; the atlas's linear comparison
    /// sampler and WE's receivers' PCF (`LIGHTS_SHADOW_MAPPING_QUALITY`) keep the edges smooth,
    /// and the setting still orders the sizes.
    static func mapSize(quality: Int, reduced: Bool = false) -> Int {
        let size: Int
        switch quality {
        case ...2: size = 256
        case 3: size = 512
        default: size = 1024
        }
        return reduced ? max(size / 2, minimumReducedSize) : size
    }

    static let minimumReducedSize = 128
}

/// WE's shelf packer for the atlas (0x1401935dc…0x1401939ed), as a pure function of the maps'
/// sizes.
///
/// - The maps are sorted by `(isPoint << 15) + size`, descending: points first, larger first
///   (0x14019e660; ties keep their order here, where WE's `std::sort` leaves them unspecified).
/// - The shelves start as one of the full width, 8192 texels, at y = 0 with its top at 0. Each map
///   walks the shelves in order: a shelf's top first rises to cover the map (`top = max(top,
///   y + size)`), then the map fits if the shelf's remaining width holds it. A shelf it doesn't fit
///   appends a new full-width shelf at that top, which the walk reaches later.
/// - The map goes at the shelf's left end (`x0`), which moves right by its size, and a shelf of the
///   map's width is appended above it, from `y + size` to the shelf's top.
/// - The atlas is `max(2, max x)` × `max(2, max y)`, not a power of two.
///
/// WE caches the layout while the sizes don't change (scene+0x408); the result is the same.
enum SceneShadowAtlasLayout {
    struct Map: Equatable {
        var size: Int
        var isPoint: Bool
    }

    struct Placement: Equatable {
        var x: Int
        var y: Int
    }

    static let shelfWidth = 8192

    /// Each map's corner, in the order of `maps`, and the extent they need.
    static func pack(_ maps: [Map]) -> (placements: [Placement], extent: SIMD2<Int>) {
        struct Shelf { var x0: Int; var x1: Int; var y: Int; var top: Int }
        let order = maps.indices.sorted { a, b in
            let keyA = key(maps[a]), keyB = key(maps[b])
            return keyA != keyB ? keyA > keyB : a < b
        }
        var shelves = [Shelf(x0: 0, x1: shelfWidth, y: 0, top: 0)]
        var placements = [Placement](repeating: Placement(x: 0, y: 0), count: maps.count)
        var maxX = 0, maxY = 0
        for index in order {
            let size = maps[index].size
            var shelf = 0
            while shelf < shelves.count {
                shelves[shelf].top = max(shelves[shelf].top, shelves[shelf].y + size)
                let current = shelves[shelf]
                if current.x1 - current.x0 >= size, current.top - current.y >= size {
                    placements[index] = Placement(x: current.x0, y: current.y)
                    maxX = max(maxX, current.x0 + size)
                    maxY = max(maxY, current.y + size)
                    shelves[shelf].x0 += size
                    if current.top - current.y > 0 {
                        shelves.append(Shelf(x0: current.x0, x1: current.x0 + size, y: current.y + size, top: current.top))
                    }
                    break
                }
                shelves.append(Shelf(x0: 0, x1: shelfWidth, y: current.top, top: current.top))
                shelf += 1
            }
        }
        return (placements, SIMD2(max(2, maxX), max(2, maxY)))
    }

    /// The sort key (0x140186c60).
    static func key(_ map: Map) -> Int { (map.isPoint ? 1 << 15 : 0) + map.size }
}
