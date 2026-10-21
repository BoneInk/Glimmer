import Foundation

/// Release notes by version, for "What's New" after an update. Notes come from the appcast when
/// Sparkle loads it (so they work offline after the update), else from the CHANGELOG bundled in
/// the app.
struct ReleaseNotesStore {
    static let defaultsKey = "CachedReleaseNotes"

    let defaults: UserDefaults
    /// The bundled `CHANGELOG.md`, nil when missing.
    let changelog: String?

    init(defaults: UserDefaults = .app,
         changelog: String? = Self.bundledChangelog()) {
        self.defaults = defaults
        self.changelog = changelog
    }

    static func bundledChangelog() -> String? {
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md") else { return nil }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            OWELog.error(.app, "Could not read the bundled changelog: \(error)")
            return nil
        }
    }

    /// Keeps the notes of versions newer than `installed`, dropping ones that are now older.
    func cache(_ notes: [String: String], newerThan installed: ReleaseVersion) {
        var stored: [String: String] = defaults.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
        for (version, text) in notes where !text.isEmpty {
            guard let parsed = ReleaseVersion(version), parsed > installed else { continue }
            stored[parsed.description] = text
        }
        defaults.set(stored, forKey: Self.defaultsKey)
    }

    /// Forgets notes up to and including `version`, once they were shown.
    func prune(through version: ReleaseVersion) {
        let stored: [String: String] = defaults.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
        defaults.set(stored.filter { ReleaseVersion($0.key).map { $0 > version } ?? false }, forKey: Self.defaultsKey)
    }

    /// The notes of `version`: cached from the appcast, else its CHANGELOG section.
    func notes(for version: ReleaseVersion) -> String? {
        let stored: [String: String] = defaults.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
        if let text = stored[version.description] { return text }
        guard let changelog else { return nil }
        return Self.section(of: version.description, in: changelog)
    }

    /// The body of `## [version]` in a Keep a Changelog file.
    static func section(of version: String, in changelog: String) -> String? {
        var lines: [Substring] = []
        var inside = false
        for line in changelog.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") {
                if inside { break }
                inside = line.hasPrefix("## [\(version)]") || line.hasPrefix("## \(version)")
                continue
            }
            if inside { lines.append(line) }
        }
        let text: String = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
