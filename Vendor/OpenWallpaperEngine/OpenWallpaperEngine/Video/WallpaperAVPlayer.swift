import AVFoundation

/// The `AVPlayer`s behind a video wallpaper, on both the AVKit and the Metal path.
///
/// A wallpaper is decoration, not something being watched. `AVPlayer` by default holds a
/// `PreventUserIdleDisplaySleep` assertion for as long as it plays, even muted, so a playing video
/// wallpaper kept the displays awake all night, and the "displays asleep → pause" playback rule
/// (`DisplayPlaybackMonitor`) could never fire. Wallpaper Engine doesn't keep the display awake
/// either; the user's energy settings apply.
///
/// Its sound plays on the default output device without its inputs (`OutputOnlyAudioDevice`):
/// on a device that also records (a headset), the player's own output would make macOS ask for
/// the microphone and hold the main thread until the prompt is answered.
enum WallpaperAVPlayer {
    static func make(item: AVPlayerItem? = nil, output: OutputOnlyAudioDevice? = WallpaperServices.shared.soundOutput) -> AVPlayer {
        let player = AVPlayer(playerItem: item)
        player.preventsDisplaySleepDuringVideoPlayback = false
        if SceneBackendRuntimeContext.isActive { player.isMuted = true; player.volume = 0 }
        route(player, to: output)
        return player
    }

    /// Plays `player`'s sound on `output` (the default output device without its inputs), for
    /// players made elsewhere (an `AVQueuePlayer` behind an `AVPlayerLooper`). A muted player
    /// still opens its device, so muted ones are routed too.
    static func route(_ player: AVPlayer, to output: OutputOnlyAudioDevice? = WallpaperServices.shared.soundOutput) {
        if let output, output.deviceID != nil { player.audioOutputDeviceUniqueID = output.uid }
    }
}
