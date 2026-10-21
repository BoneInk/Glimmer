import Cocoa
import SwiftUI

/// Shows What's New as a sheet on the main window the first time it becomes key after an update
/// (never at a relaunch into the menu bar, which opens no window).
extension AppDelegate {
    func observeMainWindowForWhatsNew() {
        let whatsNew = WhatsNew(currentVersion: AppUpdateConfiguration.main.versionLabel)
        whatsNew.recordFirstInstall()
        NotificationCenter.default.addObserver(
            self, selector: #selector(mainWindowBecameKey(_:)),
            name: NSWindow.didBecomeKeyNotification, object: mainWindowController.window)
    }

    @objc private func mainWindowBecameKey(_ notification: Notification) {
        guard let window = mainWindowController.window, window.attachedSheet == nil else { return }
        // Not over the setup assistant.
        guard !globalSettingsViewModel.isFirstLaunch, !globalSettingsViewModel.needsLegalNotice else { return }
        let whatsNew = WhatsNew(currentVersion: AppUpdateConfiguration.main.versionLabel)
        guard let pending = whatsNew.takePendingEntries() else { return }
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
                             styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        sheet.contentView = NSHostingView(rootView: WhatsNewView(version: pending.current, entries: pending.entries) {
            [weak window, weak sheet] in
            if let sheet { window?.endSheet(sheet) }
        }.appAccentTint())
        window.beginSheet(sheet)
    }
}
