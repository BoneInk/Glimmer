import CoreGraphics
import SwiftUI
import OWESceneEditing

/// Painting an effect's mask on the canvas, as WE's editor does: a brush over the layer, white
/// where the effect shows and black where it doesn't. The mask covers the layer's rectangle at a
/// resolution kept under `maximumSide`; it is saved as a PNG (`EditorAssetStore.saveMask`) and set
/// as the effect's texture in one undo step when painting ends. A Puppet Warp clipping mask is
/// painted the same way over the puppet's image (`PuppetWorkspace`).
@MainActor
final class MaskPainting: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case paint, erase
        var id: String { rawValue }
    }

    /// What the mask is for.
    enum Target {
        case effect(key: String, title: String, slot: EffectSchema.TextureSlot)
        /// A puppet's clipping mask, by its id.
        case clippingMask(id: UInt64, name: String)
    }

    let layer: Int
    let target: Target
    /// The effect's or the clipping mask's name.
    var title: String {
        switch target {
        case .effect(_, let title, _), .clippingMask(_, let title): title
        }
    }
    /// The mask's size in pixels.
    let pixelSize: SIMD2<Int>
    /// The layer's size in its own units, which the mask stretches over.
    let layerSize: SIMD2<Double>

    @Published var mode: Mode = .paint
    /// The brush's diameter, in layer units.
    @Published var brushSize: Double
    /// 0…1: how soft the brush's edge is.
    @Published var softness: Double = 0.5
    /// 0…1: how much one dab covers.
    @Published var strength: Double = 1
    /// Moves with every stroke, so the canvas draws the mask again.
    @Published private(set) var revision = 0
    @Published private(set) var canUndoStroke = false

    private let context: CGContext
    private var strokes: [CGImage] = []
    private var lastPoint: SIMD2<Double>?

    static let maximumSide = 2048

    /// A mask's size in pixels for a layer of `layerSize` (its own units), kept under
    /// `maximumSide`; nil for an empty layer. A depth map made into a mask is this size too.
    static func pixelSize(for layerSize: SIMD2<Double>) -> SIMD2<Int>? {
        guard layerSize.x > 0, layerSize.y > 0 else { return nil }
        let scale: Double = min(1, Double(maximumSide) / max(layerSize.x, layerSize.y))
        return SIMD2(max(Int((layerSize.x * scale).rounded()), 1), max(Int((layerSize.y * scale).rounded()), 1))
    }

    /// `existing`: the mask the effect has, painted over; else a fill of the slot's default.
    convenience init?(layer: Int, effectKey: String, effectTitle: String, slot: EffectSchema.TextureSlot, layerSize: SIMD2<Double>,
                      existing: CGImage?) {
        // WE's `paintdefaultcolor` ("0 0 0 1": the effect off until painted); white without one.
        self.init(layer: layer, target: .effect(key: effectKey, title: effectTitle, slot: slot), layerSize: layerSize,
                  existing: existing, fill: slot.paintDefault.map(Self.gray(of:)) ?? 1)
    }

    /// `existing` painted over; else a fill of `fill` (0 black … 1 white).
    init?(layer: Int, target: Target, layerSize: SIMD2<Double>, existing: CGImage?, fill: Double) {
        guard let size = Self.pixelSize(for: layerSize) else { return nil }
        let longest: Double = max(layerSize.x, layerSize.y)
        let width = size.x, height = size.y
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return nil
        }
        self.layer = layer
        self.target = target
        self.layerSize = layerSize
        pixelSize = SIMD2(width, height)
        self.context = context
        brushSize = max(longest / 12, 4)
        context.interpolationQuality = .high
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        if let existing {
            context.draw(existing, in: rect)
        } else {
            context.setFillColor(gray: CGFloat(fill), alpha: 1)
            context.fill(rect)
        }
    }

    /// The mean of a `paintdefaultcolor`'s first three components.
    private static func gray(of color: [Double]) -> Double {
        let sum: Double = color.prefix(3).reduce(0, +)
        let count: Int = max(min(color.count, 3), 1)
        return sum / Double(count)
    }

    /// The mask as it is now.
    var image: CGImage? { context.makeImage() }

    var pngData: Data? { image.flatMap(EditorAssetStore.pngData) }

    // MARK: Painting

    /// Starts a stroke at `point` (layer units, origin at the layer's centre, y up).
    func begin(at point: SIMD2<Double>) {
        if let snapshot = context.makeImage() {
            strokes.append(snapshot)
            if strokes.count > 30 { strokes.removeFirst() }
            canUndoStroke = true
        }
        lastPoint = nil
        dab(to: point)
    }

    /// Continues the stroke to `point`, dabbing along the way so a quick drag leaves no gaps.
    func dab(to point: SIMD2<Double>) {
        let from = lastPoint ?? point
        let distance = ((point - from) * (point - from)).sum().squareRoot()
        let spacing = max(brushSize * 0.15, 0.5)
        let steps = max(Int(distance / spacing), 1)
        for step in 1...steps {
            let t = Double(step) / Double(steps)
            stamp(at: from + (point - from) * t)
        }
        lastPoint = point
        revision += 1
    }

    func end() { lastPoint = nil }

    func undoStroke() {
        guard let last = strokes.popLast() else { return }
        context.draw(last, in: CGRect(x: 0, y: 0, width: pixelSize.x, height: pixelSize.y))
        canUndoStroke = !strokes.isEmpty
        revision += 1
    }

    /// Fills the whole mask: white shows the effect everywhere, black nowhere.
    func fill(white: Bool) {
        if let snapshot = context.makeImage() { strokes.append(snapshot); canUndoStroke = true }
        context.setFillColor(gray: white ? 1 : 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: pixelSize.x, height: pixelSize.y))
        revision += 1
    }

    /// The pixel `point` (layer units) falls on, in the context's space (origin bottom-left).
    func pixel(_ point: SIMD2<Double>) -> CGPoint {
        CGPoint(x: (point.x / layerSize.x + 0.5) * Double(pixelSize.x),
                y: (point.y / layerSize.y + 0.5) * Double(pixelSize.y))
    }

    private func stamp(at point: SIMD2<Double>) {
        let centre = pixel(point)
        let radius = brushSize / 2 * Double(pixelSize.x) / layerSize.x
        guard radius > 0.1 else { return }
        let gray: CGFloat = mode == .paint ? 1 : 0
        let alpha = CGFloat(max(min(strength, 1), 0.02))
        let inner = CGFloat(radius * (1 - max(min(softness, 1), 0)))
        let colors = [CGColor(gray: gray, alpha: alpha), CGColor(gray: gray, alpha: 0)] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: colors, locations: [0, 1]) else { return }
        context.drawRadialGradient(gradient, startCenter: centre, startRadius: inner, endCenter: centre,
                                   endRadius: CGFloat(radius), options: [.drawsBeforeStartLocation])
    }
}
