import AppKit

/// Quits the app even when AppKit won't.
///
/// `NSApplication.terminate(_:)` returns without quitting while a sheet or a modal window is up
/// ("App termination blocked by modal sheet"): the onboarding sheet, an import or warning sheet,
/// an alert. A SIGTERM, a logout or shutdown, a Quit menu choice and an update's relaunch then left
/// the app running. A wallpaper app has no document to lose in a sheet, so when AppKit refuses or
/// defers, the app ends the way a normal quit does: `willTerminateNotification` (which runs
/// `applicationWillTerminate` and every other observer), then `exit(0)`, within `deadline`.
@MainActor
final class AppTermination: NSObject {
    static let shared = AppTermination()

    /// How long AppKit gets to quit by itself.
    var deadline: TimeInterval = 1.5

    private let terminate: () -> Void
    private let notificationCenter: NotificationCenter
    private let exitProcess: (Int32) -> Void
    private var isQuitting = false

    init(terminate: @escaping () -> Void = { NSApplication.shared.terminate(nil) },
         notificationCenter: NotificationCenter = .default,
         exitProcess: @escaping (Int32) -> Void = { exit($0) }) {
        self.terminate = terminate
        self.notificationCenter = notificationCenter
        self.exitProcess = exitProcess
        super.init()
    }

    /// Quits through AppKit, and by itself if AppKit hasn't within `deadline`.
    func quit() {
        armDeadline()
        terminate()
    }

    /// For a quit someone else starts (Sparkle's relaunch): ends the app if it hasn't quit within
    /// `deadline`.
    func armDeadline() {
        guard !isQuitting else { return }
        isQuitting = true
        // The main queue also runs inside a sheet's or modal window's run loop.
        DispatchQueue.main.asyncAfter(deadline: .now() + deadline) { [weak self] in self?.finish() }
    }

    private func finish() {
        OWELog.info(.app, "Quit was refused or stalled (a sheet or modal window is open); quitting anyway")
        notificationCenter.post(name: NSApplication.willTerminateNotification, object: NSApplication.shared)
        exitProcess(0)
    }

    /// The menu items' and Apple events' quit (Quit menu, logout, shutdown, `quit` from a script).
    func installQuitHandlers() {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleQuitEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEQuitApplication))
    }

    @objc private func handleQuitEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        quit()
    }

    /// The Quit menu items' action.
    @objc func quit(_ sender: Any?) { quit() }
}
