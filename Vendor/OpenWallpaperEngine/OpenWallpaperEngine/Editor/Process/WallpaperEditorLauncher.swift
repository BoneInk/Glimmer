import AppKit

extension AppDelegate {
    /// Opens `wallpaper` in the Wallpaper Editor (editor-plan notes), which is an app of its own:
    /// quitting Open Wallpaper Engine leaves it open, and closing it leaves the app as it was.
    /// Scene wallpapers only.
    func showWallpaperEditor(for wallpaper: WEWallpaper) {
        guard WallpaperEditorController.canEdit(wallpaper) else { return }
        wallpaperEditorLauncher.open(wallpaper.settingsDirectory)
    }
}

/// Open Wallpaper Engine's side of the Wallpaper Editor's app (`<app>/Contents/Helpers/Wallpaper
/// Editor.app`, `AppBundleLayout`): one editor process for every wallpaper. Opening a wallpaper
/// asks the running editor (`AppProcessChannel.Message.openWallpaper`), else opens the editor's app
/// through LaunchServices with `--wallpaper-editor <folder>`, so it is no child of the app and
/// outlives it. Requests made while it starts wait until it says it is ready.
@MainActor
final class WallpaperEditorLauncher {
    struct Dependencies {
        var messaging: AppProcessMessaging
        var channel: AppProcessChannel
        var sender: String = AppProcessChannel.processSender
        var isolationTag: String? = AppStorageLocation.current.isolationTag
        /// The editor's app inside this one.
        var editorApp: URL = AppBundleLayout.editorURL(inApp: Bundle.main.bundleURL)
        /// The language the app was set to (Settings › General), for the editor to show.
        var languages: [String]? = WallpaperEditorLauncher.appLanguages()
        /// Whether an editor process (isolated as this app is) runs.
        var editorIsRunning: () -> Bool = {
            let editor = AppBundleLayout.editorIdentifier(for: Bundle.main.bundleIdentifier ?? AppStorageLocation.realBundleIdentifier)
            return !AppProcessList.running(.wallpaperEditor, bundleIdentifier: editor).isEmpty
        }
        /// Opens the app at the URL with these arguments and environment.
        var launch: (_ app: URL, _ arguments: [String], _ environment: [String: String],
                     _ done: @escaping @MainActor (Error?) -> Void) -> Void = WallpaperEditorLauncher.openApp
        var now: () -> Date = Date.init
        /// How long a request that needs the editor's answer waits for it (`restartParticles`).
        var replyTimeout: TimeInterval = 1
    }

    /// How long requests wait for a launched editor to say it is ready before asking again.
    static let launchTimeout: TimeInterval = 20

    private let dependencies: Dependencies
    private var token: AnyObject?
    /// When the editor this app launched started, until it says it is ready.
    private var launchStarted: Date?
    /// Folders asked for while the editor starts.
    private var waiting: [URL] = []
    /// The editor's app couldn't be opened.
    var onLaunchFailure: ((Error) -> Void)?

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    func start() {
        guard token == nil else { return }
        token = dependencies.messaging.observe(dependencies.channel.name(.editorReady)) { [weak self] sender, _ in
            guard let self, sender != self.dependencies.sender else { return }
            self.editorDidBecomeReady()
        }
    }

    func stop() {
        if let token { dependencies.messaging.remove(token) }
        token = nil
    }

    /// Opens (or brings forward) the editor of the wallpaper in `folder`.
    func open(_ folder: URL) {
        let folder = folder.standardizedFileURL
        if let launchStarted, dependencies.now().timeIntervalSince(launchStarted) < Self.launchTimeout {
            if !waiting.contains(folder) { waiting.append(folder) }
            return
        }
        launchStarted = nil
        if dependencies.editorIsRunning() {
            send(folder)
            return
        }
        launchStarted = dependencies.now()
        let arguments = AppLaunchMode.wallpaperEditorArguments(folder: folder, isolationTag: dependencies.isolationTag,
                                                               languages: dependencies.languages)
        var environment: [String: String] = [:]
        if let tag = dependencies.isolationTag { environment[AppStorageLocation.environmentKey] = tag }
        OWELog.info(.ui, "Opening the Wallpaper Editor (\(dependencies.editorApp.path)) for \(folder.path)")
        dependencies.launch(dependencies.editorApp, arguments, environment) { [weak self] error in
            guard let self, let error else { return }
            OWELog.error(.ui, "Can't open the Wallpaper Editor at \(self.dependencies.editorApp.path): \(error)")
            self.launchStarted = nil
            self.waiting = []
            self.onLaunchFailure?(error)
        }
    }

