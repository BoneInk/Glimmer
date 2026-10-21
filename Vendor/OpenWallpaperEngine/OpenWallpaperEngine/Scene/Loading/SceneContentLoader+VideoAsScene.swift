//
//  SceneContentLoader+VideoAsScene.swift
//  Open Wallpaper Engine
//
//  A video wallpaper as a one-layer scene, and its playback.
//

import SwiftUI
import CoreText
import CryptoKit
import OWESceneEditing

extension SceneContentLoader {
    // MARK: - Video as a scene

    /// Wraps a video wallpaper in a one-layer scene so the effect stack applies to it, the way
    /// Wallpaper Engine's own `scenes/videoplayer` does.
    func videoContent() -> SceneMetalContent? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        // Runs on the content queue: a video AVFoundation refuses as it is plays from its repaired
        // copy, made here on first play when the import didn't make it.
        let url = videoStream == nil ? RepairedVideoCache.current.playableURL(for: currentWallpaper.mediaURL) : currentWallpaper.mediaURL
        let dynamicRange = videoDynamicRange(of: url)
        // The stream decodes for one range: a change of the setting reopens it.
        if let videoStream, videoStream.dynamicRange != dynamicRange {
            videoStream.stop()
            self.videoStream = nil
        }
        let stream = videoStream ?? VideoTextureStream(file: VideoFileSource(url: url, mode: renderSettings.videoReadMode),
                                                       device: device, dynamicRange: dynamicRange)
        guard let stream else {
            OWELog.error(.scene, "Could not open video \(url.lastPathComponent) for Metal playback")
            return nil
        }
        videoStream = stream

        // The display size is unknown here, so the scene is the video's own size and the renderer's
        // placement handles fitting. `keepaspect` then costs nothing: the layer fills its scene.
        let sceneSize = stream.frameSize
        builtVideoFrameSize = sceneSize
        let wallpaper = currentWallpaper
        let musicSync = VideoMusicSyncVisuals(
            zoomAmount: VideoMusicSyncSettings.bool(wallpaper, "zoomEnabled")
                ? Float(VideoMusicSyncSettings.double(wallpaper, "zoomAmount", default: 0.08)) : 0,
            tiltAmount: VideoMusicSyncSettings.bool(wallpaper, "tiltEnabled")
                ? Float(VideoMusicSyncSettings.double(wallpaper, "tiltAmount", default: 3)) : 0,
            saturationAmount: VideoMusicSyncSettings.bool(wallpaper, "saturationEnabled")
                ? Float(VideoMusicSyncSettings.double(wallpaper, "saturationAmount", default: 0.6)) : 0,
            levelSource: { [weak stream] in
                stream?.musicSyncLevel ?? WallpaperServices.shared.audioLevel
            })

        var layer = SceneMetalLayer(
            id: "video", name: "video", source: .video(stream),
            position: sceneSize / 2, size: sceneSize,
            scale: SIMD2<Float>(repeating: 1),
            opacity: 1,
            brightness: 1, color: SIMD4<Float>(repeating: 1), text: nil, parallaxDepth: .zero, perspective: false,
            rotation: 0)
        layer.musicSync = musicSync
        var content = SceneMetalContent(size: sceneSize, layers: [layer], particleSystems: [],
                                        bloom: SceneBloomSettings(enabled: false, strength: 0, threshold: 0.7,
                                                                  tint: SIMD3<Float>(repeating: 1)))
        if stream.dynamicRange.isHDR {
            // WE 2.8's HDR video: a float frame of linear light, finished by `combine_video_hdr`.
            sceneEngineCombos = SceneEngineCombos(hdr: true)
            content.engineCombos = sceneEngineCombos
            content.hdrChain = engineChain("WE's HDR video combine", wallpaperDir: currentWallpaper.wallpaperDirectory,
                                           SceneHDRChain.build)
            content.videoHDR = true
        }
        return content
    }

    /// The range the Metal path decodes `url` in: its own when it is HDR and the post-processing
    /// setting is "Ultra (Display HDR)", WE 2.8's condition for a HDR video (a HDR swap chain);
    /// SDR otherwise, the 8-bit path at its usual cost. The settings offer display HDR only where a
    /// display can show it (`DisplayHDRSupport`).
    private func videoDynamicRange(of url: URL) -> VideoDynamicRange {
        guard renderSettings.postProcessing == .displayhdr else { return .sdr }
        if let known = videoRangeByURL, known.url == url { return known.range }
        let range = VideoDynamicRange.of(url)
        videoRangeByURL = (url, range)
        return range
    }

    /// Plays or pauses every scene image's video texture with the wallpaper: 0 while it is
    /// paused, covered or frozen, so their decoders stop as a video wallpaper's does.
    func setEmbeddedVideoRate(_ rate: Float) {
        embeddedVideoLock.withLock {
            embeddedVideoRate = rate
            for stream in embeddedVideoStreams.allObjects { stream.setHostRate(rate) }
        }
    }

    /// Drives playback for the Metal video path; the AVKit path owns its own players.
    func updateVideoPlayback(playRate: Float, audioRate: Float, audioLevel: Double,
                             audioEnabled: Bool, volume: Float) {
        guard let stream = videoStream else { return }
        stream.setAudio(enabled: audioEnabled, volume: volume)
        let pace = VideoMusicSyncSettings.bool(currentWallpaper, "paceEnabled")
            ? VideoMusicSyncSettings.double(currentWallpaper, "paceAmount", default: 0.25)
            : 0
        stream.update(playRate: playRate, audioRate: audioRate,
                      audioLevel: stream.musicSyncLevel, paceAmount: pace)

        // The first frame decodes seconds after the layer is built, so the scene starts at the
        // placeholder size and would keep the wrong aspect ratio without a rebuild.
        if let built = builtVideoFrameSize, built != stream.frameSize {
            builtVideoFrameSize = stream.frameSize
            bumpRevision()
        }
    }
}
