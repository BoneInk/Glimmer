import Foundation

/// Applies the system preferences theming wants and puts the user's back. It saves each
/// preference's original value before the first change, never writes a value that is already
/// stored, and restores a preference only while it still holds what theming wrote.
public final class SystemThemeApplier {
    private let writer: SystemAppearanceWriter
    private let store: ThemingJournalStore
    private var journal: ThemingJournal

    public init(writer: SystemAppearanceWriter, store: ThemingJournalStore) {
        self.writer = writer
        self.store = store
        journal = store.load()
    }

    /// The keys theming has changed and not yet restored.
    public var changedKeys: Set<SystemPreferenceKey> { Set(journal.entries.keys) }

    /// Makes `desired` the stored values (a key mapped to nil is removed), and restores every key
    /// theming changed that `desired` no longer names. A key's original is the one saved before its
    /// first change, also when a later value replaces or removes it. Returns the keys written.
    @discardableResult
    public func apply(_ desired: [SystemPreferenceKey: PreferenceValue?]) -> Set<SystemPreferenceKey> {
        var written = Set<SystemPreferenceKey>()
        for key in SystemPreferenceKey.allCases {
            if let value = desired[key] {
                let current = writer.value(for: key)
                if journal.entries[key] == nil {
                    // Saved before the first write, and on disk before the write happens.
                    journal.entries[key] = .init(original: current, written: current)
                    journal.isSessionActive = true
                    store.save(journal)
                }
                guard current != value else { continue }
                writer.setValue(value, for: key)
                journal.entries[key]?.written = value
                written.insert(key)
            } else if journal.entries[key] != nil, restore(key) {
                written.insert(key)
            }
        }
        if journal.entries.isEmpty { journal.isSessionActive = false }
        store.save(journal)
        post(written)
        return written
    }

    /// Puts every changed preference back. Returns the keys written.
    @discardableResult
    public func restoreAll() -> Set<SystemPreferenceKey> { apply([:]) }

    /// At launch: a session the app didn't end cleanly (a crash) has its originals put back.
    /// Returns whether it did.
    @discardableResult
    public func recoverAfterUncleanExit() -> Bool {
        guard journal.isSessionActive else { return false }
        restoreAll()
        return true
    }

    /// A clean quit. With `restoring`, the originals go back; otherwise the themed values stay
    /// and the originals are kept, so turning theming off later still restores them.
    public func endSession(restoring: Bool) {
        if restoring {
            restoreAll()
        } else {
            journal.isSessionActive = false
            store.save(journal)
        }
    }

    /// Writes `key`'s original back if it still holds theming's value, and forgets the key.
    /// Returns whether it wrote.
    private func restore(_ key: SystemPreferenceKey) -> Bool {
        guard let entry = journal.entries.removeValue(forKey: key) else { return false }
        let current = writer.value(for: key)
        guard current == entry.written, current != entry.original else { return false }
        writer.setValue(entry.original, for: key)
        return true
    }

    private func post(_ keys: Set<SystemPreferenceKey>) {
        for change in SystemAppearanceChange.allCases where keys.contains(where: { $0.change == change }) {
            writer.post(change)
        }
    }
}
