import Foundation

/// The messages Open Wallpaper Engine and its Wallpaper Editor process exchange, through the
/// login session's distributed notification centre. A message is a name and, at most, a
/// wallpaper's folder as its key, with an undo step's name or a timeline command where the message
/// says: never the edits or any other data, which each process reads from the files and defaults
/// they share.
///
/// Names carry the process's isolation (`AppStorageLocation`): an isolated copy only talks to
/// processes isolated under the same tag, never to the user's own app.
struct AppProcessChannel: Equatable {
    enum Message: String, CaseIterable {
        /// The editor saved a wallpaper's overlay (File › Save, `SceneEditOverlayFiles`).
        case overlayDidSave = "editor.overlayDidSave"
        /// A wallpaper's user properties were saved (`Notification.Name.wallpaperPropertiesDidSave`).
        case propertiesDidSave = "properties.didSave"
        /// A wallpaper was added to the library (Save as New Wallpaper).
        case libraryDidChange = "library.didChange"
        /// Open (or bring forward) the editor window of a wallpaper.
        case openWallpaper = "editor.open"
        /// The editor process is ready for `openWallpaper`.
        case editorReady = "editor.ready"
        /// Show the app's setup of WE's assets (Settings › Assets), which the editor's browsers offer.
        case openAssetsSettings = "app.openAssetsSettings"
        /// Show the app's Settings › Plugins › Depth Map Generation, where the editor's depth map
        /// section sends the user to install its model.
        case openDepthMapSettings = "app.openDepthMapSettings"
        /// Open Wallpaper Engine changed a wallpaper's draft for an MCP client (`HeadlessSceneDocument`):
        /// the editor's open window of it takes the change as an undo step (`actionKey` names it), or
        /// undoes or redoes the step it took (`stepKey`).
        case appOverlayDidSave = "app.overlayDidSave"
        /// Open Wallpaper Engine saved a wallpaper's draft for an MCP client (`wallpaper_editor_save`):
        /// the editor's open window of it has nothing unsaved.
        case appDraftDidSave = "app.draftDidSave"
        /// Close the editor window of a wallpaper.
        case closeWallpaper = "editor.close"
        /// Play, pause or seek the timeline of a wallpaper's editor window (`timelineCommandKey`,
        /// `secondsKey`).
        case timeline = "editor.timeline"
        /// Restart particle systems (`layersKey`) in a wallpaper's editor window, the draft its
        /// canvas runs (an MCP client's `particles_restart`).
        case particlesRestart = "editor.particlesRestart"
        /// The editor restarted them: it has a window of the wallpaper.
        case particlesRestarted = "editor.particlesRestarted"
        /// Theming's tint of the app's windows changed (`ThemeTintSync`, in the shared defaults):
        /// the editor's windows take it too.
        case themeTintDidChange = "app.themeTintDidChange"
    }

    /// The `userInfo` key of the wallpaper's folder.
    static let folderKey = "folder"
    /// The `userInfo` key of an undo step's name (`appOverlayDidSave`).
    static let actionKey = "action"
    /// The `userInfo` key of what the save was (`OverlayStep`, `appOverlayDidSave`).
    static let stepKey = "step"
    /// The `userInfo` keys of a timeline command (`play`, `pause`, `seek`) and its time in seconds.
    static let timelineCommandKey = "command"
    static let secondsKey = "seconds"
    /// The `userInfo` key of the particle systems' layer ids, comma-separated (`particlesRestart`).
    static let layersKey = "layers"

    /// What an MCP client's save of an overlay was: a new undo step, or an Undo or Redo of one,
    /// which the editor's window follows in its own history.
    enum OverlayStep: String {
        case edit, undo, redo
    }

    let prefix: String

    init(isolationTag: String?, bundleIdentifier: String = AppStorageLocation.realBundleIdentifier) {
        prefix = isolationTag.map { "\(bundleIdentifier).isolated.\($0)" } ?? bundleIdentifier
    }

    static var current: AppProcessChannel { AppProcessChannel(isolationTag: AppStorageLocation.current.isolationTag) }

    func name(_ message: Message) -> Notification.Name {
        Notification.Name("\(prefix).\(message.rawValue)")
    }

    /// This process, as the sender of what it posts (so it can pass over its own messages).
    static var processSender: String { String(ProcessInfo.processInfo.processIdentifier) }
}

/// Where the processes' messages go: the session's distributed notification centre, or an
/// in-memory one in tests.
@MainActor
protocol AppProcessMessaging: AnyObject {
    func post(_ name: Notification.Name, sender: String, userInfo: [String: String])
    /// `handler` gets the sender and the `userInfo` of every `name` posted, on the main queue.
    func observe(_ name: Notification.Name,
                 _ handler: @escaping @MainActor (_ sender: String?, _ userInfo: [String: String]) -> Void) -> AnyObject
    func remove(_ token: AnyObject)
}

/// The login session's `DistributedNotificationCenter`. Posts are delivered at once even to an
/// inactive app (which AppKit otherwise holds them for): the editor's edits reach the desktop
/// while the user works in the editor.
@MainActor
final class DistributedAppProcessMessaging: AppProcessMessaging {
    private let center = DistributedNotificationCenter.default()

    func post(_ name: Notification.Name, sender: String, userInfo: [String: String]) {
        center.postNotificationName(name, object: sender, userInfo: userInfo, deliverImmediately: true)
    }

    func observe(_ name: Notification.Name,
                 _ handler: @escaping @MainActor (String?, [String: String]) -> Void) -> AnyObject {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { notification in
            let sender = notification.object as? String
            let info = notification.userInfo as? [String: String] ?? [:]
            MainActor.assumeIsolated { handler(sender, info) }
        }
        return token as AnyObject
    }

    func remove(_ token: AnyObject) {
        center.removeObserver(token)
    }
}
