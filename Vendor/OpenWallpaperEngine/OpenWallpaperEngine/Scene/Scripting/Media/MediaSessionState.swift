import Foundation

/// What WE's media integration knows about the system's now-playing session, in the shape of its
/// five SceneScript events (lib.sceneScript.d.ts `MediaStatusEvent`, `MediaPlaybackEvent`,
/// `MediaPropertiesEvent`, `MediaThumbnailEvent`, `MediaTimelineEvent`). A `MediaSessionSource`
/// reports whole states; `changes(since:)` turns two states into the events WE would send.
struct MediaSessionState: Equatable {
    /// `MediaPlaybackEvent.PLAYBACK_STOPPED/PLAYING/PAUSED`.
    enum Playback: Int {
        case stopped = 0, playing = 1, paused = 2
    }

    /// `MediaPropertiesEvent`. "Many applications only fill out the title and artist member."
    struct Properties: Equatable {
        var title = ""
        var artist = ""
        var subTitle = ""
        var albumTitle = ""
        var albumArtist = ""
        /// Separated by commas.
        var genres = ""
        /// "music", "video" or "image", the strings WE's media helper (`winrtutil64.exe`) makes of
        /// Windows' playback types (the typings' "audio or video" is loose); empty when unknown.
        var contentType = ""
    }

    /// `MediaThumbnailEvent`: `hasThumbnail` and the artwork's colours (`ArtworkPalette`).
    struct Thumbnail: Equatable {
        /// Identifies the artwork, so a new image with the same colours is still a change. Nil: none.
        var artwork: Int?
        /// Nil when there is no thumbnail; WE then sends black for every colour.
        var colors: ArtworkPalette.Colors?
        /// The artwork as PNG, for web wallpapers' `thumbnail` (a PNG data URL in WE).
        var png: Data?

        var hasThumbnail: Bool { colors != nil }
    }

    /// `MediaTimelineEvent`, in seconds. Only some players report it; a duration of 0 means none.
    struct Timeline: Equatable {
        var position: Double = 0
        var duration: Double = 0
    }

    /// One event, in WE's callback order (scenescript64.dll indices 14–18).
    enum Change: Equatable {
        case status(Bool)
        case playback(Playback)
        case properties(Properties)
        case thumbnail(Thumbnail)
        case timeline(Timeline)
    }

    /// `MediaStatusEvent.enabled`: whether media integration works at all.
    var enabled = false
    var playback = Playback.stopped
    var properties = Properties()
    var thumbnail = Thumbnail()
    var timeline = Timeline()

    /// The events for everything that differs from `previous`, in WE's order.
    func changes(since previous: MediaSessionState) -> [Change] {
        var changes: [Change] = []
        if enabled != previous.enabled { changes.append(.status(enabled)) }
        if playback != previous.playback { changes.append(.playback(playback)) }
        if properties != previous.properties { changes.append(.properties(properties)) }
        if thumbnail != previous.thumbnail { changes.append(.thumbnail(thumbnail)) }
        if timeline != previous.timeline { changes.append(.timeline(timeline)) }
        return changes
    }

    /// What WE sends a script right after its `init` (`wallpaper64.exe` `0x140172bdb`–`0x140172f16`):
    /// the status when enabled, the playback state unless stopped, the properties when there is a
    /// title, the thumbnail when there is one, and the timeline when it has a duration.
    var initialChanges: [Change] {
        var changes: [Change] = []
        if enabled { changes.append(.status(true)) }
        if playback != .stopped { changes.append(.playback(playback)) }
        if !properties.title.isEmpty { changes.append(.properties(properties)) }
        if thumbnail.hasThumbnail { changes.append(.thumbnail(thumbnail)) }
        if timeline.duration != 0 { changes.append(.timeline(timeline)) }
        return changes
    }
}
