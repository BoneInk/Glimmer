import SwiftUI

/// WE's screen saver layout in the Displays sheet: the same as the wallpapers' (the default), or
/// its own, a loop per display, one stretched over the displays or one cloned onto each.
struct ScreenSaverLayoutPicker: View {
    @Binding var layout: ScreenSaverDisplayLayout

    var body: some View {
        HStack(spacing: 12) {
            Picker("Screen saver is:", selection: $layout.sameAsWallpaper) {
                Text("Same as wallpaper").tag(true)
                Text("Configured separately").tag(false)
            }
            .pickerStyle(.menu)
            .fixedSize()
            if !layout.sameAsWallpaper {
                Picker("Screen saver layout", selection: $layout.layout) {
                    Text("Screen saver per display").tag(DisplayLayoutMode.perDisplay)
                    Text("Stretch single screen saver").tag(DisplayLayoutMode.stretch)
                    Text("Clone single screen saver").tag(DisplayLayoutMode.clone)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
        }
    }
}
