import AppKit

extension ScreenSaverPlugin {
    /// A loop of the screen saver's layout the app draws live: a scene wallpaper, a video wallpaper
    /// AVFoundation plays (`ScreenSaverLiveVideo`), or a web page or a WebM video through the
    /// Chromium engine (`ScreenSaverLiveWeb`) when it is installed, at the largest of its displays'
    /// sizes (a stretch's canvas), with the properties its first display runs it with.
    struct LiveLoop {
        enum Kind: Equatable {
            case scene
            case video
            case page(ScreenSaverLiveWeb.Kind)
        }

        var kind: Kind
        var wallpaper: WEWallpaper
        var propertyScope: WallpaperPropertyScope
        var loop: ScreenSaverLayoutPlan.Loop
        var pixels: SIMD2<Int>
        var points: SIMD2<Int>
        /// The display it is paced by (its first).
        var screenId: String?
        /// The wallpaper picked as the screen saver, not the desktop's.
        var isPick = false
    }

    /// The isolated store the picked wallpaper is drawn with: the screen saver's own values for
    /// it (Scene Edit / Export's Screen Saver mode, `ScreenSaverSettingsStore`), never the desktop's.
    static let pickScope = WallpaperPropertyScope.isolated("screen-saver-live")

    /// What draws `wallpaper` live, nil when nothing can: a scene, a video AVFoundation plays, or a
    /// page (a web wallpaper, a WebM video AVFoundation can't play) while the Chromium engine is
    /// installed.
    nonisolated static func liveKind(of wallpaper: WEWallpaper, chromiumInstalled: Bool) -> LiveLoop.Kind? {
        if isScene(wallpaper) { return .scene }
        if ScreenSaverVideoSource.isEligible(wallpaper) { return .video }
        guard chromiumInstalled else { return nil }
        if isWeb(wallpaper) { return .page(.web) }
        if isWebMVideo(wallpaper), WebKitVideoPlayer.handles(wallpaper.mediaURL) {
            return .page(.webm)
        }
        return nil
    }

    /// The loops of the screen saver's layout drawn live now, and every planned display's identity:
    /// the picked wallpaper on every display (`livePick`), else the desktop's layout while the
    /// saver follows it (`followsDesktop`).
    func liveLoops() -> (loops: [LiveLoop], displays: [String]) {
        if let pick = livePick { return pickLoops(pick) }
        guard followsDesktop, let viewModel else { return ([], []) }
        let (plan, wallpapers) = currentPlan(fallback: nil)
        let screens = Dictionary(viewModel.connectedDisplays().map { ($0.identity, $0.screenId) }, uniquingKeysWith: { first, _ in first })
        var loops: [LiveLoop] = []
        let chromiumInstalled = ChromiumEngineInstaller.hasActiveInstall
        for loop in plan.loops {
            guard let wallpaper = wallpapers[loop.content.id],
                  let kind = Self.liveKind(of: wallpaper, chromiumInstalled: chromiumInstalled),
                  let pixels = loop.sizes.map(\.pixels).max(by: { $0.x * $0.y < $1.x * $1.y }),
                  let points = loop.sizes.map(\.points).max(by: { $0.x * $0.y < $1.x * $1.y }) else { continue }
            let screenId = loop.displays.first.flatMap { screens[$0] }
            let scope = screenId.map { viewModel.instanceKey(for: $0).properties } ?? .shared
            loops.append(LiveLoop(kind: kind, wallpaper: wallpaper, propertyScope: scope, loop: loop, pixels: pixels, points: points,
                                  screenId: screenId))
        }
        return (loops, plan.displays)
    }

    /// The live manifest's display entries for `loops` (ring `i` is `loops[i]`): one for any
    /// display when a whole loop plays on every display, else one per display, with its crop for
    /// a stretch. Displays not listed show their still.
    nonisolated static func liveDisplayEntries(_ loops: [ScreenSaverLayoutPlan.Loop], pixels: [SIMD2<Int>],
                                               displays: [String]) -> [ScreenSaverFramePublisher.DisplayEntry] {
        var entries: [ScreenSaverFramePublisher.DisplayEntry] = []
        for (ring, loop) in loops.enumerated() {
            if let canvas = loop.canvas, ring < pixels.count {
                let size = CGSize(width: pixels[ring].x, height: pixels[ring].y)
                for display in loop.displays {
                    guard let unit = loop.crops[display] else { continue }
                    entries.append(.init(display: display, ring: ring,
                                         crop: ScreenSaverManifest.Crop(unit, canvas: canvas.size, video: size)))
                }
            } else if !displays.isEmpty, Set(displays).isSubset(of: loop.displays) {
                entries.append(.init(display: nil, ring: ring))
            } else {
                entries += loop.displays.map { .init(display: $0, ring: ring) }
            }
        }
        return entries
    }

    /// The picked wallpaper as one loop on every display, at the largest display's size, paced by
    /// that display, with the screen saver's values for it published in `pickScope`.
    private func pickLoops(_ wallpaper: WEWallpaper) -> (loops: [LiveLoop], displays: [String]) {
        guard let kind = Self.liveKind(of: wallpaper, chromiumInstalled: ChromiumEngineInstaller.hasActiveInstall) else {
            return ([], [])
        }
        let displays = DisplayIdentity.connected()
        let screens = Dictionary(NSScreen.screens.map { (WallpaperViewModel.screenId(for: $0), $0) }, uniquingKeysWith: { first, _ in first })
        let sizes = displays.map { display -> ScreenSaverLayoutPlan.Size in
            let scale = screens[display.screenId]?.backingScaleFactor ?? 2
            let points = SIMD2(Int(display.frame.width), Int(display.frame.height))
            return ScreenSaverLayoutPlan.Size(pixels: SIMD2(Int(display.frame.width * scale), Int(display.frame.height * scale)),
                                              points: points)
        }
        guard let largest = sizes.indices.max(by: { sizes[$0].pixels.x * sizes[$0].pixels.y < sizes[$1].pixels.x * sizes[$1].pixels.y })
        else { return ([], []) }
        // A video plays as it is: it has no values of its own.
        if kind != .video { Self.publishPickValues(for: wallpaper, store: settingsStore) }
        let identities = displays.map(\.identity)
        let loop = ScreenSaverLayoutPlan.Loop(content: .init(id: wallpaper.wallpaperDirectory.standardizedFileURL.path),
                                              sizes: sizes, displays: identities)
        return ([LiveLoop(kind: kind, wallpaper: wallpaper, propertyScope: Self.pickScope, loop: loop,
                          pixels: sizes[largest].pixels, points: sizes[largest].points,
                          screenId: displays[largest].screenId, isPick: true)], identities)
    }

    /// Puts the screen saver's values for `wallpaper` (else the wallpaper's own) in `pickScope`,
    /// saved and running, so the live draw loads exactly them: user properties and the Screen
    /// Saver mode's layer edits alike.
    static func publishPickValues(for wallpaper: WEWallpaper, store: ScreenSaverSettingsStore,
                                  services: WallpaperServices = .shared) {
        let identity = WallpaperSettingsIdentity.resolve(wallpaper, defaults: store.defaults)
        let values = store.values(for: identity)
            ?? IsolatedSceneEditSession.seed(of: wallpaper, from: [.shared], defaults: store.defaults)
        let targets = WallpaperPropertyTargets(wallpaper: wallpaper, scopes: [pickScope])
        targets.save(values, defaults: store.defaults)
        services.setUserProperties(values, wallpaper: pickScope.runtimeKey(directory: targets.directory), replacing: true)
    }
}
