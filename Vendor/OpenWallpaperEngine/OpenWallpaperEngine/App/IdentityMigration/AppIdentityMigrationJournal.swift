import Foundation

/// What `AppIdentityMigration` has done so far, kept in the new identity's support folder
/// (`fileName`) and rewritten atomically after every step, so a crash mid-way resumes with the
/// steps not yet done instead of repeating or skipping one.
struct AppIdentityMigrationJournal: Codable, Equatable {
    static let fileName = "IdentityMigration.json"

    /// The steps finished, `AppIdentityMigration.Step` raw values.
    var completed: [String] = []
    /// Every step is done; later launches skip the migration.
    var finished = false
    /// The old identity had state for this copy (defaults), so the user is told once.
    var foundLegacyState = false
    /// The one-time notice has been shown.
    var noticeShown = false

    static func url(in supportDirectory: URL) -> URL {
        supportDirectory.appending(path: fileName, directoryHint: .notDirectory)
    }

    /// The journal at `url`; an empty one when there is none yet. A journal that can't be read
    /// starts over: every step is safe to run again.
    static func load(from url: URL) -> AppIdentityMigrationJournal {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return AppIdentityMigrationJournal() }
        do {
            return try JSONDecoder().decode(AppIdentityMigrationJournal.self, from: Data(contentsOf: url))
        } catch {
            OWELog.error(.settings, "Identity migration: can't read its journal \(url.path(percentEncoded: false)); starting over: \(error)")
            return AppIdentityMigrationJournal()
        }
    }

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
