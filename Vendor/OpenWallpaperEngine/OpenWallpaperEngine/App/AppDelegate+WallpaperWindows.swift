import Cocoa
import Combine
import SwiftUI
import AVKit
import WebKit
import OWEInspectorKit
import OWETheming

extension AppDelegate {
    func setWallpaperWindows() {
        // Stopped (`stopWallpapers`): no windows until Resume, whatever rebuilds them meanwhile.
        guard !wallpaperViewModel.isStopped else { return }
        for screen in NSScreen.screens {
            let screenId = WallpaperViewModel.screenId(for: screen)
            guard wallpaperViewModel.isScreenEnabled(screenId) else { continue }
            wallpaperWindows[screenId] = makeWallpaperWindow(on: screen, screenId: screenId)
        }
        applyMenuBarStrips()
    }

    /// The wallpaper window for `screen`.
    private func makeWallpaperWindow(on screen: NSScreen, screenId: String) -> NSWindow {
        let window = WallpaperWindow()
        window.styleMask = [.borderless, .fullSizeContentView]
        window.level = Self.wallpaperWindowLevel(hidingDesktopIcons: hidesDesktopIcons)
        window.collectionBehavior = [.stationary, .canJoinAllSpaces]
        window.setFrame(screen.frame, display: true)
        window.isMovable = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .black
        window.isOpaque = true
        window.canHide = false
        window.canBecomeVisibleWithoutLogin = true
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        // The wallpaper's display options (offset, zoom, flip) place the view on the display,
        // inside the layout's content (clone mirror, stretch canvas).
        let content = WallpaperWindowContentView(content: WallpaperDisplayTransformView(
            content: NSHostingView(rootView: DisplayWallpaperView(viewModel: self.wallpaperViewModel, screenId: screenId)),
            screenID: screenId, viewModel: wallpaperViewModel))
        content.isMirrored = wallpaperViewModel.isFlipped(screenId)
        content.stretchCanvas = wallpaperViewModel.layoutResolution.canvases[screenId]
        window.contentView = content
        return window
    }

    /// Adds or removes `screenId`'s window as its wallpapers are turned on or off; the other
    /// displays' windows stay as they are.
    func updateWallpaperWindow(for screenId: String) {
        let wanted = !wallpaperViewModel.isStopped && wallpaperViewModel.isScreenEnabled(screenId)
        if !wanted, let window = wallpaperWindows.removeValue(forKey: screenId) {
            Self.closeWallpaperWindows([screenId: window])
        } else if wanted, wallpaperWindows[screenId] == nil,
                  let screen = NSScreen.screens.first(where: { WallpaperViewModel.screenId(for: $0) == screenId }) {
            wallpaperWindows[screenId] = makeWallpaperWindow(on: screen, screenId: screenId)
            applyMenuBarStrips()
            orderWallpaperWindowsFront()
        }
    }

    /// Fills each wallpaper window's menu bar strip with theming's colour, or clears it.
    func applyMenuBarStrips() {
        let strips = theming.strips
        for (screenId, window) in wallpaperWindows {
            (window.contentView as? WallpaperWindowContentView)?.menuBarStrip =
                MenuBarStripFill(strips, display: CGDirectDisplayID(screenId))
        }
    }

    /// Mirrors the windows of flipped clone displays and only those.
    func applyDisplayFlips(_ flipped: Set<String>) {
        for (screenId, window) in wallpaperWindows {
            (window.contentView as? WallpaperWindowContentView)?.isMirrored = flipped.contains(screenId)
        }
    }

    /// Names each stretched display's canvas in its window; the others have none.
    func applyStretchCanvases(_ canvases: [String: CGRect]) {
        for (screenId, window) in wallpaperWindows {
            (window.contentView as? WallpaperWindowContentView)?.stretchCanvas = canvases[screenId]
        }
    }

    /// Rebuild wallpaper windows without changing enabled state.
    func rebuildWallpaperWindows() {
        Self.closeWallpaperWindows(wallpaperWindows)
        wallpaperWindows.removeAll()
        setWallpaperWindows()
        orderWallpaperWindowsFront()
    }

    /// Closes wallpaper windows and drops their content, so every wallpaper view goes and with it
    /// its hold on the running instance (`WallpaperInstanceRegistry`), page or player.
    static func closeWallpaperWindows(_ windows: [String: NSWindow]) {
        for (_, window) in windows {
            // `isReleasedWhenClosed` is false, so the hosting view (and the video players inside
            // it) survives a plain close and keeps playing.
            window.contentView = nil
            window.close()
        }
    }

