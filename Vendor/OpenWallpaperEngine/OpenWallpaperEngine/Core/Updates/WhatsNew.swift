import Foundation

/// Decides when "What's New" shows: the first time the main window opens after the app runs a
/// newer version than the user last saw. A first install records its version and shows nothing,
/// so it never meets the setup assistant.
struct WhatsNew {
    static let lastSeenVersionKey = "LastSeenVersion"
    static let hidesReleaseNotesKey = "HidesReleaseNotesAfterUpdate"

    struct Entry: Equatable {
        let version: String
        let notes: String?
    }

    let defaults: UserDefaults
    let current: ReleaseVersion?
    let notes: ReleaseNotesStore

    init(defaults: UserDefaults = .app, currentVersion: String, notes: ReleaseNotesStore? = nil) {
        self.defaults = defaults
        current = ReleaseVersion(currentVersion)
        self.notes = notes ?? ReleaseNotesStore(defaults: defaults)
    }

    /// At launch: a first install (no version seen yet) counts as seen.
    func recordFirstInstall() {
        guard let current, defaults.string(forKey: Self.lastSeenVersionKey) == nil else { return }
        defaults.set(current.description, forKey: Self.lastSeenVersionKey)
    }

    /// The versions since the last one seen, newest first, with their notes; nil when there is
    /// nothing to show. Marks them seen, so this returns them once.
    func takePendingEntries() -> (current: String, entries: [Entry])? {
        guard let current else { return nil }
        let lastSeen: ReleaseVersion? = defaults.string(forKey: Self.lastSeenVersionKey).flatMap(ReleaseVersion.init)
        guard let lastSeen else {
            defaults.set(current.description, forKey: Self.lastSeenVersionKey)
            return nil
        }
        guard current > lastSeen else {
            // Also after a downgrade: the older version is what the user now sees.
            if current != lastSeen { defaults.set(current.description, forKey: Self.lastSeenVersionKey) }
            return nil
        }
        defaults.set(current.description, forKey: Self.lastSeenVersionKey)
        defer { notes.prune(through: current) }
        if defaults.bool(forKey: Self.hidesReleaseNotesKey) { return nil }
        return (current.description, versions(after: lastSeen, through: current).map { Entry(version: $0.description, notes: notes.notes(for: $0)) })
    }

    /// Every version with notes between the two (skipped updates), and `current` itself.
    /// Pre-releases count only when updating to a pre-release.
    private func versions(after lastSeen: ReleaseVersion, through current: ReleaseVersion) -> [ReleaseVersion] {
        var found: Set<String> = [current.description]
        let cached: [String: String] = defaults.dictionary(forKey: ReleaseNotesStore.defaultsKey) as? [String: String] ?? [:]
        var candidates: [String] = Array(cached.keys)
        if let changelog = notes.changelog {
            for line in changelog.split(separator: "\n") where line.hasPrefix("## [") {
                candidates.append(String(line.dropFirst(4).prefix { $0 != "]" }))
            }
        }
        for candidate in candidates {
            guard let version = ReleaseVersion(candidate), version > lastSeen, version < current else { continue }
            // On a final release, the pre-releases on the way are covered by the finals' notes.
            if current.prerelease == nil, version.prerelease != nil { continue }
            found.insert(version.description)
        }
        return found.compactMap(ReleaseVersion.init).sorted(by: >)
    }
}
