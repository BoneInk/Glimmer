import Foundation
import Security

/// Moves this copy's state from the app's old identity (bundle id `legacyBundleIdentifier`) to its
/// current one, once, at the first launch of the renamed app (`AppMain`, before anything reads the
/// defaults). Data is moved, not copied: after it, an older version no longer sees it.
///
/// Each step is idempotent and recorded in a journal in the support folder
/// (`AppIdentityMigrationJournal`) as it finishes, so a crash resumes with what is left. A step
/// that fails is logged and tried again at the next launch; the others go on.
///
/// - Defaults: the old domain's keys are written to the new one (a key the new one already has
///   keeps its value), read back, and only then removed from the old domain. The real copy also
///   moves the Wallpaper Editor's own domain (`<id>.editor`).
/// - Caches: `<Caches>/<old id>` (shader variants, pipeline archives, …) becomes `<Caches>/<new id>`
///   (`FolderMerger`); the real copy also moves the editor's caches and the web views' data
///   (`~/Library/WebKit/<id>`, `~/Library/HTTPStorages/<id>`).
/// - Keychain: each secret is written under the new service, read back, and only then deleted
///   from the old one. Reading the old item may show one keychain prompt; a declined prompt
///   leaves the old item where it is.
/// - The real copy reinstalls the screen saver under the new id and registers launch at login
///   again under the new identity.
///
/// The Application Support folder (`Open Wallpaper Engine`) is named after the app, not its id,
/// so it stays where it is. An isolated copy (`AppStorageLocation`) moves only its own tag's
/// defaults, caches and keychain items. Privacy permissions (TCC) can't be moved: macOS asks again.
struct AppIdentityMigration {
    static let legacyBundleIdentifier = "com.winddog.wallpaper-engine"

    enum Step: String, CaseIterable {
        case defaults, editorDefaults, caches, editorCaches, webData, keychain, screenSaver, loginItem

        /// The steps an isolated copy runs: only what belongs to its tag.
        static let isolated: [Step] = [.defaults, .caches, .keychain]
    }

    struct DefaultsNotWritten: Error, CustomStringConvertible {
        let domain: String
        let keys: [String]
        var description: String { "\(domain) is missing \(keys.joined(separator: ", ")) after writing them" }
    }

    struct KeychainNotWritten: Error, CustomStringConvertible {
        let service: String
        let account: String
        var description: String { "\(service) doesn't hold \(account) after writing it" }
    }

    let isolationTag: String?
    let legacyIdentifier: String
    let currentIdentifier: String
    /// The current identity's support folder, where the journal is kept.
    let supportDirectory: URL
    /// `AppStorageLocation.cachesDirectory`: the user's Caches folder, or the isolated one.
    let cachesDirectory: URL
    /// The user's Library folder (WebKit and HTTPStorages data).
    let libraryDirectory: URL
    let preferences: PreferenceDomains
    let keychain: (_ service: String) -> KeychainStoring
    let keychainItems: [(suffix: String, account: String)]
    var merger = FolderMerger()
    var reinstallScreenSaver: () throws -> Void = {}
    var reregisterLoginItem: () throws -> Void = {}

    var journalURL: URL { AppIdentityMigrationJournal.url(in: supportDirectory) }

    var steps: [Step] { isolationTag == nil ? Step.allCases : Step.isolated }

    /// `<id>` for the real copy, `<id>.isolated.<tag>` for an isolated one: the defaults suite and
    /// the keychain services' prefix (`AppStorageLocation`).
    func scoped(_ identifier: String) -> String {
        isolationTag.map { "\(identifier).isolated.\($0)" } ?? identifier
    }

    /// Runs the steps not yet done and returns the journal as it is afterwards.
    @discardableResult
    func run() -> AppIdentityMigrationJournal {
        var journal = AppIdentityMigrationJournal.load(from: journalURL)
        guard !journal.finished, legacyIdentifier != currentIdentifier else { return journal }
        let pending = steps.filter { !journal.completed.contains($0.rawValue) }
        OWELog.info(.settings, "Identity migration: \(scoped(legacyIdentifier)) → \(scoped(currentIdentifier)), steps \(pending.map(\.rawValue).joined(separator: ", "))")
        var failed: [Step] = []
        for step in pending {
            do {
                let moved = try perform(step, foundLegacyState: journal.foundLegacyState)
                if step == .defaults, moved { journal.foundLegacyState = true }
                journal.completed.append(step.rawValue)
                try journal.save(to: journalURL)
                OWELog.info(.settings, "Identity migration: \(step.rawValue) done\(moved ? "" : " (nothing to move)")")
            } catch {
                failed.append(step)
                OWELog.error(.settings, "Identity migration: \(step.rawValue) failed; it runs again at the next launch: \(error)")
            }
        }
        guard failed.isEmpty else { return journal }
        journal.finished = true
        do {
            try journal.save(to: journalURL)
            OWELog.info(.settings, "Identity migration: finished")
        } catch {
            OWELog.error(.settings, "Identity migration: can't record that it finished: \(error)")
        }
        return journal
    }

