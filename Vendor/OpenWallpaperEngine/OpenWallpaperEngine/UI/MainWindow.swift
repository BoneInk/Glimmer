//
//  MainWindowController.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/8.
//

import Cocoa
import SwiftUI

class MainWindowController: NSWindowController, NSWindowDelegate {
    override var window: NSWindow! {
        get {
            return super.window
        }
        set {
            super.window = newValue
        }
    }
    
    override init(window: NSWindow?) {
        super.init(window: Self.makeWindow())
        self.window.delegate = self
        self.window.contentView = NSHostingView(rootView: ContentView(
                viewModel: AppDelegate.shared.contentViewModel,
                wallpaperViewModel: AppDelegate.shared.wallpaperViewModel
            ).environmentObject(AppDelegate.shared.globalSettingsViewModel)
            .appAccentTint()
        )
    }

    /// The main window, without its content. It moves by its title bar and toolbar only: moved
    /// by its background as well, AppKit moves it from any mouse-down on a view that allows it,
    /// which SwiftUI's hosting view and every non-opaque view do, so a drag on a wallpaper or
    /// folder tile moved the window instead of starting the drag.
    static func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Open Wallpaper Engine \(AppVersion.current)"
        // The content's split view, toolbar and inspector draw the window chrome (glass on macOS 26).
        window.toolbarStyle = .unified
        // The tabs sit in the toolbar's centre; the title stays for the Window menu and Mission Control.
        window.titleVisibility = .hidden
        // The frame autosaves into UserDefaults.standard, which an isolated copy must not write.
        if !AppStorageLocation.current.isIsolated { window.setFrameAutosaveName("MainWindow") }
        return window
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func windowDidLoad() {
        super.windowDidLoad()
    }
    
    /// Edit › Select All (⌘A) when no text field took it: every wallpaper or card the Installed,
    /// Workshop or Discover tab shows. It reaches the window's controller through the responder
    /// chain, so a focused text field (the search, a name prompt) keeps selecting its own text.
    override func selectAll(_ sender: Any?) {
        Self.selectAllAction?()
    }

    /// What Select All does in the tab shown; nil when it shows nothing to select.
    private static var selectAllAction: (() -> Void)? {
        let content = AppDelegate.shared.contentViewModel
        switch content.navigation.topTabBarSelection {
        case 0:
            let library = content.library
            guard !library.displayedWallpapers.isEmpty else { return nil }
            // Picking wallpapers for an export: every exportable one shown joins the picks.
            if let selection = content.androidBatchPicker {
                return { selection.selectAll(library.displayedWallpapers) }
            }
            return { library.selectAll() }
        case 1:
            let workshop = content.workshopVM
            return workshop.items.isEmpty ? nil : { workshop.selectAll() }
        case 4:
            let shown = content.discoverVM.shownItems, workshop = content.workshopVM
            return shown.isEmpty ? nil : { workshop.selectAll(shown) }
        default:
            return nil
        }
    }

    func windowWillClose(_ notification: Notification) {
        AppDelegate.shared.contentViewModel.navigation.isStaging = false
    }
    
    func windowDidBecomeKey(_ notification: Notification) {
        stageLibrary()
    }

    /// A window opened behind another app never becomes key: the library loads once it's on screen.
    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard window?.occlusionState.contains(.visible) == true else { return }
        stageLibrary()
    }

    /// Builds the library again (closing the window tears it down) and fades it in.
    private func stageLibrary() {
        guard !AppDelegate.shared.contentViewModel.navigation.isStaging else { return }
        DispatchQueue.main.async {
            withAnimation {
                AppDelegate.shared.contentViewModel.navigation.isStaging = true
            }
        }
    }
}

extension MainWindowController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(selectAll(_:)) else { return true }
        return Self.selectAllAction != nil
    }
}
