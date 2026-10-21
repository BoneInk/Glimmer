import Foundation

/// The choices of WE's "Exporting … for usage on Android" dialog (`ui_browse_mobile_upload_modal_*`)
/// and what each does to the package (`AndroidPackageBuilder`).
///
/// - **Dynamic** sends the scene itself, rendered on the device. Its advanced settings are Pixel
///   art optimization and Texture Reduction (Original, ×2, ×4), written to scene.json's
///   `general.texturereduction` (WE's samples: 1 for High Quality, 2 for Balanced).
/// - **Pre-Rendered** (High Performance) sends a 30 s video of the scene instead, with Video
///   Cropping, Video Preset, FPS and the crop's horizontal alignment.
///
/// The quality buttons preset Pixel art and Texture Reduction from WE's table
/// (`browseMobileUploadModalCtrl`'s `high`/`medium`/`low` × `pixel`/`normal`/`uhd`), whose column is
/// the selection's `ResolutionClass`.
struct AndroidExportOptions: Equatable, Codable {
    enum Mode: String, Codable, CaseIterable, Equatable {
        /// Dynamic, High Quality.
        case highQuality = "high_quality"
        /// Dynamic, Balanced.
        case balanced
        /// Pre-Rendered, High Performance.
        case preRendered = "pre_rendered"

        var isDynamic: Bool { self != .preRendered }

        /// WE's preset for this button and `resolution`: `compression` "high_quality" (pixel art)
        /// and `reduction`.
        func preset(for resolution: ResolutionClass) -> (pixelArt: Bool, reduction: TextureReduction) {
            switch (self, resolution) {
            case (.highQuality, .pixel): return (true, .original)
            case (.highQuality, .normal): return (false, .original)
            case (.highQuality, .uhd): return (false, .half)
            case (.balanced, .pixel): return (false, .original)
            case (.balanced, .normal): return (false, .half)
            case (.balanced, .uhd): return (false, .quarter)
            case (.preRendered, .pixel): return (false, .half)
            case (.preRendered, .normal), (.preRendered, .uhd): return (false, .quarter)
            }
        }

        /// The texture reduction the quality preset chooses for a normal selection.
        var textureReduction: TextureReduction { preset(for: .normal).reduction }
    }

    /// The column of WE's preset table (the dialog's `o()`): `uhd` when a wallpaper's resolution
    /// tag ("3840 x 2160", "Ultrawide 3440 x 1440"…) has more pixels than 1920×1080 (its
    /// `show4kHint`), else `pixel` when every wallpaper is smaller than 640×480 (its
    /// `allPixelArt`: the smallest scene under it, and the largest scene or tag too), else `normal`.
    enum ResolutionClass: String, Codable, Equatable {
        case pixel, normal, uhd

        /// WE's thresholds: 2,075,520 pixels (1920×1081) and 307,200 (640×480).
        static let uhdPixels = 2_075_520
        static let pixelArtPixels = 307_200

        static func of(tags: [String], sceneSizes: [SIMD2<Double>]) -> ResolutionClass {
            let tagged = tags.compactMap(resolution(tag:))
            if tagged.contains(where: { $0 > uhdPixels }) { return .uhd }
            let sizes = sceneSizes.map { Int($0.x * $0.y) }.filter { $0 > 0 }
            guard let smallest = sizes.min(), smallest < pixelArtPixels else { return .normal }
            return (sizes + tagged).max() ?? 0 < pixelArtPixels ? .pixel : .normal
        }

