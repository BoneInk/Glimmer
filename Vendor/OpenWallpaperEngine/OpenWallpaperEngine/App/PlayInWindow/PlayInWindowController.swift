import AppKit
import Combine
import SwiftUI

/// Wallpaper Engine's Play in Window: wallpapers playing in ordinary, resizable windows beside the
/// desktop, each by its name (WE's window `location`).
///
/// Each window runs its wallpaper as the Workshop preview does: a wallpaper model of its own that
/// saves nothing (`WallpaperViewModel(persistsWallpapers: false)`) and a `WallpaperView`, so every
/// wallpaper type plays there, on its own renderer instance (a scene's runs in that model's
/// registry, never the desktop's), with the shared user properties. The window takes the mouse
/// and keyboard as any window does: a web page gets its events directly, a scene reads the
/// cursor over its view and counts clicks in the window (`DesktopClickMonitor`). Volume and
/// speed follow the desktop's.
@MainActor
final class PlayInWindowController {
    /// The windows open now, by name.
    private(set) var windows: [String: PlayInWindowWindow] = [:]

    private let desktop: WallpaperViewModel

    init(desktop: WallpaperViewModel) {
        self.desktop = desktop
    }

    /// The open windows' names, sorted.
    var names: [String] { windows.keys.sorted() }

    /// The wallpaper the window `name` shows, if one is open.
    func wallpaper(in name: String) -> WEWallpaper? {
        windows[name]?.model.currentWallpaper
    }

    /// Whether Play in Window can show `wallpaper`: every type the app plays, not an application.
    static func canPlay(_ wallpaper: WEWallpaper) -> Bool {
        ["scene", "video", "web", "remote-video", "remote-image"].contains(wallpaper.project.type.lowercased())
    }

    /// Opens `request`'s window, or shows its wallpaper in the open window of its name (which
    /// keeps its place and size unless the request gives them).
    /// Returns why it didn't, if it didn't.
    @discardableResult
    func open(_ request: PlayInWindowRequest) -> Refusal? {
        guard Self.canPlay(request.wallpaper) else {
            OWELog.info(.app, "Play in Window: \(request.wallpaper.project.title) is a \(request.wallpaper.project.type) wallpaper, which can't play in a window")
            return .unsupported
        }
        // Code runs only once the user trusted it, as on the desktop; a window can't ask.
        guard WallpaperViewModel.mayRunWithoutAsking(request.wallpaper) else {
            OWELog.info(.app, "Play in Window: \(request.wallpaper.project.title) runs code and isn't trusted yet")
            return .untrusted
        }
        if let window = windows[request.name] {
            let model = window.model
            model.setWallpaper(request.wallpaper, for: model.selectedScreenId)
            window.title = request.wallpaper.project.displayTitle
            if request.origin != nil || request.size != .fullHD { place(window, request) }
            show(window, activating: request.activates)
            OWELog.info(.app, "Play in Window \"\(request.name)\": \(request.wallpaper.project.title)")
            return nil
        }
        let model = WallpaperViewModel(persistsWallpapers: false)
        model.setWallpaper(request.wallpaper, for: model.selectedScreenId)
        let style: NSWindow.StyleMask = request.borderless ? [.borderless, .resizable] : [.titled, .closable, .resizable, .miniaturizable]
        let window = PlayInWindowWindow(name: request.name, model: model, styleMask: style)
        window.subscriptions = follow(desktop, in: model)
        window.title = request.wallpaper.project.displayTitle
        window.isMovableByWindowBackground = request.borderless
        window.contentView = NSHostingView(rootView: PlayInWindowContent(model: model).appAccentTint())
        window.onClose = { [weak self, weak window] in
            guard let self, let window else { return }
            self.teardown(window)
        }
        windows[request.name] = window
        place(window, request)
        show(window, activating: request.activates)
        OWELog.info(.app, "Play in Window \"\(request.name)\" opened: \(request.wallpaper.project.title)")
        return nil
    }

    /// Why a wallpaper didn't open in a window.
    enum Refusal: Error, Equatable {
        /// An application wallpaper, which the app doesn't play.
        case unsupported
        /// It runs code and the user hasn't trusted it yet (Set as Wallpaper asks).
        case untrusted

