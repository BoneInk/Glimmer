import Foundation

/// A wallpaper's library thumbnail as WE's editor makes it (its snapshot tool, `takeSnapshot` in
/// `wallpaperui.exe`): a square still saved as `preview.jpg` or an animated `preview.gif`, the file
/// project.json's `preview` names.
public struct WallpaperThumbnail: Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// `preview.jpg`, from Take Snapshot.
        case image
        /// `preview.gif`, from Record GIF.
        case gif
    }

    public var kind: Kind
    /// The encoded file.
    public var data: Data
    /// Its square side in pixels.
    public var side: Int

    public init(kind: Kind, data: Data, side: Int) {
        self.kind = kind
        self.data = data
        self.side = side
    }

    /// The file WE writes into the project and names in project.json's `preview`.
    public var fileName: String {
        switch kind {
        case .image: return "preview.jpg"
        case .gif: return "preview.gif"
        }
    }

    /// The previews WE's snapshot tool writes; the other one goes when a new preview replaces it.
    public static let fileNames = ["preview.jpg", "preview.gif"]

    /// Steam's limit for a Workshop preview (1 MB, docs.wallpaperengine.io "Publishing"); WE's
    /// GIF encoder shrinks a GIF until it fits ("Shrinking GIF for compatibility with Steam").
    public static let steamSizeLimit = 1_048_576

    /// The side of a snapshot: WE captures the square the user draws over the preview at screen
    /// pixels, so its previews are as large as the scene's short side on screen; 1024, the size most
    /// of its previews have, keeps a still under Steam's limit. Never larger than the scene.
    public static let snapshotSide = 1024

    /// The snapshot's side for a scene of `sceneSize` (its short side, at most `snapshotSide`).
    public static func snapshotSide(sceneSize: SIMD2<Double>) -> Int {
        let short = Int(min(sceneSize.x, sceneSize.y).rounded(.down))
        return max(1, min(snapshotSide, short))
    }

    /// The pixel size the scene is drawn at for a square of `side`: the scene's own aspect with its
    /// short side `side`, so the square is its centre (`ThumbnailEncoder.centreSquare`).
    public static func renderSize(side: Int, sceneSize: SIMD2<Double>) -> SIMD2<Int> {
        let width = max(sceneSize.x, 1), height = max(sceneSize.y, 1)
        let scale = Double(side) / min(width, height)
        return SIMD2(max(side, Int((width * scale).rounded())), max(side, Int((height * scale).rounded())))
    }
}

/// One of WE's GIF recording formats (the snapshot tool's F key cycles them; its table in
/// `wallpaperui.exe` is `{256, 25, 2, 1}, {256, 12, 4, 1}, {128, 25, 8, 1}` and the same three
/// without dithering), shown as "1. 256×256, 25 FPS, 2 seconds, dithering enabled".
public struct GIFRecordingFormat: Hashable, Identifiable, Sendable {
    public var side: Int
    public var framesPerSecond: Int
    public var seconds: Int
    public var dithered: Bool

    public var id: String { "\(side)-\(framesPerSecond)-\(seconds)-\(dithered)" }

    public init(side: Int, framesPerSecond: Int, seconds: Int, dithered: Bool) {
        self.side = side
        self.framesPerSecond = framesPerSecond
        self.seconds = seconds
        self.dithered = dithered
    }

    /// WE's formats in its order; the first is its default.
    public static let all: [GIFRecordingFormat] = [true, false].flatMap { dithered in
        [GIFRecordingFormat(side: 256, framesPerSecond: 25, seconds: 2, dithered: dithered),
         GIFRecordingFormat(side: 256, framesPerSecond: 12, seconds: 4, dithered: dithered),
         GIFRecordingFormat(side: 128, framesPerSecond: 25, seconds: 8, dithered: dithered)]
    }

    public var frameCount: Int { framesPerSecond * seconds }

    /// A frame's delay in the GIF's hundredths of a second, as WE writes it (4 at 25 FPS, 8 at 12).
    public var delayCentiseconds: Int { max(2, 100 / framesPerSecond) }
}
