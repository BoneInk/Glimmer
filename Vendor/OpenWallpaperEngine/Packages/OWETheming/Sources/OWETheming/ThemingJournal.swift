import Foundation

/// What theming changed, kept on disk so it can be put back exactly: after a checkbox goes off,
/// on quit, or on the next launch after a crash.
public struct ThemingJournal: Equatable, Codable, Sendable {
    /// One changed preference.
    public struct Entry: Equatable, Codable, Sendable {
        /// The user's value before theming first changed it; nil when the key was absent.
        public var original: PreferenceValue?
        /// The value theming wrote last. A restore leaves the preference alone when it no longer
        /// holds this: the user changed it since, and that choice wins.
        public var written: PreferenceValue?

        public init(original: PreferenceValue?, written: PreferenceValue?) {
            self.original = original
            self.written = written
        }
    }

    public var entries: [SystemPreferenceKey: Entry] = [:]
    /// Set while the app runs with preferences changed; cleared by a clean quit. Found set at
    /// launch, the app ended without quitting (a crash), and the originals go back.
    public var isSessionActive = false

    public init(entries: [SystemPreferenceKey: Entry] = [:], isSessionActive: Bool = false) {
        self.entries = entries
        self.isSessionActive = isSessionActive
    }
}

/// Where the journal is kept.
public protocol ThemingJournalStore: AnyObject {
    func load() -> ThemingJournal
    func save(_ journal: ThemingJournal)
}

/// The journal as JSON under one `UserDefaults` key (the app passes its own defaults suite).
public final class UserDefaultsJournalStore: ThemingJournalStore {
    private let defaults: UserDefaults
    private let key: String
    /// Reports a journal that can't be read or saved (the app's log).
    private let logError: (String) -> Void

    public init(defaults: UserDefaults, key: String = "ThemingJournal", logError: @escaping (String) -> Void) {
        self.defaults = defaults
        self.key = key
        self.logError = logError
    }

    public func load() -> ThemingJournal {
        guard let data = defaults.data(forKey: key) else { return ThemingJournal() }
        do {
            return try JSONDecoder().decode(ThemingJournal.self, from: data)
        } catch {
            // An unreadable journal can't be restored from; starting over keeps the current values.
            logError("Theming: the saved original values can't be read: \(error)")
            return ThemingJournal()
        }
    }

    public func save(_ journal: ThemingJournal) {
        if journal.entries.isEmpty && !journal.isSessionActive {
            defaults.removeObject(forKey: key)
            return
        }
        do {
            defaults.set(try JSONEncoder().encode(journal), forKey: key)
        } catch {
            logError("Theming: the original values can't be saved: \(error)")
        }
    }
}
