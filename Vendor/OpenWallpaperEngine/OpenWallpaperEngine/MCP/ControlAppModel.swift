import Foundation
import OWEControlProtocol

/// What the control channel can see and change in the app (`ControlRequestRouter`): the real app
/// (`AppControlModel`), or a fake in tests. Every call is on the main actor, as the app's models are.
@MainActor
protocol ControlAppModel: AnyObject {
    func displays() -> [ControlDisplay]
    /// The library as the Installed tab lists it, before search and filters.
    func wallpapers() -> [ControlWallpaper]
    func wallpaper(onDisplay id: String) -> ControlWallpaper?
    /// The wallpaper's user properties, as its Details panel lists them, with their current values.
    func properties(of wallpaper: ControlWallpaper) -> [ControlUserProperty]
    var playback: ControlPlayback { get }
    func playlists() -> [ControlPlaylist]

    func setWallpaper(_ wallpaper: ControlWallpaper, displays: [String]) throws
    /// false resumes from a stop too, as Resume in the menu bar does.
    func setPaused(_ paused: Bool)
    /// Stops every wallpaper, as Stop Wallpapers in the menu bar does.
    func stop()
    func setVolume(_ volume: Double)
    func setMuted(_ muted: Bool)
    /// Sets one property's value (already checked against its type) on the stores of the displays
    /// showing the wallpaper, applied live; returns those stores' names.
    func setUserProperty(_ key: String, to value: String, of wallpaper: ControlWallpaper) -> [String]
    func playPlaylist(_ playlist: ControlPlaylist, displays: [String])
    /// Next or Previous Wallpaper on `displays`; returns what each display shows after.
    func step(forward: Bool, displays: [String]) -> [String: ControlWallpaper?]
    func importWallpapers(at url: URL) async throws -> ControlImportResult
    func openEditor(_ editor: ControlEditor, for wallpaper: ControlWallpaper) throws
    func snapshot(display: String) async throws -> ControlSnapshot
}

struct ControlDisplay: Equatable {
    var id: String
    var name: String
    var isMain: Bool
    /// Wallpapers are shown on it (Display Settings).
    var isEnabled: Bool
    var width: Int
    var height: Int
    var scale: Double
    /// Settings › Performance › Playback's state for it: run, mute, pause or stop.
    var rule: String
}

struct ControlWallpaper: Equatable {
    /// The folder's name, which the library keys wallpapers by.
    var id: String
    var title: String
    var type: String
    var tags: [String]
    var folder: URL
    var workshopID: String?
    var description: String?
    var contentRating: String?
}

struct ControlUserProperty: Equatable {
    struct Option: Equatable {
        var label: String
        var value: String
    }

    var key: String
    var title: String
    var type: String
    var value: String
    var defaultValue: String
    var minimum: Double
    var maximum: Double
    var step: Double?
    var fraction: Bool
    var editable: Bool
    var options: [Option]
    /// project.json's condition; nil when always shown.
    var condition: String?
}

struct ControlPlayback: Equatable {
    var paused: Bool
    /// 0…1; 0 is muted, as Mute in the menu bar does it.
    var volume: Double
    /// Stopped by the user (Stop Wallpapers): nothing is loaded until resumed.
    var stopped = false
}

struct ControlPlaylist: Equatable {
    var id: UUID
    var name: String
    var wallpapers: [ControlWallpaper]
    /// Seconds each wallpaper shows.
    var duration: Double
    var isActive: Bool
    /// The active playlist rotates by itself.
    var isRotating: Bool
    var shuffles: Bool
    /// The displays it last played on.
    var displays: [String]
}

struct ControlImportResult: Equatable {
    var imported: [ControlWallpaper]
    var skipped: [(path: String, reason: String)]

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.imported == rhs.imported && lhs.skipped.map(\.path) == rhs.skipped.map(\.path)
            && lhs.skipped.map(\.reason) == rhs.skipped.map(\.reason)
    }
}

enum ControlEditor: String {
    case scene
    case wallpaper
}

struct ControlSnapshot {
    var display: String
    var wallpaper: ControlWallpaper?
    /// What the picture is: `loading_snapshot` (the scene's own frame), `video_frame` or `preview`.
    var source: String
    var png: Data
    var width: Int
    var height: Int
}
