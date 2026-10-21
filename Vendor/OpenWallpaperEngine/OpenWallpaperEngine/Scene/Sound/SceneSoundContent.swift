import Foundation

/// A sound layer ready to play: its scene.json object, the wallpaper's copy of each file it could
/// open with its length and channels, and its `volume`, `attenuation` and `mindistance` with user
/// bindings resolved.
struct SceneSoundContent: Equatable {
    struct File: Equatable {
        /// The path scene.json names.
        var path: String
        var url: URL
        /// Seconds.
        var duration: Double
        /// The channels it decodes to. Only a mono file is spatialized, as OpenAL Soft places only
        /// mono sources (`SceneSoundSpatialization`).
        var channels = 2
    }

    var id: Int
    var name: String
    var sound: WESceneSound
    var files: [File]
    var volume: Float
    /// `attenuation` and `mindistance`, WE's defaults 1 (`WESceneSound`).
    var attenuation: Float = 1
    var minDistance: Float = 1
}
