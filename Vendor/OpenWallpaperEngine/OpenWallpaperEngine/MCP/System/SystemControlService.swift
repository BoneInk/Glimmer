import Foundation

/// What the control channel's system requests (`SystemControlRequests`) do in the app: Scene Edit / Export's
/// iPhone & iPad Export and Screen Saver modes and Settings › General's lock-screen picture, through the code those use
/// (`AppSystemControlService`), or a fake in tests. Every call is on the main actor.
@MainActor
protocol SystemControlService: AnyObject {
    // MARK: iPhone & iPad Export

    /// What the export mode remembers: the device, "Also Save to Photos Album" and its album.
    var exportDefaults: SystemExportDefaults { get }
    /// The scene's authored size, which the crop is measured in.
    func sceneSize(of wallpaper: ControlWallpaper) throws -> SIMD2<Double>
    /// Renders a Live Photo as the mode's Save does, and waits for it.
    func exportLivePhoto(_ request: SystemLivePhotoRequest) async throws -> SystemLivePhotoResult

    // MARK: Android export

    /// Exports the wallpapers as `.mpkg` packages as Scene Edit / Export's Android Export does,
    /// and waits for them.
    func exportAndroid(_ request: SystemAndroidRequest) async throws -> AndroidExportBatch

    /// Starts "Send over Wi-Fi" for the request's packages (exporting them first when it names
    /// wallpapers), replacing the one an MCP client started before.
    func sendAndroidOverWiFi(_ request: SystemAndroidSendRequest) async throws -> SystemAndroidSendResult

    // MARK: Screen saver

    var screenSaver: SystemScreenSaverState { get }
    /// The scene's layers as scene.json lists them.
    func layers(of wallpaper: ControlWallpaper) throws -> [SystemSceneLayer]
    /// The values the screen saver draws the wallpaper with: its own saved choices, or the
    /// wallpaper's values while it has none.
    func screenSaverValues(of wallpaper: ControlWallpaper) throws -> SystemScreenSaverValues
    /// Saves `values` as the screen saver's choices for the wallpaper, as the Screen Saver mode
    /// does; false when nothing was saved because they are the wallpaper's own values, which the
    /// screen saver follows until its choices first differ.
    func setScreenSaverValues(_ values: [String: String], of wallpaper: ControlWallpaper) throws -> Bool
    /// "Set as Screen Saver": a scene drawn live with its screen saver choices, a video wallpaper
    /// drawn live as it is, or a web page or WebM video drawn live through Chromium.
    func setScreenSaver(_ wallpaper: ControlWallpaper) async throws -> SystemScreenSaverSet
    /// "Stop Using as Screen Saver".
    func stopUsingScreenSaver()

    // MARK: Lock screen

    var lockScreen: SystemLockScreenState { get }
    /// Settings › General › "Show Wallpaper on Lock Screen".
    func setLockScreenEnabled(_ enabled: Bool)
    /// Shows the followed wallpaper's snapshot on every display now, as turning the setting on does.
    func refreshLockScreen()
}
