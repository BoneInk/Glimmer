import AppKit
import ImageIO
import UniformTypeIdentifiers

/// The system's now-playing session through the private MediaRemote framework, which is what the
/// menu bar's Now Playing uses. `MPNowPlayingInfoCenter` only describes the calling app's own
/// playback, so it can't stand in.
///
/// Before macOS 15.4 MediaRemote is resolved at runtime with `dlopen`/`dlsym` (`MediaRemote`); from
/// 15.4, where it answers only Apple's processes, the session is streamed from `/usr/bin/perl`
/// (`NowPlayingAdapter`; `NowPlayingBackend` picks). While neither works, or media integration is
/// turned off in Settings, the source reports `enabled == false` and stays silent.
///
/// Its registration is process-wide, so the app keeps one source and every runtime subscribes: the
/// first subscriber registers, the last one's departure unregisters. Notifications trigger a fetch;
/// while something plays with a known duration the position is re-reported once a second (WE:
/// timeline events are "sent frequently while media is playing"). Fetching and artwork decoding
/// run on `queue`; `unsubscribe` never waits for them.
///
/// An item without artwork of its own (a browser tab's video, say) has the playing app's icon as
/// its thumbnail, as the menu bar's Now Playing shows it. On Windows, WE's media helper gets a
/// thumbnail from nearly every player, browsers included; macOS players often send none, and
/// wallpapers that start their media layout on `mediaThumbnailChanged` (a paused timeline played
/// by it, say) would otherwise never start it.
///
/// WE's media blocklist (`mediablocklist`, `setBlocklist`): a session of a blocked app reaches no
/// wallpaper, which sees nothing playing (no title, cover, colours or timeline) until another app
/// plays. macOS has one now-playing session, so there is no other session to fall back to.
final class MacMediaSessionSource: MediaSessionSource {
    private let queue = DispatchQueue(label: "OpenWallpaperEngine.MediaSession", qos: .utility)
    private let framework: NowPlayingFramework?
    private let now: () -> Date
    /// The icon of the app with this bundle id, or nil.
    private let playerIcon: (String) -> CGImage?

    /// Owns `subscribers`, `nextID` and `latest`. Held while delivering a state, so `unsubscribe`
    /// waits at most for one delivery in progress (subscribers only queue it), never for fetching.
    private let lock = NSLock()
    private var subscribers: [Int: (MediaSessionState) -> Void] = [:]
    private var nextID = 0
    private var latest: MediaSessionState?
    /// The bundle id of the app the current session belongs to, blocked or not; nil when nothing
    /// plays or the app is unknown. For the blocklist's "Current media session".
    private var sessionPlayer: String?

    // Confined to `queue`.
    private var active = false
    private var info: [String: Any] = [:]
    private var isPlaying = false
    private var artwork: Artwork?
    /// The artwork bytes `artwork` was made from: the same bytes again (every publish while a
    /// track plays) reuse it without hashing them.
    private var artworkData: Data?
    /// WE's "Media integration support" setting.
    private var integrationEnabled = true
    /// WE's media blocklist: bundle ids whose sessions wallpapers don't see.
    private var blocklist: Set<String> = []
    private var observers: [NSObjectProtocol] = []
    private var timer: DispatchSourceTimer?
    private var fetchGeneration = 0

    /// The decoded artwork: its key (a hash of the data), colours and PNG.
    typealias Artwork = (key: Int, colors: ArtworkPalette.Colors?, png: Data?)

    init(framework: NowPlayingFramework? = NowPlayingBackend.load(), now: @escaping () -> Date = Date.init,
         playerIcon: @escaping (String) -> CGImage? = MacMediaSessionSource.applicationIcon(bundleIdentifier:)) {
        self.framework = framework
        self.now = now
        self.playerIcon = playerIcon
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        timer?.cancel()
        if active { framework?.unregister() }
    }

    func subscribe(_ update: @escaping (MediaSessionState) -> Void) -> Int {
        lock.lock()
        let id = nextID
        nextID += 1
        subscribers[id] = update
        lock.unlock()
        queue.async { [self] in
            reconcile()
            deliverLatest(to: id)
        }
        return id
    }

    func unsubscribe(_ id: Int) {
        lock.lock()
        subscribers[id] = nil
        lock.unlock()
        queue.async { [weak self] in self?.reconcile() }
    }

