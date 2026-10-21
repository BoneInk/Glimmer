import Foundation

/// Where the app and the savers meet: the shared folder (`sharedFolder`) holding the live frames'
/// manifest (`ScreenSaverLiveManifest`) and the stills (`ScreenSaverStills`), and a stretched
/// display's rect of a ring (`Crop`). Shared by both targets, so it uses Foundation only.
enum ScreenSaverManifest {
    /// A rect of a frame, as fractions of it from its top-left.
    struct Crop: Codable, Equatable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double

        init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        /// `unit`, a rect of a canvas of `canvas` size, in a frame of `video` size that fills
        /// the canvas (aspect kept, centred, as the desktop places it).
        init(_ unit: CGRect, canvas: CGSize, video: CGSize) {
            var fit = CGSize(width: 1, height: 1)
            if canvas.width > 0, canvas.height > 0, video.width > 0, video.height > 0 {
                let scale = max(canvas.width / video.width, canvas.height / video.height)
                fit = CGSize(width: canvas.width / scale / video.width, height: canvas.height / scale / video.height)
            }
            self.init(x: (1 - fit.width) / 2 + unit.minX * fit.width, y: (1 - fit.height) / 2 + unit.minY * fit.height,
                      width: unit.width * fit.width, height: unit.height * fit.height)
        }
    }

    /// The shared folder, given the user's home folder: OWE's own
    /// Application Support. The app can't write into the screen saver host's (`legacyScreenSaver`)
    /// container (macOS protects other apps' containers), but that host's sandbox may read any
    /// path (`files.absolute-path.read-only: /`), so the saver reads them where the app writes them.
    static func sharedFolder(home: URL) -> URL {
        home.appending(path: "Library/Application Support/Open Wallpaper Engine/ScreenSaver", directoryHint: .isDirectory)
    }

    /// The user's real home folder. Inside the saver's sandbox `homeDirectoryForCurrentUser` is the
    /// host's container, so the saver asks the user database.
    static var userHome: URL {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return URL(filePath: String(cString: dir), directoryHint: .isDirectory)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}

extension ScreenSaverManifest {
    /// A saver layer's `contentsRect` for `crop` of a frame (all of it when nil): unit
    /// coordinates with y up, as a layer's contents are on macOS, from the crop, whose y is down
    /// from the top as the app draws it. `contentsGravity` then fills the view with that rect.
    static func contentsRect(for crop: Crop?) -> CGRect {
        guard let crop, crop.width > 0, crop.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        return CGRect(x: crop.x, y: 1 - crop.y - crop.height, width: crop.width, height: crop.height)
    }
}
