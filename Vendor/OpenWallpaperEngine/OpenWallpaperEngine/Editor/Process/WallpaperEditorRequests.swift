import Foundation

/// The editor windows of the Wallpaper Editor's process.
@MainActor
protocol WallpaperEditorWindows: AnyObject {
    /// Opens the editor of the wallpaper in `folder`, or brings its window forward; false when it
    /// can't be opened (the user was told).
    @discardableResult
    func showEditor(of folder: URL) -> Bool
    /// Closes the editor window of the wallpaper in `folder`, if one is open.
    func closeEditor(of folder: URL)
    /// Plays, pauses or seeks (`seconds`) the timeline of the wallpaper's open window.
    func controlTimeline(of folder: URL, command: String, seconds: Double?)
    /// Restarts the particle systems `layers` in the wallpaper's open window; false without one.
    func restartParticles(of folder: URL, layers: Set<Int>) -> Bool
}

extension WallpaperEditorWindows {
    func closeEditor(of folder: URL) {}
    func controlTimeline(of folder: URL, command: String, seconds: Double?) {}
    func restartParticles(of folder: URL, layers: Set<Int>) -> Bool { false }
}

/// The Wallpaper Editor process's side of `WallpaperEditorLauncher`: it opens the wallpapers Open
/// Wallpaper Engine asks for in this process, one window each, and says when it is ready for them;
/// it closes them, drives their timelines and restarts their particle systems when the app asks
/// (an MCP client), answering a restart it made (`particlesRestarted`).
@MainActor
final class WallpaperEditorRequests {
    private let messaging: AppProcessMessaging
    private let channel: AppProcessChannel
    private let sender: String
    private weak var windows: WallpaperEditorWindows?
    private var tokens: [AnyObject] = []

    init(messaging: AppProcessMessaging, channel: AppProcessChannel, sender: String = AppProcessChannel.processSender,
         windows: WallpaperEditorWindows) {
        self.messaging = messaging
        self.channel = channel
        self.sender = sender
        self.windows = windows
    }

    /// Takes the app's requests from now on.
    func start() {
        guard tokens.isEmpty else { return }
        func on(_ message: AppProcessChannel.Message, _ handle: @escaping @MainActor (WallpaperEditorWindows, URL, [String: String]) -> Void) {
            tokens.append(messaging.observe(channel.name(message)) { [weak self] sender, info in
                guard let self, sender != self.sender, let path = info[AppProcessChannel.folderKey], !path.isEmpty,
                      let windows = self.windows else { return }
                handle(windows, URL(filePath: path, directoryHint: .isDirectory), info)
            })
        }
        on(.openWallpaper) { windows, folder, _ in _ = windows.showEditor(of: folder) }
        on(.closeWallpaper) { windows, folder, _ in windows.closeEditor(of: folder) }
        on(.timeline) { windows, folder, info in
            windows.controlTimeline(of: folder, command: info[AppProcessChannel.timelineCommandKey] ?? "",
                                    seconds: info[AppProcessChannel.secondsKey].flatMap(Double.init))
        }
        on(.particlesRestart) { [weak self] windows, folder, info in
            let layers = Set((info[AppProcessChannel.layersKey] ?? "").split(separator: ",").compactMap { Int($0) })
            guard let self, !layers.isEmpty, windows.restartParticles(of: folder, layers: layers) else { return }
            self.messaging.post(self.channel.name(.particlesRestarted), sender: self.sender,
                                userInfo: [AppProcessChannel.folderKey: info[AppProcessChannel.folderKey] ?? ""])
        }
    }

    /// Tells the app that launched this process that requests are taken now.
    func announceReady() {
        messaging.post(channel.name(.editorReady), sender: sender, userInfo: [:])
    }

    func stop() {
        for token in tokens { messaging.remove(token) }
        tokens = []
    }
}
