import Foundation

/// The one-time notice after `AppIdentityMigration` moved the old identity's state: macOS ties
/// privacy permissions to the app's identity and asks for them again.
@MainActor
final class AppIdentityNotice {
    static var message: String {
        String(localized: "Open Wallpaper Engine has a new identity; macOS will ask again for permissions like system audio, Local Network and Photos.")
    }

    let journalURL: URL
    private var notice: SafeRestartNotice?

    init(journalURL: URL = AppIdentityMigration.forCurrentProcess().journalURL) {
        self.journalURL = journalURL
    }

    /// Whether the notice is due: the migration finished, found the old identity's state, and
    /// the notice hasn't been shown.
    nonisolated static func isPending(_ journal: AppIdentityMigrationJournal) -> Bool {
        journal.finished && journal.foundLegacyState && !journal.noticeShown
    }

    /// Shows the notice once, recording that it was shown.
    func showIfPending() {
        var journal = AppIdentityMigrationJournal.load(from: journalURL)
        guard Self.isPending(journal) else { return }
        journal.noticeShown = true
        do {
            try journal.save(to: journalURL)
        } catch {
            OWELog.error(.settings, "Identity migration: can't record the notice as shown: \(error)")
        }
        notice = SafeRestartNotice(message: Self.message, onRetry: nil, onDismiss: { [weak self] in
            self?.notice?.close()
            self?.notice = nil
        })
        notice?.show()
    }
}
