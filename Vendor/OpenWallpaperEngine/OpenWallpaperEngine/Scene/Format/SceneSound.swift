import Foundation

/// A scene.json `sound` object, as wallpaper64.exe reads it: its property table (0x1401f7090) and
/// constructor (0x140190593, for an object whose `"sound"` is not null). Defaults are WE's for an
/// absent key. `volume` can be user-, script- or animation-bound like any object field.
///
/// Read but not played back: `muteineditor` (this app is no editor). `spatialization` places the
/// sound at its object (`SceneSoundSpatialization`).
struct WESceneSound: Decodable, Equatable {
    /// `playbackmode` (WE's table at 0x1401f7aa5: loop 0, random 1, single 2).
    enum PlaybackMode: String, Decodable, Equatable {
        case loop, random, single
    }

    /// `sound`: the files, relative to the wallpaper (a list, or one path). Each start picks one
    /// at random.
    var files: [String]
    var playbackMode: PlaybackMode = .loop
    /// `volume`, linear; WE squares it into the gain (`play()` 0x1401f59a3). Default 1.
    var volume: SceneRawValue?
    /// `mintime`/`maxtime`: in `random` mode, the pause after a clip is `mintime` plus a uniform
    /// share of `maxtime − mintime`. Defaults 1 and 5.
    var minTime: Double = 1
    var maxTime: Double = 5
    /// `startsilent`: nothing plays until a script calls `play()`.
    var startSilent = false
    var muteInEditor = false
    /// `spatialization` (flag bit 2 at +0x310, 0x14019bfa0): the sound plays from its object's
    /// position relative to the camera, attenuated by `attenuation` and `mindistance`.
    var spatialization = false
    /// `attenuation` (+0x304) and `mindistance` (+0x308): OpenAL's rolloff factor and reference
    /// distance for the sound's files (`play()` 0x1401f5858/0x1401f587b). Both default to 1
    /// (constructor 0x14019062a); either can be user-bound like `volume`.
    var attenuation: SceneRawValue?
    var minDistance: SceneRawValue?

    enum CodingKeys: String, CodingKey {
        case sound, playbackmode, volume, mintime, maxtime, startsilent, muteineditor, spatialization, attenuation
        case minDistance = "mindistance"
    }

    init(files: [String], playbackMode: PlaybackMode = .loop, volume: SceneRawValue? = nil, minTime: Double = 1,
         maxTime: Double = 5, startSilent: Bool = false, spatialization: Bool = false,
         attenuation: SceneRawValue? = nil, minDistance: SceneRawValue? = nil) {
        self.files = files
        self.playbackMode = playbackMode
        self.volume = volume
        self.minTime = minTime
        self.maxTime = maxTime
        self.startSilent = startSilent
        self.spatialization = spatialization
        self.attenuation = attenuation
        self.minDistance = minDistance
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A list; `createLayer('sounds/…')` makes the one-file form, a string (0x1816342a8).
        if let file = try? c.decode(String.self, forKey: .sound) { // optional: the list form is the usual one
            files = [file]
        } else {
            files = c.decodeElements(String.self, forKey: .sound, userInfo: decoder.userInfo) ?? []
        }
        if let mode = c.decodeLogged(String.self, forKey: .playbackmode, userInfo: decoder.userInfo) {
            if let known = PlaybackMode(rawValue: mode.lowercased()) {
                playbackMode = known
            } else {
                OWELog.error(.scene, "sound: unknown playbackmode '\(mode)', playing it as loop (WE's default)")
            }
        }
        volume = c.decodeLogged(SceneRawValue.self, forKey: .volume, userInfo: decoder.userInfo)
        minTime = c.decodeLogged(Double.self, forKey: .mintime, userInfo: decoder.userInfo) ?? 1
        maxTime = c.decodeLogged(Double.self, forKey: .maxtime, userInfo: decoder.userInfo) ?? 5
        startSilent = c.decodeLogged(Bool.self, forKey: .startsilent, userInfo: decoder.userInfo) ?? false
        muteInEditor = c.decodeLogged(Bool.self, forKey: .muteineditor, userInfo: decoder.userInfo) ?? false
        spatialization = c.decodeLogged(Bool.self, forKey: .spatialization, userInfo: decoder.userInfo) ?? false
        attenuation = c.decodeLogged(SceneRawValue.self, forKey: .attenuation, userInfo: decoder.userInfo)
        minDistance = c.decodeLogged(SceneRawValue.self, forKey: .minDistance, userInfo: decoder.userInfo)
    }
}