    @MainActor
    func showWorkshopPreview(_ wallpaper: WEWallpaper) {
        if let previewViewModel = workshopPreviewViewModel,
           let window = workshopPreviewWindow {
            previewViewModel.setWallpaper(wallpaper, for: previewViewModel.selectedScreenId)
            previewViewModel.playRate = wallpaperViewModel.playRate
            previewViewModel.playVolume = wallpaperViewModel.playVolume
            window.title = wallpaper.project.title
            window.makeKeyAndOrderFront(nil)
            return
        }

        let previewViewModel = WallpaperViewModel(persistsWallpapers: false)
        previewViewModel.setWallpaper(wallpaper, for: previewViewModel.selectedScreenId)
        previewViewModel.playRate = wallpaperViewModel.playRate
        previewViewModel.playVolume = wallpaperViewModel.playVolume

        let window = WorkshopPreviewWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.onDismiss = { [weak self] in
            // Hiding the window leaves its wallpaper view — and that view's video players — alive,
            // so the preview has to be torn down rather than just paused.
            guard let self else { return }
            self.workshopPreviewViewModel?.playRate = 0
            self.workshopPreviewViewModel?.playVolume = 0
            self.workshopPreviewWindow?.contentView = nil
            self.workshopPreviewWindow = nil
            self.workshopPreviewViewModel = nil
        }
        window.title = wallpaper.project.title
        window.contentView = NSHostingView(rootView: WorkshopPreviewContent(
            wallpaperViewModel: previewViewModel
        ).appAccentTint())
        window.center()
        window.makeKeyAndOrderFront(nil)

        workshopPreviewViewModel = previewViewModel
        workshopPreviewWindow = window
    }

    @MainActor
    func applyWorkshopPreview() {
        guard let wallpaper = workshopPreviewViewModel?.currentWallpaper else { return }
        wallpaperViewModel.inspect(wallpaper)
        wallpaperViewModel.applyInspectedWallpaper()
    }

    /// Displays connected, disconnected, woken, resized or rearranged. Only a display never
    /// connected before gets wallpapers turned on; one the user turned off stays off. The windows
    /// are rebuilt only when the displays with wallpapers or the layout changed; otherwise they
    /// follow their displays' frames.
    @objc func screensChanged() {
        let screens = NSScreen.screens
        let connected = screens.map { WallpaperViewModel.screenId(for: $0) }
        wallpaperViewModel.enableNewDisplays(Set(connected))
        // Groups whose displays came back wake up; those left with one display go dormant.
        let layout = wallpaperViewModel.layoutResolution
        wallpaperViewModel.refreshDisplayLayout()
        let wanted: Set<String> = wallpaperViewModel.isStopped
            ? [] : Set(connected.filter { wallpaperViewModel.isScreenEnabled($0) })
        guard wanted == Set(wallpaperWindows.keys), layout == wallpaperViewModel.layoutResolution else {
            rebuildWallpaperWindows()
            return
        }
        for screen in screens {
            if let window = wallpaperWindows[WallpaperViewModel.screenId(for: screen)], window.frame != screen.frame {
                window.setFrame(screen.frame, display: true)
            }
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // Settings opened some other way than `openSettingsWindow`: what Cancel goes back to.
        guard (notification.object as? NSWindow) === settingsWindow else { return }
        globalSettingsViewModel.beginEditing()
    }

    func windowWillClose(_ notification: Notification) {
        // Closed without OK: back to the settings the window opened with.
        guard (notification.object as? NSWindow) === settingsWindow else { return }
        globalSettingsViewModel.reset()
    }

    /// Installs the mouse forwarding while a web wallpaper is shown on an enabled display, and
    /// removes it otherwise: on every change of the shown wallpapers (and layouts), the enabled
    /// displays, or Stop. The publishers send the new values.
    func observeWebWallpapers() {
        webMouseCancellable = wallpaperViewModel.$instanceKeys
            .combineLatest(wallpaperViewModel.$enabledScreens, wallpaperViewModel.$isStopped)
            .map { WebWallpaperMouseForwarder.isNeeded(instanceKeys: $0, enabledScreens: $1, stopped: $2) }
            .removeDuplicates()
            .sink { [weak self] needed in self?.webMouseForwarder.update(needed: needed) }
    }
    
    /// The screen saver follows the main display's wallpaper.
    func setPlacehoderWallpaper(with wallpaper: WEWallpaper) {
        screenSaver.update(enabled: globalSettingsViewModel.settings.screenSaver, wallpaper: wallpaper)
    }
}
