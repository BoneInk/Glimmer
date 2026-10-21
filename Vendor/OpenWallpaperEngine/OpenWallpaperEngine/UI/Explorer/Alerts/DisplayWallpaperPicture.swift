import SwiftUI

/// A miniature of a display showing its wallpaper, for Display Settings: a rounded rectangle with
/// the display's aspect, holding the best picture of the wallpaper there (`DisplayPictureSource`),
/// placed as the wallpaper is placed on the display. It loads off the main thread at its drawn
/// size (`DisplayPictureLoader`) and loads again when a running scene saves a new snapshot.
struct DisplayWallpaperPicture: View {
    let wallpaper: WEWallpaper
    let displayName: String
    /// The display's size in points, and its pixels per point.
    let displaySize: CGSize
    let displayScale: CGFloat
    let placement: WallpaperPlacement
    var box = CGSize(width: 160, height: 72)

    @Environment(\.displayScale) private var scale
    @State private var picture: DisplayPictureLoader.Picture?
    @State private var snapshotGeneration = 0

    private var frame: CGSize { DisplayPictureGeometry.frameSize(display: displaySize, fitting: box) }

    private var request: DisplayPictureLoader.Request {
        DisplayPictureLoader.Request(
            wallpaperDirectory: wallpaper.wallpaperDirectory,
            type: wallpaper.project.type,
            mediaURL: wallpaper.mediaURL,
            preview: wallpaper.project == .invalid ? nil : wallpaper.previewURL,
            displayPixelSize: SIMD2(Int(displaySize.width * displayScale), Int(displaySize.height * displayScale)),
            frame: frame, scale: scale, placement: placement)
    }

    private struct LoadKey: Hashable {
        var request: DisplayPictureLoader.Request
        var snapshotGeneration: Int
    }

    var body: some View {
        let frame = frame
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        ZStack {
            Color.black
            if let picture {
                let image = CGSize(width: picture.image.width, height: picture.image.height)
                let rect = DisplayPictureGeometry.imageRect(image: image, in: frame, placement: picture.placement)
                Image(decorative: picture.image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: frame.width, height: frame.height)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(wallpaperTitle) on \(displayName)",
                                 comment: "Accessibility label of a display's wallpaper picture in Display Settings: wallpaper title on display name"))
        .accessibilityAddTraits(.isImage)
        .task(id: LoadKey(request: request, snapshotGeneration: snapshotGeneration)) {
            let request = request
            let loaded = await Task.detached(priority: .utility) {
                await DisplayPictureLoader.current.load(request)
            }.value
            guard !Task.isCancelled else { return }
            picture = loaded
        }
        .onReceive(NotificationCenter.default.publisher(for: .sceneLoadingSnapshotSaved)) { notification in
            guard let saved = notification.object as? URL,
                  saved.standardizedFileURL == wallpaper.wallpaperDirectory.standardizedFileURL else { return }
            snapshotGeneration += 1
        }
    }

    private var wallpaperTitle: String {
        wallpaper.project.title.isEmpty ? String(localized: "No wallpaper") : wallpaper.project.title
    }
}