    /// Asks the running editor to close the window of the wallpaper in `folder`; false when no
    /// editor runs.
    @discardableResult
    func close(_ folder: URL) -> Bool {
        post(.closeWallpaper, folder: folder)
    }

    /// Asks the running editor to play, pause or seek the timeline of the wallpaper's window; false
    /// when no editor runs.
    @discardableResult
    func controlTimeline(_ folder: URL, command: String, seconds: Double?) -> Bool {
        var info = [AppProcessChannel.timelineCommandKey: command]
        if let seconds { info[AppProcessChannel.secondsKey] = String(seconds) }
        return post(.timeline, folder: folder, extra: info)
    }

    /// Asks the running editor to restart the particle systems `layers` in its window of the
    /// wallpaper in `folder` (the draft its canvas runs). True once it says it did; false when no
    /// editor runs, it has no window of the wallpaper, or it doesn't answer within `replyTimeout`.
    func restartParticles(_ folder: URL, layers: Set<Int>) async -> Bool {
        let path = folder.standardizedFileURL.path(percentEncoded: false)
        let reply = EditorReply()
        return await withCheckedContinuation { continuation in
            reply.continuation = continuation
            let messaging = dependencies.messaging, sender = dependencies.sender
            reply.token = messaging.observe(dependencies.channel.name(.particlesRestarted)) { replier, info in
                guard replier != sender, info[AppProcessChannel.folderKey] == path else { return }
                reply.finish(true, messaging: messaging)
            }
            let layerList = layers.sorted().map(String.init).joined(separator: ",")
            guard post(.particlesRestart, folder: folder, extra: [AppProcessChannel.layersKey: layerList]) else {
                return reply.finish(false, messaging: messaging)
            }
            let timeout = dependencies.replyTimeout
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeout)) // Cancellation can't happen: nothing cancels it.
                reply.finish(false, messaging: messaging)
            }
        }
    }

    private func post(_ message: AppProcessChannel.Message, folder: URL, extra: [String: String] = [:]) -> Bool {
        guard dependencies.editorIsRunning() else { return false }
        var info = extra
        info[AppProcessChannel.folderKey] = folder.standardizedFileURL.path(percentEncoded: false)
        dependencies.messaging.post(dependencies.channel.name(message), sender: dependencies.sender, userInfo: info)
        return true
    }

    private func editorDidBecomeReady() {
        launchStarted = nil
        let folders = waiting
        waiting = []
        for folder in folders { send(folder) }
    }

    private func send(_ folder: URL) {
        dependencies.messaging.post(dependencies.channel.name(.openWallpaper), sender: dependencies.sender,
                                    userInfo: [AppProcessChannel.folderKey: folder.path(percentEncoded: false)])
    }

    /// The `AppleLanguages` the app's own defaults hold (the language set in Settings), nil when
    /// it follows the system.
    nonisolated static func appLanguages(location: AppStorageLocation = .current) -> [String]? {
        let domain = location.suiteName ?? AppBundleLayout.appIdentifier(for: Bundle.main.bundleIdentifier
                                                                          ?? AppStorageLocation.realBundleIdentifier)
        return location.defaults.persistentDomain(forName: domain)?["AppleLanguages"] as? [String]
    }

    /// Opens the editor's app through LaunchServices (not a child process). A new instance even
    /// when one runs: one that runs isolated otherwise than this app would be brought forward
    /// instead (a running editor isolated as this app is gets the folder as a message, `open`).
    nonisolated static func openApp(at app: URL, arguments: [String], environment: [String: String],
                                    done: @escaping @MainActor (Error?) -> Void) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.arguments = arguments
        if !environment.isEmpty { configuration.environment = environment }
        NSWorkspace.shared.openApplication(at: app, configuration: configuration) { _, error in
            DispatchQueue.main.async { MainActor.assumeIsolated { done(error) } }
        }
    }
}

/// One answer the app waits for from the editor: the first of the answer and the timeout resumes
/// the waiting request, once.
@MainActor
private final class EditorReply {
    var continuation: CheckedContinuation<Bool, Never>?
    var token: AnyObject?

    func finish(_ result: Bool, messaging: AppProcessMessaging) {
        guard let continuation else { return }
        self.continuation = nil
        if let token { messaging.remove(token) }
        token = nil
        continuation.resume(returning: result)
    }
}
