//
//  UnavailableWorkshopItemStore.swift
//  Open Wallpaper Engine
//
//  Workshop items found removed, private, banned or from another app, with when that was found,
//  so later loads don't ask steamcmd for them again. An entry is checked again after
//  `recheckInterval`, or at once when the user asks to retry. Kept as a small JSON file in the
//  app's support folder (`AppStorageLocation`), so isolated copies and tests keep their own.
//

import Foundation

final class UnavailableWorkshopItemStore {
    struct Entry: Codable, Equatable {
        let reason: WorkshopItemAvailability.Reason
        let checkedAt: Date
    }

    /// How long an unavailable item is skipped before it is checked again.
    static let recheckInterval: TimeInterval = 7 * 24 * 60 * 60

    static var defaultFileURL: URL {
        AppStorageLocation.current.supportDirectory.appending(path: "UnavailableWorkshopItems.json")
    }

    let fileURL: URL
    private let now: () -> Date
    private let lock = NSLock()
    /// Guarded by `lock`, which is also held while the file is written, so writes land in order.
    private var entries: [String: Entry]

    init(fileURL: URL = UnavailableWorkshopItemStore.defaultFileURL, now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        self.now = now
        entries = Self.load(from: fileURL)
    }

    /// The reason `id` is skipped, while its entry is younger than `recheckInterval`.
    func skipReason(for id: String) -> WorkshopItemAvailability.Reason? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[id], now().timeIntervalSince(entry.checkedAt) < Self.recheckInterval else { return nil }
        return entry.reason
    }

    func record(_ id: String, reason: WorkshopItemAvailability.Reason) {
        lock.lock()
        defer { lock.unlock() }
        entries[id] = Entry(reason: reason, checkedAt: now())
        save(entries)
    }

    /// Drops `ids`, so the next load checks them again.
    func forget(_ ids: some Sequence<String>) {
        lock.lock()
        defer { lock.unlock() }
        var changed = false
        for id in ids where entries.removeValue(forKey: id) != nil { changed = true }
        if changed { save(entries) }
    }

    private static func load(from url: URL) -> [String: Entry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        do {
            return try JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: url))
        } catch {
            OWELog.error(.workshop, "Reading the unavailable Workshop items at \(url.path) failed: \(error)")
            return [:]
        }
    }

    private func save(_ entries: [String: Entry]) {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: fileURL, options: .atomic)
        } catch {
            OWELog.error(.workshop, "Writing the unavailable Workshop items at \(fileURL.path) failed: \(error)")
        }
    }
}
