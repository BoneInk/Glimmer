import Foundation

/// Where Display Settings' miniature of a display gets its picture (`DisplayWallpaperPicture`).
enum DisplayPictureSource: Equatable {
    /// The scene's own frame, rendered at this display's pixel size (`SceneLoadingSnapshotStore`).
    case snapshot(URL)
    /// The scene's own frame at another display size, aspect-filled.
    case otherSnapshot(URL)
    /// A frame of a video wallpaper (`DisplayPictureLoader.videoFrame`).
    case videoFrame(URL)
    /// A web wallpaper's preview.
    case webPreview(URL)
    /// The Workshop preview, usually square.
    case workshopPreview(URL)
    case none

    var url: URL? {
        switch self {
        case .snapshot(let url), .otherSnapshot(let url), .videoFrame(let url), .webPreview(let url),
             .workshopPreview(let url):
            return url
        case .none:
            return nil
        }
    }

    /// How the picture sits on the display: a snapshot is the screen as rendered, placement and
    /// all, so it fills; anything else is placed as the wallpaper is.
    func placement(_ wallpaperPlacement: WallpaperPlacement) -> WallpaperPlacement {
        switch self {
        case .snapshot, .otherSnapshot: return .fill
        case .videoFrame, .webPreview, .workshopPreview, .none: return wallpaperPlacement
        }
    }

    /// The best picture of a wallpaper of `type` on a display, in order: the snapshot at the
    /// display's size, a snapshot at any size, a video's frame (grabbed only when asked for), a web
    /// wallpaper's preview, then the Workshop preview.
    static func choose(type: String, exactSnapshot: URL?, otherSnapshot: URL?,
                       videoFrame: () async -> URL?, preview: URL?) async -> DisplayPictureSource {
        if let exactSnapshot { return .snapshot(exactSnapshot) }
        if let otherSnapshot { return .otherSnapshot(otherSnapshot) }
        let type = type.lowercased()
        if type == "video", let frame = await videoFrame() { return .videoFrame(frame) }
        guard let preview else { return .none }
        return type == "web" ? .webPreview(preview) : .workshopPreview(preview)
    }
}