        var message: String {
            switch self {
            case .unsupported:
                return String(localized: "This kind of wallpaper can't play in a window.", comment: "Play in Window refused: an application wallpaper")
            case .untrusted:
                return String(localized: "This wallpaper runs its own code. Set it as your wallpaper once and trust it, then it can play in a window.", comment: "Play in Window refused: a web wallpaper the user hasn't trusted yet")
            }
        }
    }

    /// Closes the window `name`, or every window for nil. False when there was none to close.
    @discardableResult
    func close(_ name: String? = nil) -> Bool {
        let closing = name.map { windows[$0].map { [$0] } ?? [] } ?? Array(windows.values)
        for window in closing { window.close() }
        return !closing.isEmpty
    }

    private func show(_ window: NSWindow, activating: Bool) {
        if activating {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFront(nil)
        }
    }

    private func place(_ window: NSWindow, _ request: PlayInWindowRequest) {
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let mainFrame = NSScreen.screens.first?.frame ?? screen.frame
        let titleBar = window.frame.height - window.contentRect(forFrameRect: window.frame).height
        let content = PlayInWindowRequest.contentFrame(size: request.size, origin: request.origin,
                                                       visibleFrame: screen.visibleFrame,
                                                       backingScale: screen.backingScaleFactor,
                                                       mainFrame: mainFrame, titleBarHeight: titleBar)
        window.setFrame(window.frameRect(forContentRect: content), display: true)
    }

    /// The window plays at the desktop's volume and speed, which the hotkeys and menus change.
    private func follow(_ desktop: WallpaperViewModel, in model: WallpaperViewModel) -> [AnyCancellable] {
        model.playVolume = desktop.playVolume
        model.playRate = desktop.playRate
        model.audioOutputEnabled = desktop.audioOutputEnabled
        return [
            desktop.$playVolume.dropFirst().sink { [weak model] in model?.playVolume = $0 },
            desktop.$playRate.dropFirst().sink { [weak model] in model?.playRate = $0 },
            desktop.$audioOutputEnabled.dropFirst().sink { [weak model] in model?.audioOutputEnabled = $0 },
        ]
    }

    /// A closed window's wallpaper stops: its view (and with it the scene's instance, the page or
    /// the player) goes.
    private func teardown(_ window: PlayInWindowWindow) {
        guard windows[window.name] === window else { return }
        window.subscriptions = []
        window.model.playVolume = 0
        window.contentView = nil
        windows[window.name] = nil
        OWELog.info(.app, "Play in Window \"\(window.name)\" closed")
    }
}

/// A Play in Window window: an ordinary window that tears its wallpaper down when it closes.
final class PlayInWindowWindow: NSWindow {
    /// Marks these windows for the click monitor: a click in one lands on its wallpaper.
    static let identifier = NSUserInterfaceItemIdentifier("app.openwallpaperengine.playInWindow")

    let name: String
    let model: WallpaperViewModel
    var onClose: (() -> Void)?
    /// Its volume and speed following the desktop's.
    var subscriptions: [AnyCancellable] = []

    init(name: String, model: WallpaperViewModel, styleMask: NSWindow.StyleMask) {
        self.name = name
        self.model = model
        super.init(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540), styleMask: styleMask,
                   backing: .buffered, defer: false)
        identifier = Self.identifier
        isReleasedWhenClosed = false
        collectionBehavior.insert(.fullScreenPrimary)
        backgroundColor = .black
    }

    /// Never restored from a coder: the controller makes each window.
    required init?(coder: NSCoder) { nil }

    // A borderless window still takes the keyboard (a web page's keys, Esc).
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func close() {
        super.close()
        onClose?()
        onClose = nil
    }

    override func cancelOperation(_ sender: Any?) {
        // Esc leaves full screen, as in any window; it doesn't close the wallpaper.
        if styleMask.contains(.fullScreen) { toggleFullScreen(sender) }
    }
}

/// The window's wallpaper, filling it.
private struct PlayInWindowContent: View {
    @ObservedObject var model: WallpaperViewModel

    var body: some View {
        WallpaperView(viewModel: model, screenId: model.selectedScreenId)
            .ignoresSafeArea()
            .background(Color.black)
    }
}
