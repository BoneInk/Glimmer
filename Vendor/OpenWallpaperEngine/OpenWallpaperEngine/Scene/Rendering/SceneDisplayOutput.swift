import AppKit
import MetalKit
import QuartzCore

/// A display's extended dynamic range headroom: the largest colour component value it shows,
/// where 1 is SDR white. `potential` is what it can reach once content asks for EDR, `current`
/// what it shows now (it follows the brightness and ambient light).
struct SceneDisplayHeadroom: Equatable {
    var potential: Float = 1
    var current: Float = 1

    init(potential: Float = 1, current: Float = 1) {
        self.potential = potential
        self.current = current
    }

    /// `screen`'s headroom; none without a screen.
    init(screen: NSScreen?) {
        guard let screen else {
            self.init()
            return
        }
        self.init(potential: Float(screen.maximumPotentialExtendedDynamicRangeColorComponentValue),
                  current: Float(screen.maximumExtendedDynamicRangeColorComponentValue))
    }

    /// The display can show HDR (WE: the output's colour space is HDR10, 0x14012af44).
    var isHDR: Bool { potential > 1 }
}

/// How frames reach the display: WE's "displayhdr" output (docs/lighting-plan.md §2.6 "Display
/// HDR"), or the standard one.
///
/// WE decides display HDR at load, with HDR itself: `bloom` and `hdr` on and the post-processing
/// setting "displayhdr" (flag 0x4000, 0x14010e6da). The device then makes an
/// R16G16B16A16_FLOAT swap chain (0x14012b656) and sets no colour space on it, so DXGI shows it
/// as scRGB: linear, BT.709 primaries, 1.0 = 80 nits. It keeps display HDR only while the
/// monitor is in HDR mode (the output's colour space is HDR10, 0x14012af44); otherwise the flag is
/// dropped (0x1401109be) and the scene draws as "ultra". The frame is combined by
/// `combine_dhdr_upsample` (`DISPLAYHDR` 1), which leaves the scene at SDR white and lets the
/// bloom rise above it: out = lin(max(0, saturate(scene) + bloom)) · (RV.x + RV.y ·
/// smoothstep(1, 5, luma)), with RV = (SDR white, max luminance − SDR white) / 80 nits
/// (0x14012b5d9). There is no tone map and no paper-white scale beyond RV.x.
///
/// macOS's EDR is the same model with SDR white as the unit: an `rgba16Float` `CAMetalLayer` in
/// extended linear sRGB (BT.709 primaries, linear, 1.0 = SDR white) with
/// `wantsExtendedDynamicRangeContent`, and the screen's headroom as max luminance / SDR white. WE's
/// RV divided by its SDR white is therefore (1, headroom − 1). A display without headroom keeps
/// the standard output, and the content draws as "ultra", as WE does.
enum SceneDisplayOutput: Equatable {
    /// The drawable's own format, as every quality other than display HDR draws.
    case standard
    /// EDR: linear values in extended linear sRGB, 1.0 = SDR white, up to `headroom`.
    case extendedRange(headroom: Float)

    /// The EDR drawable's format and colour space.
    static let extendedPixelFormat = MTLPixelFormat.rgba16Float
    static let extendedColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)

    /// The output for a content that draws in HDR (`drawsHDR`, WE's flag 0x2000) or not, under the
    /// user's post-processing setting, on a display with `headroom`.
    static func select(postProcessing: GSPostProcessingQuality, drawsHDR: Bool,
                       headroom: SceneDisplayHeadroom) -> SceneDisplayOutput {
        guard postProcessing == .displayhdr, drawsHDR, headroom.isHDR else { return .standard }
        return .extendedRange(headroom: max(headroom.current, 1))
    }

    var isExtended: Bool { self != .standard }

    /// The drawable's format: `standard` (the renderer's) or the EDR one.
    func pixelFormat(standard: MTLPixelFormat) -> MTLPixelFormat {
        isExtended ? Self.extendedPixelFormat : standard
    }

    /// `g_RenderVar0.xy` of the display HDR combine: (1, headroom − 1); nil for the standard
    /// output, whose combine is "ultra"'s.
    var renderVar: SIMD2<Float>? {
        guard case .extendedRange(let headroom) = self else { return nil }
        return SIMD2(1, max(headroom - 1, 0))
    }

    /// The colour space `MTKView` gives its layer, which the standard output restores after EDR.
    static let standardColorSpace = CGColorSpace(name: CGColorSpace.sRGB)

    /// Sets `view` up for this output: its drawable format and, on its layer, the EDR colour space
    /// and flag. The standard output restores the layer only where EDR had changed it, so a view
    /// that never showed EDR is left exactly as it was. On the view's thread (the main one).
    func apply(to view: MTKView, standard: MTLPixelFormat) {
        // A view drawn on a render thread: only its layer is set up there (Core Animation allows
        // any thread); the view's own format follows on the main thread.
        if let snapshot = SceneViewSnapshots.snapshot(of: view) {
            guard let layer = snapshot.layer else { return }
            let format = pixelFormat(standard: standard)
            if layer.pixelFormat != format {
                layer.pixelFormat = format
                DispatchQueue.main.async { if view.colorPixelFormat != format { view.colorPixelFormat = format } }
            }
            apply(to: layer)
            return
        }
        let format = pixelFormat(standard: standard)
        if view.colorPixelFormat != format { view.colorPixelFormat = format }
        guard let layer = view.layer as? CAMetalLayer else { return }
        apply(to: layer)
    }

    private func apply(to layer: CAMetalLayer) {
        if isExtended {
            if !layer.wantsExtendedDynamicRangeContent { layer.wantsExtendedDynamicRangeContent = true }
            if layer.colorspace?.name != Self.extendedColorSpace?.name { layer.colorspace = Self.extendedColorSpace }
        } else if layer.wantsExtendedDynamicRangeContent {
            layer.wantsExtendedDynamicRangeContent = false
            layer.colorspace = Self.standardColorSpace
        }
    }
}
