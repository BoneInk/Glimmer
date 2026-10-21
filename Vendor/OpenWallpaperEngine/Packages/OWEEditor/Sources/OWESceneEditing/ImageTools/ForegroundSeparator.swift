import Foundation

/// WE's Foreground Separation on a picture (`performGrabCut` and `finishCharacterSeparation` in
/// `wallpaperui.exe`): the mask from the author's marks, refined by GrabCut at the Quality level's
/// size, adjusted by Fine-tuning (Smoothing, Mask tolerance, Fill gaps), and the two pictures WE
/// makes from it, the foreground (the picture with the mask as its alpha) and the background (the
/// picture with the foreground's area filled from around it).
///
/// The automatic guess WE's GrabCut starts from (nothing but the strokes) is, here, the picture's
/// foreground as macOS's Vision finds it (`prior`), so an unmarked picture is already separated.
public enum ForegroundSeparator {
    /// Fine-tuning, WE's `dcConfig`: ranges and defaults.
    public struct Settings: Hashable, Codable, Sendable {
        /// Mask tolerance, −20…20 (WE's `maskBias`): pixels the mask grows (shrinks when negative),
        /// at the Quality level's size.
        public var maskTolerance = -1
        /// Quality level, 0…2: GrabCut at 512 pixels on the long side, 1024, or full size.
        public var quality = 1
        /// Smoothing, 0…5.
        public var smoothing = 1
        /// Fill gaps, 0…100 (100 is off): how far, at the Quality level's size, the background's
        /// fill reaches from the opaque picture left into the cut-out area (256 pixels at 100 %).
        public var fillGaps = 100
        /// Recalculate after every stroke (WE's Auto Recalculate).
        public var autoRecalculate = true

        public init() {}

        /// Character Sheet Creation's: Fill gaps at 15 (WE's sheet `dcConfig`).
        public static var sheet: Settings {
            var settings = Settings()
            settings.fillGaps = 15
            return settings
        }

        public static let maskToleranceRange = -20...20
        public static let qualityRange = 0...2
        public static let smoothingRange = 0...5
        public static let fillGapsRange = 0...100

        /// The Quality level's working scale for a picture of `width` × `height` (never above 1).
        public func scale(width: Int, height: Int) -> Double {
            let longSide = Double(max(width, height, 1))
            switch quality {
            case ...0: return min(1, 512 / longSide)
            case 1: return min(1, 1024 / longSide)
            default: return 1
            }
        }
    }

    /// A separation: the mask (0…1) and the two pictures.
    public struct Result: Sendable {
        public var mask: ImagePlane
        public var foreground: RGBAImage
        public var background: RGBAImage
    }

    /// The mask the marks give: the polygons' inside (no GrabCut, as WE's polygon tool), or the
    /// brush's marks refined by GrabCut from `prior`. Nil when nothing says what the foreground is.
    public static func mask(_ image: RGBAImage, marks: SeparationMarks, prior: ImagePlane?, settings: Settings) -> ImagePlane? {
        let width = image.width, height = image.height
        let scale = settings.scale(width: width, height: height)
        var mask: ImagePlane
        switch marks.mode {
        case .polygon:
            guard !marks.polygons.isEmpty else { return prior.map { $0.map { $0 > 0.5 ? 1 : 0 } } }
            mask = marks.polygonMask(smoothing: Double(settings.smoothing))
        case .brush:
            guard marks.hasMarks || prior != nil else { return nil }
            let workWidth = max(Int((Double(width) * scale).rounded()), 1), workHeight = max(Int((Double(height) * scale).rounded()), 1)
            var labels = scaledLabels(marks.grabCutLabels(prior: prior), width: width, height: height,
                                      to: workWidth, workHeight)
            let rgb = scaledRGB(image, to: workWidth, workHeight)
            GrabCut.segment(rgb: rgb, width: workWidth, height: workHeight, labels: &labels, iterations: 3)
            var small = ImagePlane(width: workWidth, height: workHeight, pixels: labels.map { $0.isForeground ? 1 : 0 })
            if settings.smoothing > 0 {
                small = small.gaussianBlurred(size: settings.smoothing * 4 + 1).map { $0 >= 0.5 ? 1 : 0 }
            }
            mask = small.resized(width: width, height: height).map { $0 >= 0.5 ? 1 : 0 }
        }
        if settings.maskTolerance != 0 {
            mask = grown(mask, by: Double(settings.maskTolerance) / scale)
        }
        // A soft edge of one pixel, as the scaled-up mask has.
        return mask.gaussianBlurred(size: 3)
    }

    /// The pictures a mask gives (WE's `fg.png` and `bg.png`).
    public static func separate(_ image: RGBAImage, mask: ImagePlane, settings: Settings) -> Result {
        let width = image.width, height = image.height
        var foreground = image
        for index in 0..<(width * height) {
            foreground.pixels[index * 4 + 3] = UInt8((Float(image.pixels[index * 4 + 3]) * mask.pixels[index]).rounded())
        }
        let background = filledBackground(image, mask: mask, settings: settings)
        return Result(mask: mask, foreground: foreground, background: background)
    }

    // MARK: Pieces

