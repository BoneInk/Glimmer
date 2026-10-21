import Foundation

/// Workshop wallpapers and authors the user blocked (WE's "Block <author>" and its blocklist):
/// hidden from the Workshop and Discover tabs' results, and listed in Settings to unblock. Kept on
/// this Mac only; nothing is sent to Steam.
final class WorkshopBlockList: ObservableObject {
    /// A blocked wallpaper (its Workshop id and title) or author (Steam id and persona name).
    struct Entry: Codable, Equatable, Identifiable {
        let id: String
        var name: String
    }

    static let itemsKey = "WorkshopBlockedItems"
    static let authorsKey = "WorkshopBlockedAuthors"

    @Published private(set) var items: [Entry]
    @Published private(set) var authors: [Entry]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .app) {
        self.defaults = defaults
        items = Self.load(Self.itemsKey, from: defaults)
        authors = Self.load(Self.authorsKey, from: defaults)
    }

    var isEmpty: Bool { items.isEmpty && authors.isEmpty }

    /// Whether `item` is hidden: blocked itself, or made by a blocked author.
    func isBlocked(_ item: WorkshopItem) -> Bool {
        items.contains { $0.id == item.id } || item.creatorId.map(isAuthorBlocked) == true
    }

    func isAuthorBlocked(_ steamId: String) -> Bool {
        authors.contains { $0.id == steamId }
    }

    func block(_ item: WorkshopItem) {
        guard !items.contains(where: { $0.id == item.id }) else { return }
        items.append(Entry(id: item.id, name: item.title))
        save(items, Self.itemsKey)
    }

    func unblockItem(_ id: String) {
        items.removeAll { $0.id == id }
        save(items, Self.itemsKey)
    }

    func blockAuthor(_ steamId: String, name: String) {
        guard !isAuthorBlocked(steamId) else { return }
        authors.append(Entry(id: steamId, name: name))
        save(authors, Self.authorsKey)
    }

    func unblockAuthor(_ steamId: String) {
        authors.removeAll { $0.id == steamId }
        save(authors, Self.authorsKey)
    }

    private func save(_ entries: [Entry], _ key: String) {
        do {
            defaults.set(try JSONEncoder().encode(entries), forKey: key)
        } catch {
            OWELog.error(.workshop, "Can't save the Workshop block list: \(error)")
        }
    }

    /// The stored entries; a list that doesn't decode is logged and starts empty.
    private static func load(_ key: String, from defaults: UserDefaults) -> [Entry] {
        guard let data = defaults.data(forKey: key) else { return [] }
        do {
            return try JSONDecoder().decode([Entry].self, from: data)
        } catch {
            OWELog.error(.workshop, "Can't read the Workshop block list (\(key)): \(error)")
            return []
        }
    }
}
