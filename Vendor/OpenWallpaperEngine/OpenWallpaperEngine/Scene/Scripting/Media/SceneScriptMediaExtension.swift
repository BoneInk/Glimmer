import Foundation
import JavaScriptCore

extension SceneScriptEvent.Kind {
    /// `mediaStatusChanged({enabled})`.
    static let mediaStatus = Self(rawValue: "mediaStatus")
    /// `mediaPlaybackChanged({state})`.
    static let mediaPlayback = Self(rawValue: "mediaPlayback")
    /// `mediaPropertiesChanged({title, artist, subTitle, albumTitle, albumArtist, genres, contentType})`.
    static let mediaProperties = Self(rawValue: "mediaProperties")
    /// `mediaThumbnailChanged({hasThumbnail, primaryColor, …})`, colours as `[r, g, b]`.
    static let mediaThumbnail = Self(rawValue: "mediaThumbnail")
    /// `mediaTimelineChanged({position, duration})`.
    static let mediaTimeline = Self(rawValue: "mediaTimeline")
}

/// WP6 of docs/scenescript-plan.md: the five media callbacks, fed by a `MediaSessionSource`
/// (one per process, shared by every runtime's extension).
///
/// The source reports whole states from any thread; each state that differs from the last becomes
/// a new version, and the changed parts wait here, newest per kind. Right before each frame they go
/// into the inbox in WE's order (status, playback, properties, thumbnail, timeline), so scripts get
/// them at the media position of the frame (§1.9 P1), and a paused wallpaper holds at most five
/// pending media events instead of filling the inbox with timeline ticks.
///
/// A script also gets the current state right after its `init`, as WE sends it (§1.9 P8; only the
/// parts that aren't empty, see `MediaSessionState.initialChanges`). That goes through
/// `__rt.hooks.initialized` and `__rt.native.mediaSnapshot()`, which returns the state with its
/// version; events of that version or older are then skipped for that script, so it never sees a
/// change twice.
final class SceneScriptMediaExtension: SceneScriptRuntimeExtension {
    let scriptResources = ["sceneScriptMedia"]

    private let source: MediaSessionSource
    private var subscription: Int?
    /// Owns `state`, `version` and `pending`: the source reports on its own queue, the runtime
    /// reads on its thread.
    private let lock = NSLock()
    private var state = MediaSessionState()
    private var version = 0
    /// The newest change of each kind not yet posted, with the version it came with.
    private var pending: [SceneScriptEvent.Kind: (change: MediaSessionState.Change, version: Int)] = [:]

    init(source: MediaSessionSource) {
        self.source = source
    }

    deinit {
        if let subscription { source.unsubscribe(subscription) }
    }

    func install(into runtime: SceneScriptRuntime) throws {
        guard let native = runtime.rt.forProperty("native"), native.isObject else {
            throw SceneScriptRuntime.CreationError(description: "runtime.js has no __rt.native")
        }
        let snapshot: @convention(block) () -> [String: Any] = { [weak self] in
            self?.snapshotObject() ?? ["version": 0, "events": [Any]()]
        }
        native.setValue(unsafeBitCast(snapshot, to: AnyObject.self), forProperty: "mediaSnapshot")
        subscription = source.subscribe { [weak self] state in self?.receive(state) }
    }

    /// Posts the pending changes, newest per kind, in WE's order.
    func willRunFrame(_ runtime: SceneScriptRuntime, deltaTime: Double) {
        lock.lock()
        let posting = pending.values.sorted { $0.change.order < $1.change.order }
        pending.removeAll()
        lock.unlock()
        for entry in posting {
            runtime.inbox.post(SceneScriptEvent(kind: entry.change.kind, payload: entry.change.payload(version: entry.version)))
        }
    }

    /// Takes a state from the source (any thread).
    func receive(_ newState: MediaSessionState) {
        lock.lock()
        defer { lock.unlock() }
        let changes = newState.changes(since: state)
        state = newState
        guard !changes.isEmpty else { return }
        version += 1
        for change in changes { pending[change.kind] = (change, version) }
    }

    private func snapshotObject() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        let events = state.initialChanges.map { change -> [String: Any] in
            ["kind": change.kind.rawValue, "payload": change.payload(version: version)]
        }
        return ["version": version, "events": events]
    }
}

private extension MediaSessionState.Change {
    /// WE's callback order (scenescript64.dll indices 14–18).
    var order: Int {
        switch self {
        case .status: return 0
        case .playback: return 1
        case .properties: return 2
        case .thumbnail: return 3
        case .timeline: return 4
        }
    }

    var kind: SceneScriptEvent.Kind {
        switch self {
        case .status: return .mediaStatus
        case .playback: return .mediaPlayback
        case .properties: return .mediaProperties
        case .thumbnail: return .mediaThumbnail
        case .timeline: return .mediaTimeline
        }
    }

    /// The JS-convertible payload `sceneScriptMedia.js` turns into WE's event object.
    func payload(version: Int) -> [String: Any] {
        switch self {
        case .status(let enabled):
            return ["version": version, "enabled": enabled]
        case .playback(let playback):
            return ["version": version, "state": playback.rawValue]
        case .properties(let properties):
            return ["version": version, "title": properties.title, "artist": properties.artist,
                    "subTitle": properties.subTitle, "albumTitle": properties.albumTitle,
                    "albumArtist": properties.albumArtist, "genres": properties.genres,
                    "contentType": properties.contentType]
        case .thumbnail(let thumbnail):
            let colors = thumbnail.colors
            func rgb(_ color: SIMD3<Float>?) -> [Double] {
                let color = color ?? .zero
                return [Double(color.x), Double(color.y), Double(color.z)]
            }
            return ["version": version, "hasThumbnail": thumbnail.hasThumbnail,
                    "primaryColor": rgb(colors?.primary), "secondaryColor": rgb(colors?.secondary),
                    "tertiaryColor": rgb(colors?.tertiary), "textColor": rgb(colors?.text),
                    "highContrastColor": rgb(colors?.highContrast)]
        case .timeline(let timeline):
            return ["version": version, "position": timeline.position, "duration": timeline.duration]
        }
    }
}
