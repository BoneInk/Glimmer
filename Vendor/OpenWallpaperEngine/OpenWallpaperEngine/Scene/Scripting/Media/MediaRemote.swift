import Foundation

/// MediaRemote's functions, resolved at runtime. Nil from `load()` when the framework or any
/// symbol is missing (logged once, `.info`). Registration is process-wide: keep one
/// `MacMediaSessionSource` per process.
struct MediaRemote: NowPlayingFramework {
    typealias Register = @convention(c) (DispatchQueue) -> Void
    typealias Unregister = @convention(c) () -> Void
    typealias GetNowPlayingInfo = @convention(c) (DispatchQueue, @escaping @convention(block) (NSDictionary?) -> Void) -> Void
    typealias GetIsPlaying = @convention(c) (DispatchQueue, @escaping @convention(block) (Bool) -> Void) -> Void
    typealias GetNowPlayingClient = @convention(c) (DispatchQueue, @escaping @convention(block) (AnyObject?) -> Void) -> Void
    typealias GetClientBundleIdentifier = @convention(c) (AnyObject) -> Unmanaged<CFString>?

    /// The now-playing dictionary's keys (the constants' values are their names).
    enum Key {
        static let title = "kMRMediaRemoteNowPlayingInfoTitle"
        static let artist = "kMRMediaRemoteNowPlayingInfoArtist"
        static let album = "kMRMediaRemoteNowPlayingInfoAlbum"
        static let albumArtist = "kMRMediaRemoteNowPlayingInfoAlbumArtist"
        static let genre = "kMRMediaRemoteNowPlayingInfoGenre"
        static let mediaType = "kMRMediaRemoteNowPlayingInfoMediaType"
        static let duration = "kMRMediaRemoteNowPlayingInfoDuration"
        static let elapsedTime = "kMRMediaRemoteNowPlayingInfoElapsedTime"
        static let timestamp = "kMRMediaRemoteNowPlayingInfoTimestamp"
        static let playbackRate = "kMRMediaRemoteNowPlayingInfoPlaybackRate"
        static let artworkData = "kMRMediaRemoteNowPlayingInfoArtworkData"
        /// Set with artwork the player has but hasn't sent yet.
        static let artworkIdentifier = "kMRMediaRemoteNowPlayingInfoArtworkIdentifier"
        static let artworkMIMEType = "kMRMediaRemoteNowPlayingInfoArtworkMIMEType"
        /// Not MediaRemote's: the bundle id of the app playing an item without artwork of its own,
        /// added by this struct and by `nowPlayingAdapter.pl` (`MacMediaSessionSource` shows its icon).
        static let playerBundleIdentifier = "playerBundleIdentifier"
        /// Not MediaRemote's: the bundle id of the app the session belongs to, whatever its artwork
        /// (its parent app's for a helper process), for WE's media blocklist.
        static let sessionBundleIdentifier = "sessionBundleIdentifier"
    }

    static let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
    static let notificationSymbols = [
        "kMRMediaRemoteNowPlayingInfoDidChangeNotification",
        "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
        "kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
    ]

    private let registerFunction: Register
    private let unregisterFunction: Unregister
    private let getNowPlayingInfo: GetNowPlayingInfo
    private let getIsPlaying: GetIsPlaying
    /// The playing app's client and its bundle ids (its parent app's first); nil when missing.
    private let getNowPlayingClient: GetNowPlayingClient?
    private let clientBundleIdentifiers: [GetClientBundleIdentifier]
    let notificationNames: [Notification.Name]

    func register(on queue: DispatchQueue) {
        registerFunction(queue)
    }

    func unregister() {
        unregisterFunction()
    }

    func nowPlayingInfo(on queue: DispatchQueue, _ handler: @escaping ([String: Any]) -> Void) {
        getNowPlayingInfo(queue) { [self] dictionary in
            let info = (dictionary as? [String: Any]) ?? [:]
            let hasArtwork = [Key.artworkData, Key.artworkIdentifier, Key.artworkMIMEType].contains { info[$0] != nil }
            guard !info.isEmpty, let getNowPlayingClient else { return handler(info) }
            getNowPlayingClient(queue) { [self] client in
                var info = info
                if let client, let player = clientBundleIdentifiers.lazy
                    .compactMap({ $0(client)?.takeUnretainedValue() as String? }).first(where: { !$0.isEmpty }) {
                    info[Key.sessionBundleIdentifier] = player
                    if !hasArtwork { info[Key.playerBundleIdentifier] = player }
                }
                handler(info)
            }
        }
    }

    func isPlaying(on queue: DispatchQueue, _ handler: @escaping (Bool) -> Void) {
        getIsPlaying(queue) { playing in handler(playing) }
    }

    static func load() -> MediaRemote? {
        guard let handle = dlopen(path, RTLD_LAZY) else {
            OWELog.info(.script, "MediaRemote is unavailable; SceneScript media events are off")
            return nil
        }
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }
        guard let register = symbol("MRMediaRemoteRegisterForNowPlayingNotifications", as: Register.self),
              let unregister = symbol("MRMediaRemoteUnregisterForNowPlayingNotifications", as: Unregister.self),
              let getInfo = symbol("MRMediaRemoteGetNowPlayingInfo", as: GetNowPlayingInfo.self),
              let getIsPlaying = symbol("MRMediaRemoteGetNowPlayingApplicationIsPlaying", as: GetIsPlaying.self) else {
            OWELog.info(.script, "MediaRemote lacks a now-playing function; SceneScript media events are off")
            return nil
        }
        // Each constant is a CFStringRef whose value is (in every release so far) its own name.
        let names = notificationSymbols.map { name -> Notification.Name in
            guard let pointer = dlsym(handle, name) else { return Notification.Name(name) }
            let value = pointer.assumingMemoryBound(to: CFString?.self).pointee
            return Notification.Name(value.map { $0 as String } ?? name)
        }
        let bundleIdentifiers = ["MRNowPlayingClientGetParentAppBundleIdentifier", "MRNowPlayingClientGetBundleIdentifier"]
            .compactMap { symbol($0, as: GetClientBundleIdentifier.self) }
        return MediaRemote(registerFunction: register, unregisterFunction: unregister, getNowPlayingInfo: getInfo,
                           getIsPlaying: getIsPlaying,
                           getNowPlayingClient: symbol("MRMediaRemoteGetNowPlayingClient", as: GetNowPlayingClient.self),
                           clientBundleIdentifiers: bundleIdentifiers, notificationNames: names)
    }
}
