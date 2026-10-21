import Combine
import CoreGraphics
import Foundation
import OWESceneEditing

/// The wallpaper's library thumbnail, made from the canvas as WE's snapshot tool makes it: Take
/// Snapshot draws the scene again offscreen, at the preview's size, into `preview.jpg`; Record GIF
/// draws it at a GIF format's rate for its length into `preview.gif`. The result waits for Use or
/// Discard; the one in use is written by File › Save (into a local wallpaper) or Save as New
/// Wallpaper. Without one, both keep the wallpaper's own preview.
@MainActor
public final class EditorThumbnail: ObservableObject {
    public enum Phase: Equatable {
        case idle
        /// Recording a GIF: the share of its frames drawn.
        case recording(Double)
        case encoding
    }

    @Published public private(set) var phase: Phase = .idle
    /// The last one made, waiting for Use or Discard.
    @Published public private(set) var pending: WallpaperThumbnail?
    /// The one Save and Save as New Wallpaper write; nil keeps the wallpaper's own.
    @Published public private(set) var chosen: WallpaperThumbnail?
    /// The GIF format Record GIF uses (WE's F key).
    @Published public var gifFormat: GIFRecordingFormat = GIFRecordingFormat.all[0]
    /// Why the last capture failed, for the window's banner; cleared when shown.
    @Published public var problem: String?

    /// The scene's size, whose centre square the thumbnail shows.
    public let sceneSize: SIMD2<Double>
    /// File › Save writes the thumbnail into the wallpaper (a local one); else only Save as New
    /// Wallpaper does.
    public let savesInPlace: Bool
    /// The chosen thumbnail changed (the app's document state counts it as unsaved).
    public var onChosenChange: (() -> Void)?

    /// The canvas's scene drawn again, offscreen, at a pixel size (the app's renderer); nil when it
    /// has nothing to draw.
    private let frame: @MainActor (SIMD2<Int>) async -> CGImage?
    private let sleep: (Double) async -> Void

    public init(sceneSize: SIMD2<Double>, savesInPlace: Bool, frame: @escaping @MainActor (SIMD2<Int>) async -> CGImage?,
                sleep: @escaping (Double) async -> Void = { try? await Task.sleep(nanoseconds: UInt64(max($0, 0) * 1e9)) }) {
        self.sceneSize = sceneSize
        self.savesInPlace = savesInPlace
        self.frame = frame
        self.sleep = sleep
    }

    public var isBusy: Bool { phase != .idle }

    /// Take Snapshot: the scene's centre square at WE's snapshot size.
    public func takeSnapshot() async {
        guard !isBusy else { return }
        phase = .encoding
        defer { phase = .idle }
        let side = WallpaperThumbnail.snapshotSide(sceneSize: sceneSize)
        guard let image = await frame(WallpaperThumbnail.renderSize(side: side, sceneSize: sceneSize)) else {
            return fail()
        }
        do {
            pending = try await Task.detached(priority: .userInitiated) { try ThumbnailEncoder.snapshot(image, side: side) }.value
        } catch {
            fail()
        }
    }

    /// Record GIF: `gifFormat`'s frames, drawn at its rate as the scene plays, then encoded.
    public func recordGIF() async {
        guard !isBusy else { return }
        let format = gifFormat
        let size = WallpaperThumbnail.renderSize(side: format.side, sceneSize: sceneSize)
        let interval = 1 / Double(format.framesPerSecond)
        var frames: [CGImage] = []
        phase = .recording(0)
        defer { phase = .idle }
        let start = Date()
        for index in 0..<format.frameCount {
            guard let image = await frame(size) else { return fail() }
            frames.append(image)
            phase = .recording(Double(index + 1) / Double(format.frameCount))
            // The next frame at its time on the scene's clock, which runs on while frames are drawn.
            let due = Double(index + 1) * interval - Date().timeIntervalSince(start)
            if due > 0 { await sleep(due) }
        }
        phase = .encoding
        let captured = frames
        do {
            pending = try await Task.detached(priority: .userInitiated) { try ThumbnailEncoder.gif(captured, format: format) }.value
        } catch {
            fail()
        }
    }

    /// Use: the pending thumbnail is the one Save writes.
    public func use() {
        guard let pending else { return }
        chosen = pending
        self.pending = nil
        onChosenChange?()
    }

    public func discard() {
        pending = nil
    }

    /// Keep the Original Thumbnail: nothing the editor made is written.
    public func keepOriginal() {
        guard chosen != nil else { return }
        chosen = nil
        onChosenChange?()
    }

    /// File › Save wrote the chosen thumbnail into the wallpaper: it is the wallpaper's own now.
    public func didSaveInPlace() {
        guard chosen != nil else { return }
        chosen = nil
        onChosenChange?()
    }

    private func fail() {
        problem = TH("The thumbnail couldn’t be made.")
    }
}
