import Foundation

/// The iPhone & iPad Export mode's remembered settings.
struct SystemExportDefaults: Equatable {
    var device: DeviceModel
    /// "Also Save to Photos Album".
    var savesToPhotos: Bool
    var photosAlbum: String
    /// Photos access as macOS reports it: `authorized`, `limited`, `denied`, `restricted` or
    /// `not_determined`. Reading it never asks the user.
    var photosAccess: String
}

/// One Android export of one or more wallpapers, as Scene Edit / Export's Android Export would set it.
struct SystemAndroidRequest: Equatable {
    var wallpapers: [ControlWallpaper]
    var options: AndroidExportOptions
    /// An existing folder for the packages; nil uses the export's cache folder.
    var outputFolder: URL?
}

/// "Send over Wi-Fi" for an MCP client: a new export of `export`'s wallpapers, or packages an
/// export already wrote (`.mpkg` files).
struct SystemAndroidSendRequest: Equatable {
    var export: SystemAndroidRequest?
    var packages: [URL] = []
    /// One of the Mac's local-network IPv4 addresses; nil uses the primary interface's.
    var address: String?
}

/// A "Send over Wi-Fi" that is serving.
struct SystemAndroidSendResult: Equatable {
    var url: URL
    var expiry: Date
    var files: [AndroidWiFiFile]
    /// Every local-network address the Mac has; `url` uses one of them.
    var addresses: [String]
    /// The export it made first, if it made one.
    var batch: AndroidExportBatch?
}

/// One Live Photo export, as the mode's Export Settings would set it.
struct SystemLivePhotoRequest: Equatable {
    var wallpaper: ControlWallpaper
    var device: DeviceModel
    var zoom: Double
    /// The crop's centre in scene units; nil centres it.
    var center: SIMD2<Double>?
    /// Seconds into the scene; nil moves the clip to the window with the most motion, as the mode
    /// does when it opens.
    var clipStart: Double?
    var clipLength: Double
    var quality: LivePhotoQuality
    /// False skips the Photos album for this export; true follows the user's setting.
    var savesToPhotos: Bool
    /// An existing folder to copy the pair into; nil leaves it in the export's cache folder.
    var outputFolder: URL?
}

/// A finished export.
struct SystemLivePhotoResult: Equatable {
    /// What happened with "Also Save to Photos Album".
    enum Photos: Equatable {
        /// The setting is off.
        case off
        /// The request turned it off for this export.
        case skipped
        case saved(album: String)
        /// The export succeeded; Photos couldn't take it.
        case failed(album: String, reason: String)
        /// The setting is on but Photos access isn't granted (`photosAccess`), so nothing was asked.
        case needsAccess(album: String, access: String)
    }

    var photo: URL
    var movie: URL
    /// The files are in the export's cache folder, not a folder the request named.
    var isInCache: Bool
    var crop: LivePhotoCrop
    var clip: LivePhotoClip
    var clipIsAutomatic: Bool
    var photos: Photos
}

/// A scene layer, as Scene Edit / Export's list shows it.
struct SystemSceneLayer: Equatable {
    /// scene.json's object id (its index when it has none), which layer edits are keyed by.
    var id: Int
    var name: String
    /// `image`, `particle`, `text`, `sound`, `light`, `model` or `other`.
    var kind: String
    /// Whether scene.json shows it.
    var authoredVisible: Bool
}

/// The values a wallpaper's screen saver version is drawn with.
struct SystemScreenSaverValues: Equatable {
    /// User properties and Scene Edit / Export's layer edits.
    var values: [String: String]
    /// The screen saver has its own saved choices for the wallpaper (else these are the wallpaper's).
    var isOwn: Bool
}

/// The wallpaper set as the screen saver.
struct SystemScreenSaverSelection: Equatable {
    enum Kind: String, Equatable {
        /// Drawn live: a scene or a page with the screen saver's choices for it, a video as it is.
        case live
    }

    /// The wallpaper; nil when it is no longer in the library.
    var wallpaper: ControlWallpaper?
    var folder: String
    var kind: Kind
    /// When it was set as the screen saver.
    var picked: Date
}

struct SystemScreenSaverState: Equatable {
    /// Settings › Plugins › Screen Saver.
    var pluginEnabled: Bool
    var selection: SystemScreenSaverSelection?
}

/// A finished "Set as Screen Saver".
struct SystemScreenSaverSet: Equatable {
    var selection: SystemScreenSaverSelection
    /// The plugin was off, so setting it turned it on (which installs the saver).
    var enabledPlugin: Bool
}

/// Settings › General › "Show Wallpaper on Lock Screen".
struct SystemLockScreenState: Equatable {
    struct Display: Equatable {
        var id: String
        var name: String
        var wallpaper: ControlWallpaper?
        /// The desktop picture macOS shows on it (and on its lock screen).
        var picture: URL?
        /// The picture is OWE's lock-screen picture.
        var isLockScreenPicture: Bool
    }

    var enabled: Bool
    /// This copy may change the desktop picture (an isolated copy may not).
    var mayChangeDesktopPicture: Bool
    /// The wallpaper whose snapshot it shows: the one the app shows on its selected display.
    var follows: ControlWallpaper?
    var displays: [Display]
}
