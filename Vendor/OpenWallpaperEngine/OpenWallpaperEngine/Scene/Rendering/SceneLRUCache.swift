/// A small least-recently-used cache, capped by entry count and, optionally, by total cost (bytes).
/// Eviction scans for the oldest entry, which is fine for the hundred-odd entries it holds (it only
/// happens on insert past a cap).
///
/// The cost cap only evicts entries not used since `beginGeneration()` (the current frame), and
/// never the entry being inserted: what a frame draws stays even when it alone is over the budget,
/// so a frame never re-creates its own entries. The count cap evicts regardless, as before.
struct SceneLRUCache<Key: Hashable, Value> {
    let capacity: Int
    /// The most total cost kept across entries the current generation hasn't used.
    let costLimit: Int
    private var entries: [Key: (value: Value, lastUse: UInt64, cost: Int)] = [:]
    private var clock: UInt64 = 0
    /// Entries used at or after this tick belong to the current generation (`beginGeneration`).
    private var generationStart: UInt64 = .max
    /// The summed cost of every entry.
    private(set) var totalCost = 0

    init(capacity: Int, costLimit: Int = .max) {
        self.capacity = max(capacity, 1)
        self.costLimit = max(costLimit, 0)
    }

    var count: Int { entries.count }

    /// Starts a new generation (a frame): entries used from now on are kept past the cost cap.
    mutating func beginGeneration() { generationStart = clock &+ 1 }

    mutating func value(for key: Key) -> Value? {
        guard let entry = entries[key] else { return nil }
        clock &+= 1
        entries[key] = (entry.value, clock, entry.cost)
        return entry.value
    }

    mutating func insert(_ value: Value, for key: Key, cost: Int = 0) {
        clock &+= 1
        let cost = max(cost, 0)
        if let old = entries[key] { totalCost -= old.cost }
        entries[key] = (value, clock, cost)
        totalCost += cost
        while entries.count > capacity,
              let oldest = entries.min(by: { $0.value.lastUse < $1.value.lastUse })?.key {
            remove(oldest)
        }
        while totalCost > costLimit,
              let oldest = entries.filter({ $0.key != key && $0.value.lastUse < generationStart })
                  .min(by: { $0.value.lastUse < $1.value.lastUse })?.key {
            remove(oldest)
        }
    }

    mutating func removeAll() {
        entries.removeAll(keepingCapacity: true)
        totalCost = 0
    }

    /// Keeps only the `count` most recently used entries (memory pressure).
    mutating func trim(to count: Int) {
        guard entries.count > count else { return }
        let kept = entries.sorted { $0.value.lastUse > $1.value.lastUse }.prefix(max(count, 0))
        entries = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
        totalCost = entries.values.reduce(0) { $0 + $1.cost }
    }

    private mutating func remove(_ key: Key) {
        if let removed = entries.removeValue(forKey: key) { totalCost -= removed.cost }
    }
}
