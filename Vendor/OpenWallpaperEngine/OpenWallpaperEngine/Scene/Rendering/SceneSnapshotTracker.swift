import simd

/// Keeps the scene snapshot (`_rt_FullFrameBuffer`) cheap: one full-size copy target per frame,
/// into which only the part a scene-reading draw needs is copied, and only when the copy already
/// there no longer matches the scene.
///
/// A `BLENDMODE` material or a scene-input layer reads the scene under its own quad, so it needs
/// just that quad's bounding rect (padded for linear filtering). An effect that reads the scene may
/// sample anywhere, so it asks for all of it. Every draw into the scene afterwards shrinks the part
/// of the copy known to match (`valid`); the next request copies again only if it reaches outside.
///
/// Pixel rects are in the scene target (y down), in pixels.
struct SceneSnapshotTracker {
    struct Rect: Equatable {
        var x: Int
        var y: Int
        var width: Int
        var height: Int

        /// No pixels: a draw that covers none of the target needs nothing copied.
        static let empty = Rect(x: 0, y: 0, width: 0, height: 0)

        var maxX: Int { x + width }
        var maxY: Int { y + height }
        var area: Int { width * height }

        func contains(_ other: Rect) -> Bool {
            other.x >= x && other.y >= y && other.maxX <= maxX && other.maxY <= maxY
        }

        func intersection(_ other: Rect) -> Rect? {
            let left = max(x, other.x), top = max(y, other.y)
            let right = min(maxX, other.maxX), bottom = min(maxY, other.maxY)
            guard right > left, bottom > top else { return nil }
            return Rect(x: left, y: top, width: right - left, height: bottom - top)
        }
    }

    /// Texels around a quad's box: linear filtering reads one beyond the edge, rounding one more.
    static let padding = 2

    /// The target pixels `quad` covers (scene units, y up), padded and clamped to the target; nil
    /// when it covers none (off-screen, zero, NaN or infinite).
    static func pixelRect(of quad: SceneQuadGeometry, sceneSize: SIMD2<Float>, targetSize: SIMD2<Int>) -> Rect? {
        let targetWidth = Float(targetSize.x)
        let targetHeight = Float(targetSize.y)
        let scale: SIMD2<Float> = SIMD2<Float>(targetWidth, targetHeight) / simd_max(sceneSize, SIMD2<Float>(1, 1))
        let halfX: SIMD2<Float> = quad.axisX / 2
        let halfY: SIMD2<Float> = quad.axisY / 2
        let center: SIMD2<Float> = quad.center
        let sceneCorners: [SIMD2<Float>] = [center - halfX - halfY, center + halfX - halfY,
                                            center - halfX + halfY, center + halfX + halfY]
        let corners: [SIMD2<Float>] = sceneCorners.map { (corner: SIMD2<Float>) -> SIMD2<Float> in
            SIMD2<Float>(corner.x * scale.x, targetHeight - corner.y * scale.y)
        }
        var low: SIMD2<Float> = corners[0]
        var high: SIMD2<Float> = corners[0]
        for corner in corners.dropFirst() {
            low = simd_min(low, corner)
            high = simd_max(high, corner)
        }
        guard low.x.isFinite, low.y.isFinite, high.x.isFinite, high.y.isFinite else { return nil }
        let pad = Float(padding)
        let size = SIMD2<Float>(targetWidth, targetHeight)
        let zero = SIMD2<Float>(0, 0)
        // Clamped before converting: a far off-screen corner must not overflow `Int`.
        let lowRounded: SIMD2<Float> = (low - pad).rounded(FloatingPointRoundingRule.down)
        let highRounded: SIMD2<Float> = (high + pad).rounded(FloatingPointRoundingRule.up)
        let lowPixel: SIMD2<Float> = simd_clamp(lowRounded, zero, size)
        let highPixel: SIMD2<Float> = simd_clamp(highRounded, zero, size)
        let left: Int = Int(lowPixel.x)
        let top: Int = Int(lowPixel.y)
        let right: Int = Int(highPixel.x)
        let bottom: Int = Int(highPixel.y)
        guard right > left, bottom > top else { return nil }
        return Rect(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// Where this frame's copy equals the scene as drawn so far; nil when nowhere.
    private(set) var valid: Rect?
    /// Pixels copied since creation, for tests and diagnostics.
    private(set) var pixelsCopied = 0

    /// A new frame, or a new copy target: nothing copied yet.
    mutating func reset() { valid = nil }

    /// The scene was drawn into within `rect`, or anywhere when nil. Keeps the largest part of
    /// `valid` that the draw didn't touch.
    mutating func sceneDrawn(in rect: Rect?) {
        guard let current = valid else { return }
        guard let rect else { valid = nil; return }
        guard current.intersection(rect) != nil else { return }
        let bands = [
            Rect(x: current.x, y: current.y, width: current.width, height: rect.y - current.y),
            Rect(x: current.x, y: rect.maxY, width: current.width, height: current.maxY - rect.maxY),
            Rect(x: current.x, y: current.y, width: rect.x - current.x, height: current.height),
            Rect(x: rect.maxX, y: current.y, width: current.maxX - rect.maxX, height: current.height),
        ].filter { $0.width > 0 && $0.height > 0 }
        valid = bands.max { $0.area < $1.area }
    }

    /// A draw needs the scene within `rect`. Returns the rect to copy now, or nil when the copy
    /// already holds it.
    mutating func copy(for rect: Rect) -> Rect? {
        guard rect.area > 0 else { return nil }
        if let valid, valid.contains(rect) { return nil }
        valid = rect
        pixelsCopied += rect.area
        return rect
    }
}
