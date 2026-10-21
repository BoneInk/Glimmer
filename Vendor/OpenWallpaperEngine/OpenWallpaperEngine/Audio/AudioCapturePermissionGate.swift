import Foundation

/// Decides whether ScreenCaptureKit may be touched and whether the user should hear about a
/// missing Screen Recording grant.
///
/// `SCShareableContent.current` and `SCStream.startCapture()` show the system permission prompt
/// themselves whenever the grant is missing, so every retry or restart used to re-prompt. The gate
/// only ever asks `preflight` (which never prompts); prompting is left to explicit user actions.
@MainActor
final class AudioCapturePermissionGate {
    private let preflight: () -> Bool
    private let isAlertDismissed: () -> Bool
    private var didAlertThisLaunch = false
    private var lastKnownGranted: Bool?

    init(preflight: @escaping () -> Bool, isAlertDismissed: @escaping () -> Bool) {
        self.preflight = preflight
        self.isAlertDismissed = isAlertDismissed
    }

    /// True only when capture can start without the system showing a prompt.
    func canCapture() -> Bool {
        let granted = preflight()
        lastKnownGranted = granted
        return granted
    }

    /// True at most once per launch, and never after the user chose "Don't Ask Again".
    func shouldAlertMissingPermission() -> Bool {
        guard !didAlertThisLaunch, !isAlertDismissed(), !preflight() else { return false }
        didAlertThisLaunch = true
        return true
    }

    /// Re-checks the grant without prompting; true when it went from missing (or unknown) to
    /// granted since the last check, i.e. when capture should now be started.
    func becameGranted() -> Bool {
        let wasGranted = lastKnownGranted
        return canCapture() && wasGranted != true
    }
}
