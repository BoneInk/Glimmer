import CoreGraphics
import Foundation
import ImageIO
import OWESceneEditing

/// A layer's Create Mask from Depth Map: the generated depth map, shaped by Invert and Contrast
/// (`DepthMask`), written as the mask of one of the layer's effects the way WE's editor stores a
/// painted one: an R8 `.tex` in `materials/masks/<material>_mask_<hash>.tex`, named in the
/// `textures` of the effect pass that samples it at the slot's index (`masks/<material>_mask_<hash>`;
/// Blur's in its fourth pass, `blur_combine`), a first pass's `MASK` combo switched on as setting
/// any mask does. One undo step; a mask it replaces stays on disk, so Undo
/// brings it back as it was.
///
/// **Layer Opacity**, listed first, is WE's Opacity effect's mask (`DepthMask.opacityEffect`): the
/// layer's first Opacity effect, or, when it has none, the effect added with the mask in the same
/// undo step, so the layer is transparent where the mask is black.
extension DepthMapSectionModel {
    /// One mask the depth map can fill: an effect's grey mask slot (`"mode": "opacitymask"`).
    public struct MaskTarget: Identifiable, Hashable {
        public var effectKey: String
        public var effectFile: String
        /// What the mask file is named after: the sampling pass's material (`blur_combine`), else
        /// the effect's folder.
        public var maskName: String
        public var slot: EffectSchema.TextureSlot
        /// What the menu shows: the effect, and the slot's label when the effect has several masks.
        public var title: String
        /// The mask the effect has now, when it has its own (not the shader's default).
        public var currentMask: String?
        /// Layer Opacity on a layer without an Opacity effect: using it adds the effect
        /// (`effectKey` is empty until then).
        public var addsEffect = false
        /// Layer Opacity: WE's Opacity effect's mask (the first Opacity effect, or the one to add).
        public var isLayerOpacity = false

        public var id: String { addsEffect ? "opacity:\(slot.pass):\(slot.slot)" : "\(effectKey):\(slot.pass):\(slot.slot)" }
        public var replacesMask: Bool { currentMask != nil }
    }

    /// The section's title: the scene's depth parallax, or a layer's mask maker.
    public var title: String {
        layerID == nil ? DL("Scene Depth Parallax") : DL("Create Mask from Depth Map")
    }

    /// The layer's effects with a grey mask slot, in the order they apply, after Layer Opacity:
    /// the first Opacity effect's mask, or WE's Opacity effect to add.
    public var maskTargets: [MaskTarget] {
        guard let layerID, let layer = session.outline.layer(layerID) else { return [] }
        var targets: [MaskTarget] = []
        var layerOpacity: MaskTarget?
        for effect in layer.effects where effect.file != SceneDepthParallax.effectFile {
            let slots = (services.effectSchema(effect.file)?.textures ?? []).filter(\.isOpacityMask)
            let isLayerOpacity = layerOpacity == nil && slots.count == 1 && DepthMask.isOpacityEffect(effect.file)
            for slot in slots {
                let current = session.effectTexture(slot.slot, pass: slot.pass, effect: effect.key, of: layerID)
                let own = current.flatMap { $0.isEmpty || $0 == slot.defaultTexture ? nil : $0 }
                let target = MaskTarget(effectKey: effect.key, effectFile: effect.file,
                                        maskName: slot.materialName ?? effect.folderName, slot: slot,
                                        title: isLayerOpacity ? DL("Layer Opacity")
                                            : slots.count > 1 ? "\(effect.title) › \(slot.title)" : effect.title,
                                        currentMask: own, isLayerOpacity: isLayerOpacity)
                if isLayerOpacity { layerOpacity = target } else { targets.append(target) }
            }
        }
        if layerOpacity == nil, let slot = services.effectSchema(DepthMask.opacityEffect.file)?.textures.first(where: \.isOpacityMask) {
            layerOpacity = MaskTarget(effectKey: "", effectFile: DepthMask.opacityEffect.file,
                                      maskName: slot.materialName ?? DepthMask.opacityEffect.folderName, slot: slot,
                                      title: DL("Layer Opacity"), addsEffect: true, isLayerOpacity: true)
        }
        return (layerOpacity.map { [$0] } ?? []) + targets
    }

    /// Writes the depth map, shaped, as `target`'s mask; Layer Opacity on a layer without an
    /// Opacity effect adds it with the mask. One undo step.
    public func useAsMask(_ target: MaskTarget) {
        problem = nil
        guard let layerID, let texture = generatedTexture else { return }
        do {
            if target.addsEffect {
                try services.prepareBuiltInEffect(DepthMask.opacityEffect)
            }
            let path = try writeMask(from: texture, name: target.maskName)
            if target.addsEffect {
                session.addEffect(DepthMask.opacityEffect, to: layerID, texture: path, slot: target.slot.slot, pass: target.slot.pass,
                                  combo: target.slot.combo, actionName: DL("Use Depth Map as Mask"))
                maskNotice = DL("The depth map is now the layer’s opacity, through the Opacity effect added to it.")
            } else {
                session.setEffectTexture(path, slot: target.slot.slot, pass: target.slot.pass, effect: target.effectKey, of: layerID,
                                         combo: target.slot.combo, actionName: DL("Use Depth Map as Mask"))
                maskNotice = target.replacesMask
                    ? DL("The effect’s mask was replaced. Undo brings the old one back; its file is kept.")
                    : DL("The depth map is now the effect’s mask.")
            }
        } catch {
            problem = error.localizedDescription
        }
    }

    enum MaskFailure: LocalizedError {
        case unreadable

        var errorDescription: String? { DL("The depth map couldn’t be read to make the mask.") }
    }

    /// The mask's `.tex` kept with the editor's files; returns its texture path. The mask is the
    /// layer's size (as a painted mask is, `MaskPainting.pixelSize`), else the depth map's.
    func writeMask(from texture: String, name: String) throws -> String {
        guard let url = services.assetStore.depthMapURL(texture),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw MaskFailure.unreadable }
        let size = layerID.flatMap { session.geometry(of: $0)?.size }.flatMap(MaskPainting.pixelSize(for:))
            ?? SIMD2(image.width, image.height)
        guard let depth = Self.grayPixels(of: image, width: size.x, height: size.y) else { throw MaskFailure.unreadable }
        let mask = DepthMask.shaped(depth, invert: maskInverted, contrast: maskContrast)
        return try services.assetStore.saveEffectMask(services.encodeMask(mask, size.x, size.y), name: name)
    }

    /// `image` drawn into `width` × `height` grey values, rows top to bottom.
    nonisolated static func grayPixels(of image: CGImage, width: Int, height: Int) -> [UInt8]? {
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height))
    }

    /// The preview of a layer's mask: the depth preview, at most 256 pixels across, shaped.
    func refreshMaskPreview() {
        guard layerID != nil, let depth = depthPreview else {
            maskPreview = nil
            return
        }
        let scale = min(1, 256 / Double(max(depth.width, depth.height)))
        let width = max(Int(Double(depth.width) * scale), 1), height = max(Int(Double(depth.height) * scale), 1)
        guard let pixels = Self.grayPixels(of: depth, width: width, height: height) else { return }
        let shaped = DepthMask.shaped(pixels, invert: maskInverted, contrast: maskContrast)
        guard let provider = CGDataProvider(data: Data(shaped) as CFData) else { return }
        maskPreview = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                              provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