    /// WE's "Media integration support" (on by default). Off, nothing is read and every subscriber
    /// gets media integration disabled (`mediaStatusChanged({enabled: false})`), as WE's setting does.
    func setIntegrationEnabled(_ enabled: Bool) {
        queue.async { [self] in
            guard enabled != integrationEnabled else { return }
            integrationEnabled = enabled
            reconcile()
        }
    }

    /// WE's media blocklist (`GlobalSettings.mediaBlocklist`): apps, by bundle id, whose
    /// sessions no wallpaper sees. Applies to the current session at once.
    func setBlocklist(_ bundleIdentifiers: [String]) {
        queue.async { [self] in
            let blocked = Set(bundleIdentifiers)
            guard blocked != blocklist else { return }
            blocklist = blocked
            if active { publish() }
        }
    }

    /// The bundle id of the app the current session belongs to, blocked or not (nil while nothing
    /// plays, the app is unknown, or nobody subscribes). Read after an update.
    var currentSessionPlayer: String? {
        lock.lock()
        defer { lock.unlock() }
        return sessionPlayer
    }

    /// Waits until the work queued so far has run. Tests use it.
    func flush() {
        queue.sync {}
    }

    // MARK: - Lifecycle (on `queue`)

    /// Registers while anyone listens and integration is on, and unregisters otherwise.
    private func reconcile() {
        lock.lock()
        let listening = !subscribers.isEmpty
        lock.unlock()
        let wanted = listening && integrationEnabled
        if wanted && !active {
            activate()
        } else if !wanted && active {
            deactivate()
            if listening { deliver(MediaSessionState()) }
        }
    }

