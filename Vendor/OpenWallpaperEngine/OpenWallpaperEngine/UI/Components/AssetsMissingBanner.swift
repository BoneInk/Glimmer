import SwiftUI

/// Says that scenes need the Wallpaper Engine assets and opens Settings › Assets to set them up.
/// Shown in the main window and the welcome sheet while no assets are installed.
struct AssetsMissingBanner: View {
    @ObservedObject var assets: WallpaperEngineAssetsService

    var body: some View {
        if assets.isMissing { AssetsMissingNotice() }
    }
}

/// The banner's line and its button.
///
/// The line wraps to at most two lines. Sized to its full height at any width
/// (`fixedSize(horizontal: false, vertical: true)`), it reported hundreds of points when the split
/// view measured the column narrow. In the library's top safe-area inset that height pushed the
/// grid and the buttons under it past the window's bottom edge.
struct AssetsMissingNotice: View {
    static let lineLimit = 2

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "shippingbox")
                .foregroundStyle(.orange)
            Text("Scenes need Wallpaper Engine assets from your Steam copy.")
                .lineLimit(Self.lineLimit)
            Spacer()
            Button("Set Up Assets…") { AppDelegate.shared.openAssetsSettings() }
                .glassButtonStyle(.prominent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

/// A scene on the desktop while no assets are installed: it can't draw, so it says why.
struct AssetsMissingWallpaperView: View {
    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 10) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 40))
                Text("This scene needs Wallpaper Engine assets from your Steam copy. Set them up in Settings › Assets.")
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            .foregroundStyle(.white.opacity(0.75))
        }
        .ignoresSafeArea()
    }
}