        /// A WE resolution tag's pixels: "W x H", maybe after "Ultrawide ", "Dual ", "Triple " or
        /// "Portrait "; nil for any other tag.
        static func resolution(tag: String) -> Int? {
            let parts = tag.replacingOccurrences(of: #"(?i)(Ultrawide |Dual |Triple |Portrait )"#, with: "", options: .regularExpression)
                .components(separatedBy: " x ")
            guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]) else { return nil }
            return width * height
        }
    }

    /// WE's Texture Reduction: the divisor of a colour texture's sides, written to scene.json's
    /// `general.texturereduction`. WE's Pre-Rendered package's scene.json says 4.
    enum TextureReduction: Int, Codable, CaseIterable, Equatable {
        case original = 1
        case half = 2
        case quarter = 4
    }

    enum Cropping: String, Codable, CaseIterable, Equatable {
        /// "Fit to phone screen": the portrait window the scene covers.
        case phone
        /// "Keep original aspect ratio": the whole scene.
        case original
    }

    /// WE's Video Preset: the video's size. "Automatic" (the paired device's screen) needs a
    /// connected device, which an export has none of.
    enum VideoPreset: String, Codable, CaseIterable, Equatable {
        case original
        case fullHD = "full_hd"
        case uhd4K = "uhd_4k"

        /// The short side in pixels; nil keeps the scene's own size.
        var shortSide: Int? {
            switch self {
            case .original: return nil
            case .fullHD: return 1080
            case .uhd4K: return 2160
            }
        }
    }

    static let frameRates = [24, 30, 60]
    static let defaultFrameRate = 30
    /// WE's pre-rendered video is a 30.0 s loop.
    static let videoSeconds = 30
    /// WE's sample: about 8.1 Mbit/s for 1080×1920 at 30 fps.
    static let referenceBitRate = 8_000_000
    /// The phone screen WE fits a video to: 9:16 portrait.
    static let phoneAspect = SIMD2(9, 16)

    var mode: Mode = .balanced
    var pixelArt = false
    var textureReduction: TextureReduction = .half
    var cropping: Cropping = .phone
    var videoPreset: VideoPreset = .fullHD
    var frameRate = AndroidExportOptions.defaultFrameRate
    /// The crop's horizontal position, 0 (left) to 1 (right); 0.5 centres it.
    var alignment = 0.5

    init() {}

    /// `mode` with its preset, as clicking WE's quality button does.
    init(mode: Mode, resolution: ResolutionClass = .normal) {
        choose(mode, resolution: resolution)
    }

    /// Chooses `mode` and its preset's pixel art and texture reduction for `resolution`.
    mutating func choose(_ mode: Mode, resolution: ResolutionClass = .normal) {
        self.mode = mode
        let preset = mode.preset(for: resolution)
        pixelArt = preset.pixelArt
        textureReduction = preset.reduction
    }

    /// What `general.texturereduction` says in the package's scene.json (WE's Pre-Rendered
    /// sample: 4, its preset's).
    var sceneTextureReduction: Int { effectiveTextureReduction.rawValue }

    /// The reduction textures get: pixel art keeps every pixel (WE's editor calls the same
    /// option "Disable Bilinear Filtering"), so it isn't reduced.
    var effectiveTextureReduction: TextureReduction { pixelArt ? .original : textureReduction }

    /// The video's pixel size for a scene of `sceneSize`: the portrait 9:16 window (or the whole
    /// scene) scaled so its short side is the preset's, even.
    func videoPixelSize(sceneSize: SIMD2<Double>) -> SIMD2<Int> {
        let window: SIMD2<Double>
        switch cropping {
        case .phone:
            let aspect = Double(Self.phoneAspect.x) / Double(Self.phoneAspect.y)
            window = sceneSize.x / sceneSize.y > aspect ? SIMD2(sceneSize.y * aspect, sceneSize.y) : SIMD2(sceneSize.x, sceneSize.x / aspect)
        case .original:
            window = sceneSize
        }
        let shortSide = videoPreset.shortSide.map(Double.init) ?? min(window.x, window.y)
        let scale = shortSide / max(min(window.x, window.y), 1)
        func even(_ value: Double) -> Int { max(2, Int((value * scale / 2).rounded()) * 2) }
        return SIMD2(even(window.x), even(window.y))
    }

    /// The video's average bit rate: WE's ~8 Mbit/s at 1080×1920, 30 fps, in proportion to the
    /// pixels per second.
    func videoBitRate(pixelSize: SIMD2<Int>) -> Int {
        let reference = 1080.0 * 1920 * 30
        let rate = Double(pixelSize.x * pixelSize.y * frameRate)
        return max(500_000, Int(Double(Self.referenceBitRate) * rate / reference))
    }

    /// The portrait crop (`LivePhotoCrop`) of a scene of `sceneSize` at `alignment`.
    func crop(sceneSize: SIMD2<Double>) -> LivePhotoCrop {
        let pixels = videoPixelSize(sceneSize: sceneSize)
        var crop = LivePhotoCrop(sceneSize: sceneSize, outputPixels: pixels)
        let half = crop.cropSize.x / 2
        let x = half + (sceneSize.x - 2 * half) * min(max(alignment, 0), 1)
        crop.setCenter(SIMD2(x, sceneSize.y / 2))
        return crop
    }
}
