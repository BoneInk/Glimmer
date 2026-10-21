import CoreGraphics
import Foundation
import OWETheming

/// Keeps each display's system desktop picture, which the lock screen and the menu bar's tint
/// show, a picture of what the display shows (`DesktopPicturePlan`): a scene's loading snapshot,
/// a video's frame, a web page's snapshot, or until there is one the wallpaper's preview, never a
/// stale or missing file. Each picture is OWE's own copy (`LockScreenPicture`), so no cache trim
/// removes a picture in use.
///
/// - **When.** `update` with the displays' plans whenever the wallpapers, the layout, the display
///   options or a picture's source change (`DesktopPictureController`). A display whose plan and
///   sources are unchanged writes nothing.
/// - **Spaces, wake, reconnection.** macOS sets a picture on the current Space only, and may
///   reset it; `reassert` shows each display's current picture again where something else shows.
/// - **Work.** Sources are looked up, decoded and drawn off the main thread, one update at a time;
///   a plain display (one frame at its own size) copies its snapshot without decoding it.
/// - **Theming.** With Settings › Theming › Menu Bar on, each display's picture gets its menu bar
///   strip in the scheme colour (`DesktopPictureTheming`), drawn over the composed picture; the
///   strip is part of the picture's signature, so a new colour draws the pictures again.
@MainActor
final class DesktopPictureSync {
    struct Shown: Equatable {
        var url: URL
        var signature: String
    }

    let setter: DesktopPictureSetting
    let files: LockScreenPicture
    /// False: the pictures are only written, for the screen saver's stills
    /// (`DesktopPictureController`'s screen-saver-only mode, with the lock-screen picture and the
    /// menu bar tint off): no display's desktop picture is ever set, recorded or restored.
    let setsPictures: Bool
    /// A display's new picture was written and set: the screen saver keeps it as its still
    /// (`ScreenSaverStillPublisher`).
    var onPictureWritten: ((URL, CGDirectDisplayID) -> Void)?
    let loader: DisplayPictureLoader
    /// Each display's picture as last set, and what it was drawn from.
    private(set) var shown: [CGDirectDisplayID: Shown] = [:]
    /// The latest snapshot of each web wallpaper's page, by folder path.
    private var webFrames: [String: CGImage] = [:]
    private var running = false
    private var pending: (plans: [DesktopPicturePlan], placement: WallpaperPlacement, strips: DesktopPictureStrips?)?

    init(setter: DesktopPictureSetting, files: LockScreenPicture, loader: DisplayPictureLoader, setsPictures: Bool = true) {
        self.setter = setter
        self.files = files
        self.loader = loader
        self.setsPictures = setsPictures
    }

    /// A web wallpaper's page drew `image`: its displays' pictures use it from the next update.
    func webFrameCaptured(_ image: CGImage, wallpaperDirectory: URL) {
        webFrames[Self.key(wallpaperDirectory)] = image
    }

    /// Brings each planned display's picture up to date. An update asked for while one runs runs
    /// after it, with the latest plans only. `strips` are theming's menu bar strips, if any.
    func update(_ plans: [DesktopPicturePlan], placement: WallpaperPlacement,
                strips: DesktopPictureStrips? = nil) async {
        pending = (plans, placement, strips)
        guard !running else { return }
        running = true
        while let next = pending {
            pending = nil
            await run(next.plans, placement: next.placement, strips: next.strips)
        }
        running = false
    }

    /// Shows each display's current picture again where its current Space shows another (a new
    /// Space, a wake, a reconnection). Returns the displays with no picture to show yet.
    @discardableResult
    func reassert(_ displays: [CGDirectDisplayID]) -> [CGDirectDisplayID] {
        guard setsPictures else { return [] }
        var missing: [CGDirectDisplayID] = []
        for display in displays {
            guard let current = shown[display], LockScreenPicture.fileExists(current.url) else {
                missing.append(display)
                continue
            }
            let showing = setter.picture(for: display)
            guard showing?.standardizedFileURL != current.url.standardizedFileURL else { continue }
            set(current.url, display: display, showing: showing, reason: "shown again")
        }
        return missing
    }

    /// Puts the user's own pictures back on `displays` where one of OWE's shows (`restorePlan`),
    /// and forgets them and what was shown there.
    func restoreUsersPictures(_ displays: [CGDirectDisplayID], fallback: URL?) {
        guard setsPictures else { return }
        var showing: [CGDirectDisplayID: URL?] = [:]
        for display in displays { showing[display] = setter.picture(for: display) }
        for (display, original) in files.restorePlan(showing: showing, fallback: fallback) {
            do {
                try setter.setPicture(original, for: display, ownPicture: false)
                OWELog.info(.app, "Desktop picture of display \(display): the user's \(original.lastPathComponent) again")
            } catch {
                OWELog.error(.app, "Desktop picture of display \(display): restoring the user's picture failed: \(error)")
            }
        }
        files.forgetOriginals(of: displays)
        for display in displays { shown[display] = nil }
    }

    // MARK: Updating

    private struct Job: Sendable {
        var plan: DesktopPicturePlan
        var showing: URL?
        var previous: Shown?
        var webFrames: [String: CGImage]
        var strips: DesktopPictureStrips?
    }

    private enum Outcome: Sendable {
        case written(URL, signature: String)
        case unchanged
        case failed
    }

