import AppKit
import Metal
import MetalKit

/// Everything one text raster needs, read on the render thread (user settings, script values) so
/// the raster itself can run anywhere.
struct SceneTextRasterRequest {
    let text: SceneMetalText
    let value: String
    /// The font the layer asks for (the user's, else authored, else none: Arial, as in WE).
    let fontName: String
    let pointSize: Float
    let bold: Bool
    let italic: Bool
    let rasterScale: Float
    /// nil rasterises white coverage, coloured when drawn; a colour rasterises the text in it.
    let fill: SIMD3<Float>?
}

/// A finished text raster: the frame to draw, the block size the layout settled on and its bytes.
struct SceneTextRasterResult {
    let frame: RenderTextureFrame
    let baseSize: SIMD2<Float>
    let cost: Int
}

/// Lays out and rasterises a text layer and uploads it (Core Text, then Metal). Touches no
/// renderer state, so it runs on a pool job as well as on the render thread.
enum SceneTextRaster {
    static func render(_ request: SceneTextRasterRequest, device: MTLDevice,
                       loader: MTKTextureLoader) -> SceneTextRasterResult? {
        let text = request.text
        let pixelSize = SceneTextLayout.pixelSize(pointSize: CGFloat(request.pointSize))
        var font = Self.font(named: request.fontName, size: pixelSize, loader: text.fonts)
        if request.bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        if request.italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        let layout = SceneTextLayout(text: request.value, font: font, padding: text.padding,
                                     horizontalAlignment: text.horizontalAlignment,
                                     verticalAlignment: text.verticalAlignment,
                                     maxWidth: text.maxWidth, maxRows: text.maxRows, useEllipsis: text.useEllipsis,
                                     blockAlign: text.blockAlign, spacing: text.spacing)
        // A white coverage mask, as WE's `font` shader samples its glyphs: colour (authored and
        // the user's), alpha and brightness are applied when the quad is drawn. Font effects colour
        // a white raster themselves (`effectText`).
        let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let color = text.effects != nil ? white
            : request.fill.map { NSColor(srgbRed: CGFloat($0.x), green: CGFloat($0.y), blue: CGFloat($0.z), alpha: 1) }
                ?? white
        let pixels = SceneTextRasterScale.clamped(request.rasterScale, boxSize: layout.boxSize)
        // A background box is drawn under plain glyphs; font effects composite their output over it.
        guard let image = layout.rasterize(font: font, color: color, pixelsPerUnit: CGFloat(pixels),
                                           background: text.effects == nil ? text.background : nil),
              let texture = text.effects.map({ effectText(image, effects: $0, pointSize: request.pointSize,
                                                          pixelsPerUnit: pixels, fill: request.fill ?? SIMD3(repeating: 1),
                                                          background: text.background, device: device) })
                ?? (try? SceneTextureUpload.texture(from: image, loader: loader, device: device)) else {
            OWELog.error(.scene, "Text: could not rasterise \(layout.boxSize) at \(pixels) px/unit")
            return nil
        }
        var coverage: MTLTexture?
        do {
            // Text with font effects or a background has no coverage mask: it draws its coloured raster.
            if !text.rastersInColor { coverage = try SceneTextureUpload.coverageTexture(from: image, device: device) }
        } catch {
            OWELog.error(.scene, "Text: no coverage texture, drawn natively: \(error)")
            coverage = nil
        }
        let frame = RenderTextureFrame(texture: texture, duration: .greatestFiniteMagnitude,
                                       uvOrigin: .zero, uvAxisX: SIMD2(1, 0), uvAxisY: SIMD2(0, 1), coverage: coverage,
                                       textCenter: layout.boxCenter)
        return SceneTextRasterResult(frame: frame, baseSize: layout.boxSize,
                                     cost: texture.allocatedSize + (coverage?.allocatedSize ?? 0))
    }

    /// The font `name` (a scene's font path, or an installed font's name) names: one the scene
    /// registered, an installed one, else one `loader` finds and registers now (a path only a
    /// script named), else Arial, as in WE.
    static func font(named name: String, size: CGFloat, loader: SceneTextFontLoader?) -> NSFont {
        if let font = SceneFontRegistry.font(named: name, size: size) ?? NSFont(name: name, size: size) { return font }
        if !name.isEmpty, let registered = loader?.register(name),
           let font = SceneFontRegistry.font(named: name, size: size) ?? NSFont(name: registered, size: size) {
            return font
        }
        return SceneTextFallbackFont.font(size: size)
    }

