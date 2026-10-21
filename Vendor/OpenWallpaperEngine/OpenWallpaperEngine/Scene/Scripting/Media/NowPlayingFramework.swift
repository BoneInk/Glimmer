import Foundation

/// What `MacMediaSessionSource` needs from the system's now-playing service: MediaRemote
/// (`MediaRemote`) or its adapter (`NowPlayingAdapter`) in the app, a fake in tests
/// (`NowPlayingBackend` picks one). Registration is process-wide.
protocol NowPlayingFramework {
    /// Posted (on `NotificationCenter.default`) when the now-playing info or state may have changed.
    var notificationNames: [Notification.Name] { get }
    /// Whether the service answers. MediaRemote does once loaded; the adapter only once it has
    /// reported, and no longer after it failed. WE's `MediaStatusEvent.enabled` follows it.
    var isAvailable: Bool { get }
    func register(on queue: DispatchQueue)
    func unregister()
    /// The now-playing dictionary (MediaRemote's `kMRMediaRemoteNowPlayingInfo…` keys), on `queue`.
    func nowPlayingInfo(on queue: DispatchQueue, _ handler: @escaping ([String: Any]) -> Void)
    func isPlaying(on queue: DispatchQueue, _ handler: @escaping (Bool) -> Void)
}

extension NowPlayingFramework {
    var isAvailable: Bool { true }
}