    private func run(_ plans: [DesktopPicturePlan], placement: WallpaperPlacement, strips: DesktopPictureStrips?) async {
        let jobs = plans.map { plan in
            Job(plan: plan, showing: setsPictures ? setter.picture(for: plan.display) : shown[plan.display]?.url,
                previous: shown[plan.display],
                webFrames: webFrames.filter { key, _ in plan.layers.contains { Self.key($0.wallpaperDirectory) == key } },
                strips: strips)
        }
        let files = files
        let loader = loader
        let outcomes = await Task.detached(priority: .utility) {
            var outcomes: [Outcome] = []
            for job in jobs { outcomes.append(await Self.render(job, placement: placement, files: files, loader: loader)) }
            return outcomes
        }.value
        for (job, outcome) in zip(jobs, outcomes) {
            switch outcome {
            case .written(let url, let signature):
                if setsPictures {
                    set(url, display: job.plan.display, showing: setter.picture(for: job.plan.display), reason: "updated")
                }
                shown[job.plan.display] = Shown(url: url, signature: signature)
                onPictureWritten?(url, job.plan.display)
            case .unchanged:
                if setsPictures { reassert([job.plan.display]) }
            case .failed:
                break
            }
        }
        // Pages no display shows any more.
        let shownFolders = Set(plans.flatMap { $0.layers.map { Self.key($0.wallpaperDirectory) } })
        webFrames = webFrames.filter { shownFolders.contains($0.key) }
    }

    private func set(_ url: URL, display: CGDirectDisplayID, showing: URL?, reason: String) {
        files.recordOriginal(showing, display: display)
        do {
            try setter.setPicture(url, for: display, ownPicture: true)
            OWELog.info(.app, "Desktop picture of display \(display): \(url.lastPathComponent) (\(reason))")
        } catch {
            OWELog.error(.app, "Desktop picture of display \(display): setting \(url.lastPathComponent) failed: \(error)")
        }
    }

    private nonisolated static func key(_ directory: URL) -> String { directory.standardizedFileURL.path(percentEncoded: false) }

    // MARK: Rendering (background)

    private enum LayerSource {
        case file(URL, placement: WallpaperPlacement, exactSnapshot: Bool)
        case image(CGImage)
        case none

        var signature: String {
            switch self {
            case .file(let url, let placement, _):
                // A rewritten file is a new file (writes are atomic); the modification date is
                // the snapshot store's last use.
                let values = try? url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey]) // Optional: part of the key only.
                let created = values?.creationDate?.timeIntervalSinceReferenceDate ?? 0
                return "\(url.path(percentEncoded: false))|\(created)|\(values?.fileSize ?? 0)|\(placement.rawValue)"
            case .image(let image):
                return "page:\(UInt(bitPattern: Unmanaged.passUnretained(image).toOpaque()))"
            case .none:
                return "none"
            }
        }
    }

    private nonisolated static func render(_ job: Job, placement: WallpaperPlacement, files: LockScreenPicture,
                                           loader: DisplayPictureLoader) async -> Outcome {
        let plan = job.plan
        var sources: [LayerSource] = []
        for layer in plan.layers {
            if layer.type.caseInsensitiveCompare("web") == .orderedSame, let page = job.webFrames[key(layer.wallpaperDirectory)] {
                sources.append(.image(page))
                continue
            }
            let request = DisplayPictureLoader.Request(
                wallpaperDirectory: layer.wallpaperDirectory, type: layer.type, mediaURL: layer.mediaURL,
                preview: layer.preview, displayPixelSize: layer.framePixelSize, frame: .zero, scale: 1,
                placement: placement)
            let source = await loader.source(for: request)
            if case .snapshot = source, let url = source.url {
                sources.append(.file(url, placement: .fill, exactSnapshot: true))
            } else if let url = source.url {
                sources.append(.file(url, placement: source.placement(placement), exactSnapshot: false))
            } else {
                sources.append(.none)
            }
        }
        let signature = "\(plan)|" + sources.map(\.signature).joined(separator: ";")
            + DesktopPictureTheming.signature(job.strips, display: plan.display)
        let hasStrip = job.strips?.displays[plan.display] != nil
        if let previous = job.previous, previous.signature == signature, LockScreenPicture.fileExists(previous.url) {
            return .unchanged
        }
        do {
            if plan.isPlain, !hasStrip, case .file(let url, _, true) = sources.first {
                return .written(try files.write(snapshot: url, display: plan.display, showing: job.showing), signature: signature)
            }
            let images = zip(plan.layers, sources).map { layer, source -> DesktopPictureComposer.Source? in
                switch source {
                case .image(let image):
                    return DesktopPictureComposer.Source(image: image, placement: .fill)
                case .file(let url, let placement, _):
                    let canvas = DesktopPictureComposer.denormalized(
                        layer.canvas, CGSize(width: plan.pixelSize.x, height: plan.pixelSize.y)).size
                    return DisplayPictureLoader.decode(url, frame: canvas, placement: placement, scale: 1)
                        .map { DesktopPictureComposer.Source(image: $0, placement: placement) }
                case .none:
                    return nil
                }
            }
            guard let composed = DesktopPictureComposer.compose(plan, sources: images),
                  let (data, fileExtension) = SceneLoadingSnapshotStore.encoded(
                      DesktopPictureTheming.draw(job.strips, over: composed, display: plan.display)) else {
                OWELog.error(.app, "Desktop picture of display \(plan.display) could not be drawn")
                return .failed
            }
            let url = try files.write(data, fileExtension: fileExtension, display: plan.display, showing: job.showing)
            return .written(url, signature: signature)
        } catch {
            OWELog.error(.app, "Desktop picture of display \(plan.display) could not be written: \(error)")
            return .failed
        }
    }
}