    private func activate() {
        active = true
        guard let framework else {
            publish()
            return
        }
        framework.register(on: queue)
        for name in framework.notificationNames {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.queue.async { self?.fetch() }
            })
        }
        publish()
        fetch()
    }

    private func deactivate() {
        active = false
        fetchGeneration += 1
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        timer?.cancel()
        timer = nil
        framework?.unregister()
        info = [:]
        isPlaying = false
        artwork = nil
        lock.lock()
        latest = nil
        sessionPlayer = nil
        lock.unlock()
    }

    private func deliverLatest(to id: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard let latest, let update = subscribers[id] else { return }
        update(latest)
    }

    // MARK: - Fetching (on `queue`)

    private func fetch() {
        guard active, let framework else { return }
        fetchGeneration += 1
        let generation = fetchGeneration
        framework.nowPlayingInfo(on: queue) { [weak self] info in
            guard let self, generation == self.fetchGeneration else { return }
            self.info = info
            framework.isPlaying(on: self.queue) { [weak self] playing in
                guard let self, generation == self.fetchGeneration else { return }
                self.isPlaying = playing
                self.publish()
            }
        }
    }

    private func publish() {
        let player = Self.sessionPlayer(of: info)
        lock.lock()
        sessionPlayer = player
        lock.unlock()
        let enabled = framework?.isAvailable ?? false
        if let player, blocklist.contains(player) {
            var state = MediaSessionState()
            state.enabled = enabled
            deliver(state)
            scheduleTimeline(running: false)
            return
        }
        let colors = artworkColors()
        let state = Self.state(from: info, isPlaying: isPlaying, enabled: enabled, now: now(), artwork: colors)
        deliver(state)
        scheduleTimeline(running: active && state.playback == .playing && state.timeline.duration > 0)
    }

    /// The bundle id of the app a now-playing dictionary belongs to, or nil.
    static func sessionPlayer(of info: [String: Any]) -> String? {
        for key in [MediaRemote.Key.sessionBundleIdentifier, MediaRemote.Key.playerBundleIdentifier] {
            if let player = info[key] as? String, !player.isEmpty { return player }
        }
        return nil
    }

    private func deliver(_ state: MediaSessionState) {
        lock.lock()
        latest = state
        for update in subscribers.values { update(state) }
        lock.unlock()
    }

    /// Decodes the artwork once per image; for an item without any, the player's icon once per player.
    private func artworkColors() -> Artwork? {
        guard let data = info[MediaRemote.Key.artworkData] as? Data, !data.isEmpty else {
            artworkData = nil
            artwork = playerArtwork()
            return artwork
        }
        if let artwork, let artworkData, Self.sameStorage(artworkData, data) { return artwork }
        var hasher = Hasher()
        hasher.combine(data)
        let key = hasher.finalize()
        if let artwork, artwork.key == key {
            artworkData = data
            return artwork
        }
        var colors: ArtworkPalette.Colors?
        var png: Data?
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            colors = ArtworkPalette.colors(of: image)
            png = Self.png(of: image, original: data, type: CGImageSourceGetType(source))
        } else {
            OWELog.error(.script, "Now-playing artwork (\(data.count) bytes) could not be decoded; thumbnail colours are unavailable")
        }
        artwork = (key, colors, png)
        artworkData = data
        return artwork
    }

    /// The playing app's icon as the artwork, when the session names the app (only for an item
    /// without artwork); nil otherwise. A missing icon is remembered too, so it is looked up once.
    private func playerArtwork() -> Artwork? {
        guard let player = info[MediaRemote.Key.playerBundleIdentifier] as? String, !player.isEmpty else { return nil }
        var hasher = Hasher()
        hasher.combine("player icon")
        hasher.combine(player)
        let key = hasher.finalize()
        if let artwork, artwork.key == key { return artwork }
        guard let image = playerIcon(player) else {
            OWELog.debug(.script, "No icon for the now-playing app \(player); the item has no thumbnail")
            return (key, nil, nil)
        }
        return (key, ArtworkPalette.colors(of: image), Self.png(of: image, original: nil, type: nil))
    }

    /// The icon of the installed app with `bundleIdentifier`, at 300 × 300 pixels, or nil.
    static func applicationIcon(bundleIdentifier: String) -> CGImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return nil }
        var rect = CGRect(x: 0, y: 0, width: 300, height: 300)
        return NSWorkspace.shared.icon(forFile: url.path).cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    /// The two are the same bytes in memory (the now-playing info handed back unchanged).
    static func sameStorage(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        let first = a.withUnsafeBytes { $0.baseAddress }, second = b.withUnsafeBytes { $0.baseAddress }
        return first != nil && first == second
    }

    /// The artwork as PNG: the original when it is one, else re-encoded (WE hands web wallpapers PNG).
    private static func png(of image: CGImage, original: Data?, type: CFString?) -> Data? {
        if let original, let type, type as String == UTType.png.identifier { return original }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            OWELog.error(.script, "PNG encoding is unavailable; web wallpapers get no album cover")
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            OWELog.error(.script, "Now-playing artwork (\(image.width)×\(image.height)) could not be encoded as PNG; web wallpapers get no album cover")
            return nil
        }
        return output as Data
    }

    private func scheduleTimeline(running: Bool) {
        if !running {
            timer?.cancel()
            timer = nil
            return
        }
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.publish() }
        timer.resume()
        self.timer = timer
    }

    // MARK: - Mapping

    /// The media state for MediaRemote's now-playing dictionary.
    static func state(from info: [String: Any], isPlaying: Bool, enabled: Bool, now: Date,
                      artwork: Artwork?) -> MediaSessionState {
        var state = MediaSessionState()
        state.enabled = enabled
        func string(_ key: String) -> String { (info[key] as? String) ?? "" }
        state.properties.title = string(MediaRemote.Key.title)
        state.properties.artist = string(MediaRemote.Key.artist)
        state.properties.albumTitle = string(MediaRemote.Key.album)
        state.properties.albumArtist = string(MediaRemote.Key.albumArtist)
        state.properties.genres = string(MediaRemote.Key.genre)
        state.properties.contentType = contentType(info[MediaRemote.Key.mediaType] as? String)
        let rate = (info[MediaRemote.Key.playbackRate] as? NSNumber)?.doubleValue
        let playing = isPlaying || (rate ?? 0) > 0
        if playing {
            state.playback = .playing
        } else if !info.isEmpty {
            state.playback = .paused
        }
        if let key = artwork?.key, let colors = artwork?.colors {
            state.thumbnail = .init(artwork: key, colors: colors, png: artwork?.png)
        }
        let duration = (info[MediaRemote.Key.duration] as? NSNumber)?.doubleValue ?? 0
        if duration > 0 {
            var position = (info[MediaRemote.Key.elapsedTime] as? NSNumber)?.doubleValue ?? 0
            if playing, let timestamp = info[MediaRemote.Key.timestamp] as? Date {
                position += now.timeIntervalSince(timestamp) * (rate ?? 1)
            }
            // Whole seconds, so a timeline change is a real one and not float noise per tick.
            state.timeline = .init(position: min(max(position.rounded(.down), 0), duration), duration: duration)
        }
        return state
    }

    private static func contentType(_ mediaType: String?) -> String {
        guard let mediaType = mediaType?.lowercased() else { return "" }
        if mediaType.contains("video") { return "video" }
        if mediaType.contains("music") || mediaType.contains("audio") || mediaType.contains("podcast") { return "music" }
        return ""
    }
}
