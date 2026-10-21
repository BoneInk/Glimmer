import SwiftUI
import AVKit

enum WallpaperPlacement: String, CaseIterable, Identifiable {
    case fill = "Fill"
    case fit = "Fit"
    case center = "Center"
    case stretch = "Stretch"
    case zoom = "Zoom"

    var id: Self { self }

    /// The name shown in the placement picker.
    var label: LocalizedStringResource {
        switch self {
        case .fill: return LocalizedStringResource("Fill", comment: "Wallpaper placement: scale to cover the screen, cropping")
        case .fit: return LocalizedStringResource("Fit", comment: "Wallpaper placement: scale to fit inside the screen")
        case .center: return LocalizedStringResource("Center", comment: "Wallpaper placement: centred at its own size")
        case .stretch: return LocalizedStringResource("Stretch", comment: "Wallpaper placement: stretch to the screen's shape")
        case .zoom: return LocalizedStringResource("Zoom", comment: "Wallpaper placement: enlarge to fill the screen")
        }
    }
}
