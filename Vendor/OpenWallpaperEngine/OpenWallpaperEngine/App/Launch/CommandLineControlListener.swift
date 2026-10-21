import AppKit
import OWEControlProtocol

/// The running app's side of `--control` (`CommandLineControlCommand`): takes each command the
/// command line posts, does it (`CommandLineControlPerformer`) and posts the answer back.
@MainActor
final class CommandLineControlListener {
    private let channel: CommandLineControlChannel
    private let perform: (CommandLineControlRequest) -> CommandLineControlReply
    private var token: NSObjectProtocol?

    init(channel: CommandLineControlChannel = .current,
         perform: @escaping (CommandLineControlRequest) -> CommandLineControlReply) {
        self.channel = channel
        self.perform = perform
    }

    func start() {
        guard token == nil else { return }
        let center = DistributedNotificationCenter.default()
        token = center.addObserver(forName: channel.requestName, object: nil, queue: .main) { [weak self] notification in
            let info = notification.userInfo as? [String: String] ?? [:]
            MainActor.assumeIsolated { self?.handle(info) }
        }
    }

    func stop() {
        if let token { DistributedNotificationCenter.default().removeObserver(token) }
        token = nil
    }

    private func handle(_ info: [String: String]) {
        guard let id = info[CommandLineControlChannel.idKey] else { return }
        let reply: CommandLineControlReply
        do {
            let data = Data((info[CommandLineControlChannel.requestKey] ?? "").utf8)
            let request = try JSONDecoder().decode(CommandLineControlRequest.self, from: data)
            OWELog.info(.app, "Command line: \(request.verb.rawValue)")
            reply = perform(request)
        } catch {
            OWELog.error(.app, "Command line: a command couldn't be read: \(error)")
            reply = CommandLineControlReply(succeeded: false, output: "Open Wallpaper Engine couldn't read the command. Run the same app version's executable.")
        }
        if !reply.succeeded { OWELog.info(.app, "Command line: \(reply.output)") }
        do {
            let json = String(decoding: try JSONEncoder().encode(reply), as: UTF8.self)
            DistributedNotificationCenter.default().postNotificationName(
                channel.replyName, object: nil,
                userInfo: [CommandLineControlChannel.idKey: id, CommandLineControlChannel.replyKey: json],
                deliverImmediately: true)
        } catch {
            OWELog.error(.app, "Command line: the answer couldn't be encoded: \(error)")
        }
    }
}

/// Does WE's command-line commands in the app, through the models the app's own controls use
/// (the MCP Server's `AppControlModel` for playback, wallpapers, playlists and properties).
@MainActor
struct CommandLineControlPerformer {
    let app: AppDelegate
    let control: AppControlModel

    private var wallpapers: WallpaperViewModel { app.wallpaperViewModel }

    struct Failure: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    func perform(_ request: CommandLineControlRequest) -> CommandLineControlReply {
        do {
            return CommandLineControlReply(succeeded: true, output: try run(request))
        } catch let failure as Failure {
            return CommandLineControlReply(succeeded: false, output: failure.message)
        } catch let error as ControlError {
            return CommandLineControlReply(succeeded: false, output: error.message)
        } catch {
            return CommandLineControlReply(succeeded: false, output: error.localizedDescription)
        }
    }

