import AppKit

/// Whether the "Ultra (Display HDR)" post-processing setting is offered. WE's settings list it only
/// when a display can show HDR (`runtime.displayhdrsupport`), and turn a saved "displayhdr" into
/// "ultra" when none can. Here a display can when it has extended dynamic range headroom.
///
/// With it, a scene drawn in HDR reaches the display as EDR (`SceneDisplayOutput`); on a display
/// without headroom it draws as "ultra", as WE does without an HDR monitor.
enum DisplayHDRSupport {
    /// A display's potential EDR headroom above SDR white.
    static func isAvailable(headrooms: [CGFloat] = NSScreen.screens.map(\.maximumPotentialExtendedDynamicRangeColorComponentValue)) -> Bool {
        headrooms.contains { $0 > 1 }
    }

    /// The setting as WE's settings keep it: "displayhdr" becomes "ultra" where no display can show HDR.
    static func coerced(_ quality: GSPostProcessingQuality, available: Bool) -> GSPostProcessingQuality {
        !available && quality == .displayhdr ? .ultra : quality
    }
}
