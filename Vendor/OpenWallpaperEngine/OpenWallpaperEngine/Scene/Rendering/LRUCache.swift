/// A dictionary that keeps at most `capacity` entries, evicting the least recently used. Not
/// thread-safe: its owner's lock guards it.
///
/// Recency is a counter per entry; eviction drops the oldest eighth at once, so inserting past the
/// cap costs O(n log n) once every n/8 inserts instead of a scan per insert.
struct LRUCache<Value> {
    let capacity: Int
    private var entries: [String: (value: Value, used: UInt64)] = [:]
    private var clock: UInt64 = 0

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    var count: Int { entries.count }

    /// The value, marked as just used.
    mutating func value(forKey key: String) -> Value? {
        guard let entry = entries[key] else { return nil }
        clock &+= 1
        entries[key] = (entry.value, clock)
        return entry.value
    }

    func contains(_ key: String) -> Bool { entries[key] != nil }

    /// Stores `value` as just used; returns the keys evicted to stay within `capacity`.
    @discardableResult
    mutating func insert(_ value: Value, forKey key: String) -> [String] {
        clock &+= 1
        entries[key] = (value, clock)
        guard entries.count > capacity else { return [] }
        let excess = entries.count - capacity
        let batch = min(entries.count - 1, max(excess, capacity / 8))
        let evicted = entries.filter { $0.key != key }.sorted { $0.value.used < $1.value.used }.prefix(batch).map(\.key)
        for old in evicted { entries[old] = nil }
        return evicted
    }

    /// Keeps only the entries whose key passes `isIncluded`.
    mutating func keep(where isIncluded: (String) -> Bool) {
        entries = entries.filter { isIncluded($0.key) }
    }
}
