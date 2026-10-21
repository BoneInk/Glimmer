import Cocoa
import SwiftUI
import OWEInspectorKit
import OWETheming

final class WorkshopPreviewWindow: NSWindow {
    var onDismiss: (() -> Void)?

    override func performClose(_ sender: Any?) {
        orderOut(sender)
        onDismiss?()
    }

    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }

    override func resignKey() {
        super.resignKey()
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isKeyWindow else { return }
            self.orderOut(nil)
            self.onDismiss?()
        }
    }
}

struct WorkshopPreviewContent: View {
    @ObservedObject var wallpaperViewModel: WallpaperViewModel

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            WallpaperView(
                viewModel: wallpaperViewModel,
                screenId: wallpaperViewModel.selectedScreenId
            )
            .id(wallpaperViewModel.currentWallpaper.wallpaperDirectory)

            // One small glass group over the live wallpaper.
            GlassGroup(spacing: 10) {
                HStack(spacing: 10) {
                    if SceneContentLoader.isVideoType(wallpaperViewModel.currentWallpaper.project.type) {
                        let isPaused = wallpaperViewModel.playRate == 0
                        HStack(spacing: 8) {
                            Button {
                                wallpaperViewModel.playRate = isPaused ? max(wallpaperViewModel.lastPlayRate, 0.1) : 0
                            } label: {
                                Label(isPaused ? "Play" : "Pause", systemImage: isPaused ? "play.fill" : "pause.fill")
                                    .labelStyle(.iconOnly)
                            }
                            .borderlessOnGlassButtonStyle()
                            .help(isPaused ? "Play" : "Pause")

                            NumericSliderInput(value: $wallpaperViewModel.playVolume, range: 0...1,
                                               defaultValue: 1, displayScale: 100, suffix: "%",
                                               fractionDigits: 0, sliderWidth: 110, fieldWidth: 36)
                        }
                        .glassBackground(in: Capsule(),
                                         padding: EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)) { controls in
                            // Before glass: a frosted capsule keeps the controls legible over the video.
                            controls
                                .padding(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                                .background(.regularMaterial, in: Capsule())
                        }
                    }

                    Button("Set Wallpaper") {
                        AppDelegate.shared.applyWorkshopPreview()
                    }
                    .glassButtonStyle(.prominent)
                }
            }
            .padding()
        }
    }
}
