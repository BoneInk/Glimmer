import Foundation

/// Reports the system's memory pressure (`DispatchSource.makeMemoryPressureSource`) to one
/// renderer, which then drops what it can rebuild. One per renderer, so each wallpaper instance
/// trims its own caches; cancelled when released.
final class SceneMemoryPressure {
    enum Level: Equatable {
        /// Drop free and spare memory: pooled targets, text, uniform chunks.
        case warning
        /// Also drop caches that cost work to rebuild: asset textures and idle pipelines.
        case critical
    }

    private let source: DispatchSourceMemoryPressure

    /// `handler` runs on `queue` (the render thread's).
    init(queue: DispatchQueue = .main, handler: @escaping (Level) -> Void) {
        source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: queue)
        source.setEventHandler { [source] in
            guard let level = Self.level(for: source.data) else { return }
            handler(level)
        }
        source.activate()
    }

    deinit { source.cancel() }

    /// The level an event reports; nil for a return to normal.
    static func level(for event: DispatchSource.MemoryPressureEvent) -> Level? {
        if event.contains(.critical) { return .critical }
        if event.contains(.warning) { return .warning }
        return nil
    }
}
