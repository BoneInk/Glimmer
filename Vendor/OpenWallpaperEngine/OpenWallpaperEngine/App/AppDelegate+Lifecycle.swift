import Cocoa
import Combine
import SwiftUI
import AVKit
import WebKit
import OWEInspectorKit
import OWETheming

extension AppDelegate {
    /// Settings › Library Folders changed: watch the new set and list its wallpapers.
    func libraryFoldersDidChange() {
        libraryFolderWatcher.watch(LibraryFolders().folders)
        contentViewModel.refresh()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A test copy wears "TEST", a local build "Dev", on its Dock icon (`DockBadge`).
        DockBadge.current.apply()
        #if DEBUG
        AndroidBatchPicker.openScreenshotFixtureIfRequested(library: contentViewModel.library)
        #endif
        AppDelegate.shared.setPlacehoderWallpaper(with: wallpaperViewModel.currentWallpaper)
        // Each display's desktop picture (lock screen, menu bar tint) follows what it shows.
        desktopPictures.observe(wallpaperViewModel, settings: globalSettingsViewModel)
        #if DEBUG
        // The live screen saver lab: each display's window stack during a screen saver or lock.
        ScreenSaverWindowSampler.shared.startIfLab()
        #endif
        // The screen saver shows each display's picture until its live frames come.
        if ScreenSaverInstaller.current.mayInstall {
            let stills = ScreenSaverStillPublisher.current
            desktopPictures.sync.onPictureWritten = { url, display in stills.publish(url, display: display) }
            // With the lock-screen picture and the menu bar tint off, the same pictures are
            // written for the screen saver alone while its plugin is on.
            desktopPictures.saverSync?.onPictureWritten = { url, display in stills.publish(url, display: display) }
            desktopPictures.wantsScreenSaverStills = { [unowned self] in globalSettingsViewModel.settings.screenSaver }
            screenSaverSelection.stills = stills
            liveScreenSaver.stills = stills
        }

        // 显示桌面壁纸
        for (_, window) in self.wallpaperWindows {
            window.orderFront(nil)
        }
        
        safeRestart.showPendingNotice()
        // Once, after the move from the old bundle id: macOS asks for its permissions again.
        identityNotice.showIfPending()
        updater.willRelaunch = { [unowned self] in
            self.captureUpdateRelaunchState().save(to: .app)
            // Sparkle quits next; a sheet would stop that.
            AppTermination.shared.armDeadline()
        }
        // Logout, shutdown and scripted quits go through the same bounded quit.
        AppTermination.shared.installQuitHandlers()
        updater.start()
        displayPlaybackMonitor.start(settings: globalSettingsViewModel.$settings)
        videoMemorySettingCancellable = globalSettingsViewModel.$settings
            .map(\.pauseOnVRAMExhausted)
            .removeDuplicates()
            .sink { [weak self] enabled in MainActor.assumeIsolated { self?.videoMemoryWatch.setEnabled(enabled) } }

        // After an update relaunch, what was open before; otherwise the setup assistant if due.
        if !restoreUpdateRelaunchState(), !launchedForScreenSaver,
           globalSettingsViewModel.isFirstLaunch || globalSettingsViewModel.needsLegalNotice {
            self.mainWindowController.window.center()
            self.mainWindowController.window.makeKeyAndOrderFront(nil)
        }

        // Registers the playlists', the hotkey actions', the wallpapers' and the profiles' global shortcuts.
        _ = playlistShortcuts
        _ = globalHotKeys

        // MCP clients connect once the app is set up, while the MCP Server plugin is installed.
        mcpServerPlugin.start()
        // And the command line's `--control` commands.
        commandLineControl.start()

        // Theming: puts back what a crashed session changed, then follows the wallpaper's colour.
        DesktopPictureTheming.provider = { [unowned self] in theming.strips }
        theming.start(settings: globalSettingsViewModel.$settings.map(\.theming).eraseToAnyPublisher(),
                      wallpapers: wallpaperViewModel)
        themeTintCancellable = theming.$appTint.removeDuplicates().sink { [unowned self] in themeTint.publish($0) }

        // Launched into the menu bar only, the Dock icon goes until a window opens, unless Show in
        // Dock keeps it.
        dockPresence.keepsIcon = { [unowned self] in globalSettingsViewModel.settings.showInDock && !launchedForScreenSaver }
        dockPresence.start()

        // The Wallpaper Editor's browser previews, when any is missing.
        editorPreviewPrewarm.start(reason: "launch", after: EditorPreviewPrewarm.launchDelay)

        // Cache entries unused for 60 days go, a while after launch and then daily.
        cacheMaintenance.start()

        // Workshop downloads need SteamCMD; set it up from Valve in the background when it's missing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            self.steamCmdInstaller.detectThenAutoInstall(self.contentViewModel.steamCmd)
        }

