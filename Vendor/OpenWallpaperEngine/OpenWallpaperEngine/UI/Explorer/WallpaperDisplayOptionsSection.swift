import SwiftUI
import OWEInspectorKit

/// The details panel's display options for the shown wallpaper on the selected displays (WE's
/// per-wallpaper alignment options and playback rate, `WallpaperDisplayOptions`): where the
/// picture sits beyond its placement, mirrored or not, and a video's speed. Each display keeps its
/// own; the selected displays are edited together, starting from the first one's.
struct WallpaperDisplayOptionsSection: View {
    @ObservedObject var wallpaperViewModel: WallpaperViewModel

    private var wallpaper: WEWallpaper { wallpaperViewModel.displayedWallpaper }

    private var screens: Set<String> {
        wallpaperViewModel.selectedScreenIds.isEmpty ? [wallpaperViewModel.selectedScreenId] : wallpaperViewModel.selectedScreenIds
    }

    private var options: WallpaperDisplayOptions {
        wallpaperViewModel.displayOptions.options(for: wallpaper, on: wallpaperViewModel.selectedScreenId)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<WallpaperDisplayOptions, Value>) -> Binding<Value> {
        Binding(get: { options[keyPath: keyPath] },
                set: { value in
                    var options = options
                    options[keyPath: keyPath] = value
                    wallpaperViewModel.setDisplayOptions(options, for: wallpaper, on: screens)
                })
    }

    private var isVideo: Bool {
        ["video", "remote-video"].contains(wallpaper.project.type.lowercased())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Position", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                InfoTip(String(localized: "Moves, zooms or mirrors the wallpaper on the selected displays, after its placement. Each display keeps its own.", comment: "Details panel tooltip"))
                Spacer()
                if options.transformsPicture {
                    Button("Reset") {
                        var reset = WallpaperDisplayOptions.identity
                        reset.playbackRate = options.playbackRate
                        wallpaperViewModel.setDisplayOptions(reset, for: wallpaper, on: screens)
                    }
                    .controlSize(.small)
                }
            }
            row("Horizontal") {
                NumericSliderInput(value: binding(\.offsetX), range: WallpaperDisplayOptions.offsetRange,
                                   defaultValue: 0, step: 0.01, displayScale: 100, suffix: "%",
                                   fractionDigits: 0, sliderWidth: 100, fieldWidth: 42)
            }
            row("Vertical") {
                NumericSliderInput(value: binding(\.offsetY), range: WallpaperDisplayOptions.offsetRange,
                                   defaultValue: 0, step: 0.01, displayScale: 100, suffix: "%",
                                   fractionDigits: 0, sliderWidth: 100, fieldWidth: 42)
            }
            row("Zoom") {
                NumericSliderInput(value: binding(\.zoom), range: WallpaperDisplayOptions.zoomRange,
                                   defaultValue: 1, step: 0.01, displayScale: 100, suffix: "%",
                                   fractionDigits: 0, sliderWidth: 100, fieldWidth: 42)
            }
            Toggle("Flip Horizontally", isOn: binding(\.flipHorizontal))
            Toggle("Flip Vertically", isOn: binding(\.flipVertical))
            if isVideo {
                row("Playback rate") {
                    NumericSliderInput(value: binding(\.playbackRate), range: WallpaperDisplayOptions.playbackRateRange,
                                       defaultValue: 1, step: 0.05, suffix: "x",
                                       fractionDigits: 2, sliderWidth: 100, fieldWidth: 42)
                }
                .help("This video's speed on the selected displays, times the app's Video Speed. A video shown on several displays plays at the main display's rate.")
            }
        }
    }

    private func row(_ title: LocalizedStringKey, @ViewBuilder control: () -> some View) -> some View {
        HStack {
            Text(title)
            Spacer()
            control()
        }
    }
}
