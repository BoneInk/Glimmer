import AppKit
import Metal
import QuartzCore

/// Plays WE's transitions on the wallpaper windows: a playlist's between its wallpapers, and
/// Settings' "Transition" for a wallpaper chosen in the library (WE's "Wallpaper browser
/// transition", `browsetransition`).
///
/// A change with a transition first captures what each changing wallpaper shows
/// (`WallpaperTransitionCapture`), then applies the change and lays the transition over the
/// incoming wallpapers, which run live underneath: one render per changing wallpaper, shown by
/// every display that shows it (`WallpaperTransitionGeometry`). The outgoing wallpaper stops as
/// soon as its picture is captured, as it would without a transition; only that picture and the
/// frames stay until the transition ends.
@MainActor
final class WallpaperTransitionCoordinator: WallpaperTransitionPerforming {
    private unowned let wallpapers: WallpaperViewModel
    private let settings: () -> WallpaperTransitionSettings
    /// The wallpaper windows, by display.
    private let windows: () -> [String: NSWindow]
    private let device: MTLDevice?
    private lazy var renderer: WallpaperTransitionRenderer? = makeRenderer()
    private lazy var queue: MTLCommandQueue? = device?.makeCommandQueue()

    /// A change waiting for its captures.
    private struct Pending {
        let id: UUID
        let apply: @MainActor () -> Void
    }
    private var pending: Pending?
    /// The transitions playing now.
    private(set) var players: [WallpaperTransitionPlayer] = []

    init(wallpapers: WallpaperViewModel, settings: @escaping () -> WallpaperTransitionSettings,
         windows: @escaping () -> [String: NSWindow], device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        self.wallpapers = wallpapers
        self.settings = settings
        self.windows = windows
        self.device = device
    }

    var manualSettings: WallpaperTransitionSettings { settings() }

    /// Whether a change is waiting for its captures.
    var isCapturing: Bool { pending != nil }

    func flushPending() {
        guard let pending else { return }
        self.pending = nil
        pending.apply()
    }

    func perform(_ kind: WallpaperTransitionKind, duration: TimeInterval, on screens: Set<String>,
                 apply: @escaping @MainActor () -> Void) {
        flushPending()
        let windows = windows()
        let resolution = wallpapers.layoutResolution
        let geometries = screens.sorted().compactMap { target in
            WallpaperTransitionGeometry.make(
                target: target, windowIds: Set(windows.keys), resolution: resolution,
                frame: { [wallpapers] in wallpapers.displayRect(of: $0) },
                scale: { windows[$0]?.backingScaleFactor ?? 1 })
        }
        guard let renderer, let queue, !geometries.isEmpty else {
            apply()
            return
        }
        let id = UUID()
        pending = Pending(id: id, apply: apply)
        // WE's transition clock starts when the change asks for it, its setup included.
        let requested = CACurrentMediaTime()
        Task { @MainActor [weak self] in
            await self?.start(id: id, kind: kind, duration: duration, requested: requested, geometries: geometries,
                              windows: windows, renderer: renderer, queue: queue)
        }
    }

    private func start(id: UUID, kind: WallpaperTransitionKind, duration: TimeInterval, requested: CFTimeInterval,
                       geometries: [WallpaperTransitionGeometry], windows: [String: NSWindow],
                       renderer: WallpaperTransitionRenderer, queue: MTLCommandQueue) async {
        // The pipeline compiles off the main thread while the pictures are captured.
        let prepared = Task.detached(priority: .userInitiated) { () -> Error? in
            do {
                try renderer.preparePipelines(for: kind, pixelFormat: .bgra8Unorm)
                return nil
            } catch {
                return error
            }
        }
        var captures: [(WallpaperTransitionGeometry, MTLTexture)] = []
        for geometry in geometries {
            let window = windows[geometry.captureWindowId]
            let texture = await WallpaperTransitionCapture.withTimeout { [wallpapers, renderer] in
                await WallpaperTransitionCapture.capture(
                    screenId: geometry.target, pixelSize: geometry.pixelSize, backingScale: geometry.backingScale,
                    wallpapers: wallpapers, window: window, device: renderer.device)
            }
            if let texture { captures.append((geometry, texture)) }
        }
        let failure = await prepared.value
        // Another change came first and applied this one already: no transition for it.
        guard let change = pending, change.id == id else { return }
        pending = nil
        if let failure {
            OWELog.error(.app, "Transition \(kind) can't be drawn: \(failure)")
            captures = []
        }
        if captures.isEmpty { OWELog.info(.app, "Transition \(kind): nothing to capture; changing without it") }
        var started: [WallpaperTransitionPlayer] = []
        for (geometry, texture) in captures {
            stopPlayers(on: geometry.target)
            let overlays = geometry.members.compactMap { member -> WallpaperTransitionOverlayView? in
                guard let host = Self.overlayHost(in: windows[member.windowId]) else { return nil }
                let overlay = WallpaperTransitionOverlayView(frame: member.frame, contentsRect: member.contentsRect)
                host.addSubview(overlay, positioned: .above, relativeTo: nil)
                return overlay
            }
            do {
                let player = try WallpaperTransitionPlayer(
                    kind: kind, duration: duration, target: geometry.target, outgoing: texture,
                    pixelSize: geometry.pixelSize, renderer: renderer, queue: queue, startTime: requested,
                    overlays: overlays)
                do {
                    try player.showFirstFrame()
                } catch {
                    player.stop()
                    throw error
                }
                started.append(player)
            } catch {
                OWELog.error(.app, "Transition \(kind) on \(geometry.target) can't start: \(error)")
                for overlay in overlays { overlay.removeFromSuperview() }
            }
        }
        // The overlays show the outgoing pictures: the wallpapers change under them.
        change.apply()
        players += started
        for player in started {
            player.run { [weak self] finished in self?.players.removeAll { $0 === finished } }
        }
    }

    /// Stops what plays on `target`: a new change there starts from what shows under it.
    private func stopPlayers(on target: String) {
        for player in players where player.target == target { player.stop() }
    }

    /// Where a window's overlays go: the display options' transform view, with the wallpaper's view.
    static func overlayHost(in window: NSWindow?) -> NSView? {
        guard let content = window?.contentView as? WallpaperWindowContentView else { return nil }
        return content.content
    }

    private func makeRenderer() -> WallpaperTransitionRenderer? {
        guard let device else {
            OWELog.error(.app, "Transitions: no Metal device")
            return nil
        }
        do {
            return try WallpaperTransitionRenderer(device: device)
        } catch {
            OWELog.error(.app, "Transitions: the renderer can't start: \(error)")
            return nil
        }
    }
}