        // Local wallpapers get their stable settings ids once, before any of them is edited.
        let libraries = [FileManager.default.wallpapersDirectory] + LibraryFolders().folders
        DispatchQueue.global(qos: .utility).async {
            LocalWallpaperIdentities.registerLibrary(libraries)
            WallpaperPackageConverter.convertInstalledLibrary()
            if UserDefaults.app.bool(forKey: "ReclaimOriginalPackages") {
                WallpaperPackageConverter.reclaimEligibleSources()
            }
            // Bundles left on an older conversion with no package to redo it from.
            let stale = StaleBundleScanner.scan(storage: FileManager.default.wallpapersDirectory)
            guard !stale.isEmpty else { return }
            // Later, so the cached SteamCMD login restored at launch has had its turn.
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                self?.refreshStaleBundles(stale)
            }
        }
    }
    
    /// What earlier versions left for the screen saver: what they set as the screen saver (a
    /// scene's recording, a video's own file copied in) becomes the live pick of that wallpaper,
    /// with its picture as the still; one of a wallpaper no longer in the library goes, so the
    /// screen saver follows the desktop again. The old recordings and video files (only OWE's own,
    /// in the screen saver's folder) and the retired settings are deleted.
    func migrateScreenSaverRecording() {
        let store = screenSaverSelection.store
        store.removeRetiredKeys()
        // Nothing is recorded, linked or copied any more: the old files go, in the background
        // (only the user's own copy wrote them where the saver reads).
        defer {
            if ScreenSaverInstaller.current.mayInstall {
                let videos = ScreenSaverVideoStore.current, caches = AppStorageLocation.current.cachesDirectory
                DispatchQueue.global(qos: .utility).async { videos.removeOldFiles(cachesDirectory: caches) }
            }
        }
        guard let selection = store.selection else {
            store.migrateSelection() // Drops one that no longer decodes.
            return
        }
        let folder = URL(filePath: selection.wallpaperDirectory, directoryHint: .isDirectory)
        guard let wallpaper = InstalledLibrary.wallpaper(at: folder, hiding: []) else {
            store.selection = nil
            OWELog.info(.app, "Screen saver: \(folder.lastPathComponent), set as the screen saver, is no longer in the library")
            return
        }
        guard store.migrateSelection() else { return }
        OWELog.info(.app, "Screen saver: \(folder.lastPathComponent), set as the screen saver by an earlier version, is now drawn live")
        // Its still now, once the app is set up (`renderPickStill`).
        DispatchQueue.main.async { [weak self] in self?.liveScreenSaver.renderPickStill(wallpaper) }
    }

    func screenSaverSessionChanged(_ running: Bool) {
        if running {
            screenSaverQuitTimer?.invalidate()
            screenSaverQuitTimer = nil
            return
        }
        if launchedForScreenSaver {
            launchedForScreenSaver = false
            dockPresence.update()
        }
        guard quitsAfterScreenSaver else { return }
        screenSaverQuitTimer?.invalidate()
        OWELog.info(.app, "Live screen saver: launched only for the screen saver; quitting in \(Int(ScreenSaverLiveController.warmGrace)) s unless a window opens")
        screenSaverQuitTimer = Timer.scheduledTimer(withTimeInterval: ScreenSaverLiveController.warmGrace + 5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.quitsAfterScreenSaver else { return }
                OWELog.info(.app, "Live screen saver: quitting the copy launched for the screen saver")
                NSApp.terminate(nil)
            }
        }
    }

    /// The user opening one of the app's windows keeps a copy launched for the screen saver running.
    func observeWindowsOpenedAfterScreenSaverLaunch() {
        windowOpenedObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil,
                                                                      queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let window = note.object as? NSWindow, window.styleMask.contains(.titled),
                      !(window is NSPanel) else { return }
                self.quitsAfterScreenSaver = false
                self.screenSaverQuitTimer?.invalidate()
                self.screenSaverQuitTimer = nil
                if let observer = self.windowOpenedObserver { NotificationCenter.default.removeObserver(observer) }
                self.windowOpenedObserver = nil
                OWELog.info(.app, "Live screen saver: a window opened; the copy launched for the screen saver keeps running")
            }
        }
    }

    private func refreshStaleBundles(_ stale: [StaleBundle]) {
        let refresher = StaleBundleRefresher(
            downloader: contentViewModel.steamCmd,
            isShown: { [weak self] directory in
                self?.wallpaperViewModel.wallpapers.values.contains {
                    $0.wallpaperDirectory.standardizedFileURL == directory.standardizedFileURL
                } ?? false
            },
            notify: { [weak self] titles in
                guard let self else { return }
                self.staleBundleNotice?.close()
                self.staleBundleNotice = SafeRestartNotice(
                    message: StaleBundleRefresher.noticeMessage(for: titles), onRetry: nil,
                    onDismiss: { [weak self] in
                        self?.staleBundleNotice?.close()
                        self?.staleBundleNotice = nil
                    })
                self.staleBundleNotice?.show()
            })
        staleBundleRefresher = refresher
        refresher.run(stale)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        contentViewModel.navigation.isApplicationActive = true
        // Picks up a steamcmd installed meanwhile, e.g. with Homebrew.
        if !steamCmdInstaller.isBusy {
            contentViewModel.steamCmd.detectSteamCmd()
        }
    }

    func applicationDidResignActive(_ notification: Notification) {
        contentViewModel.navigation.isApplicationActive = false
    }
    
    /// Settings › General › Show in Dock and Show in Menu Bar.
    func applyAppPresence() {
        statusItem?.isVisible = globalSettingsViewModel.settings.showInMenuBar
        dockPresence.update()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !self.mainWindowController.window.isVisible && !settingsWindow.isVisible {
            self.mainWindowController.window?.makeKeyAndOrderFront(nil)
        }
        
        return true
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        // What an application rule loaded isn't the user's choice: the saved wallpapers and
        // playlist go back to theirs before they are stored for the next launch.
        if applicationRuleLoader.isHoldingRestorePoint { applicationRuleLoader.update(nil) }
        safeRestart.applicationWillTerminate()
        crashWatcher.applicationWillTerminate()
        mcpServerPlugin.stop()
        // The steamcmd kept logged in between Workshop downloads quits with the app.
        contentViewModel.steamCmd.endSteamCmdSession()
        updater.stopShaderPrewarm()
        cacheMaintenance.stop()
        // The system colours go back when the user chose "Restore on quit".
        theming.stop()
        // The editor's windows go back to the system accent with the app.
        themeTintCancellable = nil
        themeTint.publish(nil)
        // The user's pictures go back where they still exist; OWE's pictures stay on disk, since
        // a Space macOS doesn't let OWE reach may still show one. Full-screen TIFFs earlier
        // versions left in Caches go to the Trash.
        desktopPictures.restoreUsersPictures()
        DesktopSnapshotCache.current.trashLegacySnapshots()
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}
