import SwiftUI

/// What a display's wallpaper window shows: its wallpaper, or, while it is split, each region's
/// own wallpaper in the region's rect (WE's splits). Each region is a display of its own: its
/// view renders at the region's size.
struct DisplayWallpaperView: View {
    @ObservedObject var viewModel: WallpaperViewModel
    let screenId: String

    var body: some View {
        // Stopped: no wallpaper view, so nothing holds an instance, page or player, even before
        // the app delegate closes the window (`AppDelegate+StopWallpapers`).
        if viewModel.isStopped {
            Color.clear
        } else if let regions = viewModel.layoutResolution.regions[screenId], let frame = viewModel.displayRect(of: screenId) {
            ZStack(alignment: .topLeading) {
                ForEach(regions) { region in
                    let rect = DisplayCanvas.rect(of: region.rect, in: frame)
                    WallpaperView(viewModel: viewModel, screenId: region.id)
                        .frame(width: rect.width, height: rect.height)
                        .clipped()
                        .position(x: rect.midX, y: rect.midY)
                }
            }
            .frame(width: frame.width, height: frame.height, alignment: .topLeading)
        } else {
            WallpaperView(viewModel: viewModel, screenId: screenId)
        }
    }
}

extension View {
    /// Sizes a wallpaper view to a stretch's `canvas` and offsets it so the display at `display`
    /// (both in global points) shows its rect of it; unchanged while the display isn't stretched.
    /// For views that can't share one frame between windows (pages, AVKit video layers): each
    /// draws the whole canvas, and the window clips it to the display.
    func stretched(on canvas: CGRect?, display: CGRect?) -> some View {
        modifier(StretchedOnCanvas(canvas: canvas, display: display))
    }
}

private struct StretchedOnCanvas: ViewModifier {
    let canvas: CGRect?
    let display: CGRect?

    func body(content: Content) -> some View {
        if let canvas, let display, canvas.width > 0, canvas.height > 0 {
            let rect = DisplayCanvas.rect(of: display, in: canvas)
            content
                .frame(width: canvas.width, height: canvas.height)
                .position(x: canvas.width / 2 - rect.minX, y: canvas.height / 2 - rect.minY)
                .frame(width: display.width, height: display.height, alignment: .topLeading)
                .clipped()
        } else {
            content
        }
    }
}
