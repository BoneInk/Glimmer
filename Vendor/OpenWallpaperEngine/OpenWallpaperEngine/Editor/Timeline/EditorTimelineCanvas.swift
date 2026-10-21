import Foundation
import OWESceneEditing

/// The Wallpaper Editor's playhead on its canvas (editor-plan notes P4): while the timeline is
/// open, the canvas's scene clock is held (time-driven shaders, particles and scripts stand
/// still) and every property timeline shows the playhead's time; closing the timeline lets the
/// scene run again from there.
@MainActor
final class EditorTimelineCanvas {
    private let preview: WallpaperViewModel

    init(preview: WallpaperViewModel) {
        self.preview = preview
    }

    /// Shows `seconds` on the canvas, or with nil resumes it.
    func show(_ seconds: Double?) {
        let key = preview.instanceKey(for: preview.selectedScreenId)
        guard let instance = preview.sceneInstances.instance(for: key) else { return }
        let time = seconds.map { Float($0) }
        let renderLoop = instance.renderLoop
        renderLoop.perform { renderer in Self.apply(time, to: renderer) }
        // Thread boundary: main → render thread, as the instance wakes its pacing.
        renderLoop.thread.perform { renderLoop.wake(.smooth) }
    }

    /// On the render thread: holds the scene clock and pins the timelines at `time`, or lets go.
    nonisolated static func apply(_ time: Float?, to renderer: SceneMetalRenderer) {
        renderer.holdsClock = time != nil
        renderer.timelines.scrubTime = time
    }
}

extension SceneTimelineClock {
    /// The editor's playhead at `seconds`: the clock stands where its mode reaches that time
    /// (`TimelineCurve.clockTime`, the editor's own evaluation), going forward and not finished.
    mutating func scrub(to seconds: Float) {
        let mode: TimelineClip.Mode = flags.contains(.single) ? .single : flags.contains(.mirror) ? .mirror : .loop
        time = TimelineCurve.clockTime(atPlayhead: seconds, frameDuration: frameDuration, duration: duration, mode: mode)
        flags.subtract([.finished, .reversed])
    }
}
