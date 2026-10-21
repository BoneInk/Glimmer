import CoreGraphics
import Foundation
import OWESceneEditing

/// Puppet Warp › Clipping Masks, as WE's editor has it: a limb (mesh island) is assigned a mask,
/// which is painted over the image where the limb may show (docs/models-plan.md §2.13a).
extension PuppetWorkspace {
    var clipping: PuppetClipping { document?.clippingOrEmpty ?? PuppetClipping() }

    /// The selected limb's mask, if it has one.
    var selectedLimbMask: PuppetClipping.Mask? {
        guard let selectedLimb, clipping.limbs.indices.contains(selectedLimb),
              let id = clipping.limbs[selectedLimb]?.mask else { return nil }
        return clipping.mask(id)
    }

    /// WE's Assign Clipping Mask with a new mask: the mask is created, assigned and opened for painting.
    func assignNewClippingMask(named name: String) {
        guard let limb = selectedLimb else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var id: UInt64 = 0
        edit(PL("Assign Clipping Mask")) { id = $0.addClippingMask(named: trimmed.isEmpty ? PL("Clipping Mask") : trimmed, to: limb) }
        startPaintingClippingMask(id)
    }

    /// Assign Clipping Mask with a mask another limb has.
    func assignClippingMask(_ id: UInt64) {
        guard let limb = selectedLimb else { return }
        edit(PL("Assign Clipping Mask")) { $0.assignClippingMask(id, to: limb) }
    }

    func removeClippingMask() {
        guard let limb = selectedLimb else { return }
        edit(PL("Remove Clipping Mask")) { $0.removeClippingMask(from: limb) }
    }

    func setClippingAdditive(_ additive: Bool) {
        guard let limb = selectedLimb else { return }
        edit(PL("Change Clipping Mask")) { $0.setClippingAdditive(additive, limb: limb) }
    }

    func updateClippingMask(_ id: UInt64, _ change: @escaping (inout PuppetClipping.Mask) -> Void) {
        edit(PL("Change Clipping Mask")) { $0.updateClippingMask(id, change) }
    }

    /// Paints mask `id` over the image: what it has, else nothing painted.
    func startPaintingClippingMask(_ id: UInt64) {
        guard let mask = document?.clipping?.mask(id) else { return }
        let existing = mask.texture.isEmpty ? nil : assets?.texture?(mask.texture)
        clippingPainting = MaskPainting(layer: layerID, target: .clippingMask(id: id, name: mask.title),
                                        layerSize: SIMD2(Double(imageSize.x), Double(imageSize.y)), existing: existing, fill: 0)
    }

    /// Saves the painting and sets it on its mask, with the limbs it covers, in one undo step.
    func finishPaintingClippingMask() {
        defer { clippingPainting = nil }
        guard let painting = clippingPainting, case let .clippingMask(id, _) = painting.target, let document,
              let image = painting.image, let png = painting.pngData, let save = assets?.saveMask else { return }
        do {
            let path = try save(png)
            let limbs = PuppetClipping.paintedLimbs(document.mesh, islands: document.mesh.islands, painted: image)
            edit(PL("Paint Clipping Mask")) { document in
                document.updateClippingMask(id) { mask in
                    mask.texture = path
                    mask.maskingLimbs = limbs
                }
            }
        } catch {
            clippingProblem = PL("The clipping mask couldn’t be saved: \(error.localizedDescription)")
        }
    }

    func cancelPaintingClippingMask() { clippingPainting = nil }
}