    /// The glyphs of `image` (a white raster) with their font effects, as straight-alpha RGBA in
    /// `fill`'s colour; nil (the caller logs) when it can't be read or uploaded.
    /// Over `background`, when there is one, the result is opaque.
    static func effectText(_ image: CGImage, effects: SceneTextEffects, pointSize: Float, pixelsPerUnit: Float,
                           fill: SIMD3<Float>, background: SIMD3<Float>? = nil, device: MTLDevice) -> MTLTexture? {
        guard let coverage = try? SceneTextureUpload.whiteCoverage(image) else { return nil }
        var rgba = effects.render(coverage: coverage, width: image.width, height: image.height,
                                  pixelsPerUnit: pixelsPerUnit, pointSize: pointSize, fill: fill)
        if let background { composite(&rgba, over: background) }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: image.width,
                                                                  height: image.height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        rgba.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0,
                            withBytes: raw.baseAddress!, bytesPerRow: image.width * 4)
        }
        return texture
    }

    /// Straight-alpha RGBA8 `rgba` drawn over an opaque `background` (0…1), in place.
    static func composite(_ rgba: inout [UInt8], over background: SIMD3<Float>) {
        let base = [background.x, background.y, background.z].map { min(max($0.isFinite ? $0 : 0, 0), 1) * 255 }
        var index = 0
        while index + 3 < rgba.count {
            let alpha = Float(rgba[index + 3]) / 255
            for channel in 0..<3 {
                let value = Float(rgba[index + channel]) * alpha + base[channel] * (1 - alpha)
                rgba[index + channel] = UInt8(min(max(value.rounded(), 0), 255))
            }
            rgba[index + 3] = 255
            index += 4
        }
    }
}

/// Double-buffered text rasters: when a layer's string changes, the render thread keeps drawing
/// the layer's previous raster while a pool job makes the new one, and draws the new one from the
/// first frame after it lands (so a change shows a frame late instead of stalling the frame).
/// A layer's first raster, with nothing to show before it, is made on the spot.
///
/// A slot is one drawn raster of a layer (its id, and whether it's the scene draw or its
/// composite). Only the render thread calls it, except the jobs' hand-back, which is locked.
final class SceneTextRasterQueue {
    private let device: MTLDevice
    private let loader: MTKTextureLoader
    private let queue = DispatchQueue(label: "owe.text-raster", qos: .userInitiated, attributes: .concurrent)
    private let lock = NSLock()
    /// Finished jobs, by cache key, waiting for the render thread to take them.
    private var finished: [(key: String, result: SceneTextRasterResult?)] = []
    /// Cache keys being rasterised.
    private var pending: Set<String> = []
    /// What each slot drew last.
    private var shown: [String: SceneTextRasterResult] = [:]
    /// Bumped by `reset`, so a job for dropped content is discarded.
    private var epoch = 0
    /// Jobs still rasterising.
    private var running = 0

    /// Rasters not yet taken by a frame: jobs running or finished and waiting (for tests).
    var inFlight: Int {
        lock.lock()
        defer { lock.unlock() }
        return running + finished.count
    }

    /// Whether a job finished since the last frame took them: the frame that takes it must draw
    /// (and redraw the text layer) even when nothing else changed.
    var hasFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !finished.isEmpty
    }

    init(device: MTLDevice, loader: MTKTextureLoader) {
        self.device = device
        self.loader = loader
    }

    /// Jobs that finished since the last call, for the caller's cache.
    func takeFinished() -> [(key: String, result: SceneTextRasterResult?)] {
        lock.lock()
        defer { lock.unlock() }
        let done = finished
        finished.removeAll(keepingCapacity: true)
        // A failed raster stays pending, so it isn't retried every frame (`reset` clears it).
        for item in done where item.result != nil { pending.remove(item.key) }
        return done
    }

    /// Records what `slot` draws this frame (a cache hit or a fresh raster).
    func show(_ result: SceneTextRasterResult, slot: String) { shown[slot] = result }

    /// A raster for `key` the cache doesn't hold: the slot's previous raster while a job makes
    /// this one, or, for a slot that hasn't drawn yet, one made now (`isNew`, for the caller's cache).
    func raster(key: String, slot: String,
                request: SceneTextRasterRequest) -> (result: SceneTextRasterResult, isNew: Bool)? {
        guard let previous = shown[slot] else {
            guard let result = SceneTextRaster.render(request, device: device, loader: loader) else { return nil }
            shown[slot] = result
            return (result, true)
        }
        lock.lock()
        let started = pending.insert(key).inserted
        let epoch = self.epoch
        if started { running += 1 }
        lock.unlock()
        if started {
            let device = self.device, loader = self.loader
            queue.async { [weak self] in
                let result = SceneTextRaster.render(request, device: device, loader: loader)
                guard let self else { return }
                self.lock.lock()
                self.running -= 1
                if self.epoch == epoch { self.finished.append((key, result)) } else { self.pending.remove(key) }
                self.lock.unlock()
            }
        }
        return (previous, false)
    }

    /// Forgets every slot and in-flight job (new content, or the cache was cleared).
    func reset() {
        shown.removeAll()
        lock.lock()
        epoch += 1
        finished.removeAll()
        pending.removeAll()
        lock.unlock()
    }
}
