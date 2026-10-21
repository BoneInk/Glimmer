import Foundation
@testable import OWETheming

/// Preferences in memory, with every write and notification recorded.
final class FakeAppearanceWriter: SystemAppearanceWriter {
    var values: [SystemPreferenceKey: PreferenceValue]
    private(set) var writes: [(SystemPreferenceKey, PreferenceValue?)] = []
    private(set) var posted: [SystemAppearanceChange] = []

    init(_ values: [SystemPreferenceKey: PreferenceValue] = [:]) {
        self.values = values
    }

    func value(for key: SystemPreferenceKey) -> PreferenceValue? { values[key] }

    func setValue(_ value: PreferenceValue?, for key: SystemPreferenceKey) {
        writes.append((key, value))
        values[key] = value
    }

    func post(_ change: SystemAppearanceChange) { posted.append(change) }

    var writtenKeys: [SystemPreferenceKey] { writes.map(\.0) }

    func clearLog() {
        writes = []
        posted = []
    }
}

/// The journal in memory; `saved` is what a relaunch would read.
final class MemoryJournalStore: ThemingJournalStore {
    var saved = ThemingJournal()
    func load() -> ThemingJournal { saved }
    func save(_ journal: ThemingJournal) { saved = journal }
}