    /// A binary mask grown (shrunk, for a negative amount) by `amount` pixels.
    static func grown(_ mask: ImagePlane, by amount: Double) -> ImagePlane {
        if amount > 0 {
            let outside = DistanceTransform.distances(of: mask.map { 1 - $0 }, above: 0.5)
            return outside.map { $0 <= Float(amount) ? 1 : 0 }
        }
        let inside = DistanceTransform.distances(of: mask.padded(by: 1, mode: .zero), above: 0.5)
            .cropped(x: 1, y: 1, width: mask.width, height: mask.height)
        return inside.map { $0 > Float(-amount) ? 1 : 0 }
    }

    static func scaledLabels(_ labels: [GrabCut.Label], width: Int, height: Int, to newWidth: Int, _ newHeight: Int) -> [GrabCut.Label] {
        guard newWidth != width || newHeight != height else { return labels }
        var result = [GrabCut.Label](repeating: .probableBackground, count: newWidth * newHeight)
        // A sure mark anywhere in a working pixel's area wins (strokes stay strokes).
        for y in 0..<newHeight {
            let y0 = y * height / newHeight, y1 = max((y + 1) * height / newHeight, y0 + 1)
            for x in 0..<newWidth {
                let x0 = x * width / newWidth, x1 = max((x + 1) * width / newWidth, x0 + 1)
                var foreground = false, background = false, probable = 0, total = 0
                for sy in y0..<min(y1, height) {
                    for sx in x0..<min(x1, width) {
                        switch labels[sy * width + sx] {
                        case .foreground: foreground = true
                        case .background: background = true
                        case .probableForeground: probable += 1
                        case .probableBackground: break
                        }
                        total += 1
                    }
                }
                let index = y * newWidth + x
                if foreground && !background {
                    result[index] = .foreground
                } else if background && !foreground {
                    result[index] = .background
                } else {
                    result[index] = probable * 2 > total ? .probableForeground : .probableBackground
                }
            }
        }
        return result
    }

    static func scaledRGB(_ image: RGBAImage, to newWidth: Int, _ newHeight: Int) -> [UInt8] {
        let planes = (0..<3).map { image.plane($0).resized(width: newWidth, height: newHeight) }
        var rgb = [UInt8](repeating: 0, count: newWidth * newHeight * 3)
        for index in 0..<(newWidth * newHeight) {
            for channel in 0..<3 { rgb[index * 3 + channel] = UInt8(min(max(planes[channel].pixels[index].rounded(), 0), 255)) }
        }
        return rgb
    }

    /// The picture with the masked area filled from around it: Telea at a fifth of the Quality
    /// level's size, radius 5 % of that picture's long side (4…32 pixels), scaled back up, mixed
    /// in over the mask grown by a few pixels. With Fill gaps on, the cut-out area keeps the
    /// picture's opacity only within Fill gaps' reach of the opaque picture left.
    static func filledBackground(_ image: RGBAImage, mask: ImagePlane, settings: Settings) -> RGBAImage {
        let width = image.width, height = image.height
        let scale = settings.scale(width: width, height: height)
        let smallScale = 0.2 * scale
        let smallWidth = max(Int(Double(width) * smallScale), 1), smallHeight = max(Int(Double(height) * smallScale), 1)
        let radius = min(max(Int(0.05 * Double(max(smallWidth, smallHeight))), 4), 32)
        // The area to fill: the mask grown by the blur WE gives it (7 × 7, any coverage).
        let area = grown(mask.map { $0 > 0.01 ? 1 : 0 }, by: max(3 / scale, 1))
        let smallArea = area.resized(width: smallWidth, height: smallHeight)
        let unknown = smallArea.pixels.map { $0 > 0.01 }
        let planes = (0..<3).map { image.plane($0).resized(width: smallWidth, height: smallHeight) }
        let filled = unknown.contains(false) ? Inpainting.telea(planes, unknown: unknown, radius: radius) : planes
        let upscaled = filled.map { $0.resized(width: width, height: height) }
        let blend = area.gaussianBlurred(size: 3)
        var background = image
        for index in 0..<(width * height) {
            let m = blend.pixels[index]
            guard m > 0 else { continue }
            for channel in 0..<3 {
                let value = Float(image.pixels[index * 4 + channel]) * (1 - m) + upscaled[channel].pixels[index] * m
                background.pixels[index * 4 + channel] = UInt8(min(max(value.rounded(), 0), 255))
            }
        }
        guard settings.fillGaps < 100 else { return background }
        // Opacity of the cut-out area: the picture's, kept only near the opaque picture left.
        let remaining = ImagePlane(width: width, height: height, pixels: (0..<(width * height)).map { (index: Int) -> Float in
            Float(image.pixels[index * 4 + 3]) > 254 && area.pixels[index] < 0.5 ? 1 : 0
        })
        let reach = Float(Double(settings.fillGaps) / 100 * 256 / scale)
        let distance = DistanceTransform.distances(of: remaining.map { 1 - $0 }, above: 0.5)
        for index in 0..<(width * height) where area.pixels[index] >= 0.5 {
            if distance.pixels[index] > reach { background.pixels[index * 4 + 3] = 0 }
        }
        return background
    }
}