    /// Runs one step; true when it moved something.
    func perform(_ step: Step, foundLegacyState: Bool) throws -> Bool {
        switch step {
        case .defaults:
            return try moveDefaults(from: scoped(legacyIdentifier), to: scoped(currentIdentifier))
        case .editorDefaults:
            return try moveDefaults(from: legacyIdentifier + AppBundleLayout.editorIdentifierSuffix,
                                    to: currentIdentifier + AppBundleLayout.editorIdentifierSuffix)
        case .caches:
            return try merger.move(cachesDirectory.appending(path: legacyIdentifier, directoryHint: .isDirectory),
                                   to: cachesDirectory.appending(path: currentIdentifier, directoryHint: .isDirectory))
        case .editorCaches:
            let suffix = AppBundleLayout.editorIdentifierSuffix
            return try merger.move(cachesDirectory.appending(path: legacyIdentifier + suffix, directoryHint: .isDirectory),
                                   to: cachesDirectory.appending(path: currentIdentifier + suffix, directoryHint: .isDirectory))
        case .webData:
            var moved = false
            for (folder, suffix) in [("WebKit", ""), ("HTTPStorages", ""), ("HTTPStorages", ".binarycookies")] {
                let parent = libraryDirectory.appending(path: folder, directoryHint: .isDirectory)
                moved = try merger.move(parent.appending(path: legacyIdentifier + suffix),
                                        to: parent.appending(path: currentIdentifier + suffix)) || moved
            }
            return moved
        case .keychain:
            return try moveKeychainItems()
        case .screenSaver:
            try reinstallScreenSaver()
            return false
        case .loginItem:
            guard foundLegacyState else { return false }
            try reregisterLoginItem()
            return true
        }
    }

    /// Writes `old`'s keys into `new` (keeping any `new` already has), checks that `new` holds
    /// every one of them, then removes them from `old`.
    func moveDefaults(from old: String, to new: String) throws -> Bool {
        let values = preferences.values(in: old)
        guard !values.isEmpty else { return false }
        let existing = preferences.values(in: new)
        preferences.set(values.filter { existing[$0.key] == nil }, in: new)
        let written = preferences.values(in: new)
        let missing = values.keys.filter { written[$0] == nil }.sorted()
        guard missing.isEmpty else { throw DefaultsNotWritten(domain: new, keys: missing) }
        preferences.remove(Array(values.keys), from: old)
        OWELog.info(.settings, "Identity migration: moved \(values.count) defaults from \(old) to \(new)")
        return true
    }

    /// Each Steam secret: written under the new service (unless it already has one), read back,
    /// then deleted from the old service. Never deleted before the new service holds it.
    func moveKeychainItems() throws -> Bool {
        var moved = false
        for item in keychainItems {
            let old = keychain("\(scoped(legacyIdentifier)).\(item.suffix)")
            let new = keychain("\(scoped(currentIdentifier)).\(item.suffix)")
            let value: String?
            do {
                value = try old.string(forAccount: item.account)
            } catch let failure as KeychainStore.Failure where Self.isDeclined(failure.status) {
                OWELog.error(.settings, "Identity migration: reading \(item.account) from \(old.service) was declined; it stays there: \(failure)")
                continue
            }
            guard let value else { continue }
            let current = try new.string(forAccount: item.account)
            if current == nil {
                try new.set(value, forAccount: item.account)
            }
            guard let stored = try new.string(forAccount: item.account), current != nil || stored == value else {
                throw KeychainNotWritten(service: new.service, account: item.account)
            }
            try old.removeValue(forAccount: item.account)
            OWELog.info(.settings, "Identity migration: moved \(item.account) from \(old.service) to \(new.service)")
            moved = true
        }
        return moved
    }

    /// The user turned the keychain prompt down, or it couldn't be shown.
    static func isDeclined(_ status: OSStatus) -> Bool {
        [errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed].contains(status)
    }
}