    private func run(_ request: CommandLineControlRequest) throws -> String {
        switch request.verb {
        case .pause: control.setPaused(true)
        case .stop: control.stop()
        // WE's play resumes from a pause or a stop, as Resume does.
        case .play: control.setPaused(false)
        case .mute: control.setMuted(true)
        case .unmute: control.setMuted(false)
        case .hideIcons: if !app.hidesDesktopIcons { app.toggleDesktopIcons() }
        case .showIcons: if app.hidesDesktopIcons { app.toggleDesktopIcons() }
        case .openWallpaper: try openWallpaper(request)
        case .nextWallpaper:
            let displays = try request.option("location") == nil && request.int("monitor") == nil
                ? NSScreen.screens.map(WallpaperViewModel.screenId(for:)) : [display(request)]
            _ = control.step(forward: true, displays: displays)
        case .closeWallpaper: try closeWallpaper(request)
        case .openPlaylist:
            let name = request.option("playlist") ?? ""
            guard let playlist = control.playlists().first(where: { $0.name == name })
                    ?? control.playlists().first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                throw Failure("There is no playlist \"\(name)\".")
            }
            if request.option("location") == nil, request.int("monitor") == nil {
                // On its own displays, as its shortcut starts it.
                wallpapers.startPlaylist(id: playlist.id)
            } else {
                control.playPlaylist(playlist, displays: [try display(request)])
            }
        case .openProfile:
            let name = request.option("profile") ?? ""
            guard wallpapers.displayProfiles.load(name: name) else { throw Failure("There is no profile \"\(name)\".") }
        case .applyProperties: try applyProperties(request)
        case .getWallpaper:
            let wallpaper = try shownWallpaper(request)
            return WEProject.url(in: wallpaper.settingsDirectory).path(percentEncoded: false)
        }
        return ""
    }

    // MARK: Wallpapers

    private func openWallpaper(_ request: CommandLineControlRequest) throws {
        let wallpaper = try Self.wallpaper(atPath: request.option("file") ?? "", library: app.contentViewModel.library.allWallpapers)
        if let name = request.option("playinwindow") {
            let size: PlayInWindowRequest.Size
            if let width = request.int("width"), let height = request.int("height") {
                size = .pixels(width: width, height: height)
            } else {
                size = .fullHD
            }
            let origin = request.int("x").map { x in CGPoint(x: x, y: request.int("y") ?? 0) }
                ?? request.int("y").map { CGPoint(x: 0, y: $0) }
            let window = PlayInWindowRequest(wallpaper: wallpaper, name: name.isEmpty ? PlayInWindowRequest.defaultName : name,
                                             size: size, origin: origin, borderless: request.flags.contains("borderless"),
                                             activates: request.flags.contains("activate"))
            if let refusal = app.playInWindow.open(window) { throw Failure(refusal.message) }
            if let preset = request.option("preset") { try applyPreset(preset, to: wallpaper) }
            return
        }
        // WE: the first monitor when none is given.
        let screenId = try request.option("location") == nil && request.int("monitor") == nil
            ? WallpaperViewModel.mainScreenId() : display(request)
        // As the control channel's set_wallpaper: code runs only once the user trusted it.
        guard WallpaperViewModel.mayRunWithoutAsking(wallpaper) else {
            throw Failure("\"\(wallpaper.project.displayTitle)\" runs its own code and hasn't been trusted yet, or changed since. Set it as your wallpaper once in Open Wallpaper Engine and trust it; then it can be opened from here.")
        }
        guard wallpapers.confirmApply?(wallpaper) ?? true else {
            throw Failure("\"\(wallpaper.project.displayTitle)\" wasn't opened: safe restart holds it back after it stopped the app.")
        }
        if !wallpapers.isScreenEnabled(screenId) { wallpapers.toggleScreen(screenId) }
        wallpapers.setWallpaper(wallpaper, for: [screenId])
        if let preset = request.option("preset") { try applyPreset(preset, to: wallpaper) }
    }

    /// The wallpaper at `path`: its project.json, its folder, or a file in it (WE takes a
    /// video's own file). The library's when it has it; a wallpaper folder elsewhere opens too.
    static func wallpaper(atPath path: String, library: [WEWallpaper]) throws -> WEWallpaper {
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { throw Failure("--file needs an absolute path.") }
        var url = URL(fileURLWithPath: expanded).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw Failure("Nothing at \(url.path).")
        }
        if !isDirectory.boolValue { url.deleteLastPathComponent() }
        let folder = url.standardizedFileURL.path
        if let found = library.first(where: { $0.settingsDirectory.standardizedFileURL.path == folder }) { return found }
        do {
            let decoded = try WEProject.read(in: url)
            return WEWallpaper(using: decoded, where: url)
        } catch {
            throw Failure("\(url.path) isn't a wallpaper: its project.json can't be read (\(error.localizedDescription)).")
        }
    }

    private func applyPreset(_ name: String, to wallpaper: WEWallpaper) throws {
        let targets = WallpaperPropertyTargets(wallpaper: wallpaper, scopes: control.scopes(of: wallpaper))
        let presets: [WallpaperPreset]
        do {
            presets = try WallpaperPresetStore(identity: targets.identity).presets()
        } catch {
            throw Failure("The presets of \"\(wallpaper.project.displayTitle)\" can't be read: \(error.localizedDescription)")
        }
        guard let preset = presets.first(where: { $0.name == name }) else {
            throw Failure("\"\(wallpaper.project.displayTitle)\" has no preset \"\(name)\".")
        }
        targets.apply(preset: preset.values)
    }

    private func closeWallpaper(_ request: CommandLineControlRequest) throws {
        if let location = request.option("location"), app.playInWindow.close(location) { return }
        if request.option("location") == nil, request.int("monitor") == nil {
            // Every wallpaper: the windows close and every display shows its desktop picture.
            app.playInWindow.close()
            for screenId in NSScreen.screens.map(WallpaperViewModel.screenId(for:)) where wallpapers.isScreenEnabled(screenId) {
                wallpapers.toggleScreen(screenId)
            }
            return
        }
        let screenId = DisplayLayoutResolution.screen(of: try display(request))
        if wallpapers.isScreenEnabled(screenId) { wallpapers.toggleScreen(screenId) }
    }

    private func applyProperties(_ request: CommandLineControlRequest) throws {
        let json = request.option("properties") ?? ""
        let object: [String: Any]
        do {
            guard let decoded = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
                throw Failure("--properties needs a JSON object, e.g. RAW~({\"rate\":10})~END.")
            }
            object = decoded
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure("--properties isn't JSON: \(error.localizedDescription)")
        }
        let wallpaper = control.control(try shownWallpaper(request))
        for (key, value) in object.sorted(by: { $0.key < $1.key }) {
            _ = control.setUserProperty(key, to: Self.propertyValue(value), of: wallpaper)
        }
    }

    /// A JSON value as a stored property value: WE's strings as they are, numbers and switches
    /// as their text.
    static func propertyValue(_ value: Any) -> String {
        switch value {
        case let string as String: return string
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return number.stringValue
        default:
            return String(describing: value)
        }
    }

    // MARK: Targets

    /// The wallpaper `-location` (a display or a window's name) or `-monitor` shows; the main
    /// display's when neither is given.
    private func shownWallpaper(_ request: CommandLineControlRequest) throws -> WEWallpaper {
        if let location = request.option("location"), let shown = app.playInWindow.wallpaper(in: location) { return shown }
        let screenId = try request.option("location") == nil && request.int("monitor") == nil
            ? WallpaperViewModel.mainScreenId() : display(request)
        let wallpaper = wallpapers.wallpaper(for: screenId)
        guard wallpaper.project != .invalid, wallpapers.isScreenEnabled(screenId) else {
            throw Failure("No wallpaper shows on that display.")
        }
        return wallpaper
    }

    /// The display (or a split display's region) `-location` or `-monitor` names.
    private func display(_ request: CommandLineControlRequest) throws -> String {
        let connected = wallpapers.connectedDisplays()
        if let location = request.option("location") {
            guard let screenId = Self.screenId(ofLocation: location, connected: connected) else {
                throw Failure("No display or Play in Window window is called \"\(location)\". Displays: \(connected.map(\.identity).joined(separator: ", ")).")
            }
            return screenId
        }
        let index = request.int("monitor") ?? 0
        guard connected.indices.contains(index) else {
            throw Failure("There is no monitor \(index); the displays are numbered 0 to \(connected.count - 1).")
        }
        return connected[index].screenId
    }

    /// A display's identity (as profiles and WE's `config.json` name it), its id, or either with
    /// a region (`/L`…).
    static func screenId(ofLocation location: String, connected: [DisplayIdentity]) -> String? {
        let display = DisplayLayoutConfiguration.display(of: location)
        let region = location.dropFirst(display.count)
        if let match = connected.first(where: { $0.identity.caseInsensitiveCompare(display) == .orderedSame || $0.screenId == display }) {
            return match.screenId + region
        }
        return nil
    }
}
