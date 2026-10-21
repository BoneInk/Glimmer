import Foundation

/// How wallpapers change over: WE's playlist transition settings (`settings.transition`,
/// `transitionpool`, `transitiontime`), and the same three for wallpapers chosen by hand
/// (`browsetransition`, Settings › General). Stored under WE's keys and values.
struct WallpaperTransitionSettings: Codable, Equatable, Sendable {
    /// WE's `transition`: "-2", "none", "random" or a kind's id.
    enum Choice: Equatable, Hashable, Sendable {
        /// WE's "None (reduce flicker)" ("-2"), what WE shows when a playlist has no setting.
        case noneReducingFlicker
        /// WE's "None" ("none").
        case none
        /// WE's "Random" ("random"): a kind from `pool` each time.
        case random
        case kind(WallpaperTransitionKind)

        var storedValue: String {
            switch self {
            case .noneReducingFlicker: return "-2"
            case .none: return "none"
            case .random: return "random"
            case .kind(let kind): return kind.storedValue
            }
        }

        /// WE's values; WE's older `true` (a fade) arrives as "0" through `init(from:)`.
        init?(storedValue: String) {
            switch storedValue {
            case "-2": self = .noneReducingFlicker
            case "none": self = .none
            case "random": self = .random
            default:
                guard let kind = WallpaperTransitionKind(storedValue: storedValue) else { return nil }
                self = .kind(kind)
            }
        }
    }

    var choice: Choice
    /// The kinds Random picks from, in the order they were added; nil: every kind (WE removes
    /// `transitionpool` when every kind is in it).
    var pool: [WallpaperTransitionKind]?
    /// WE's `transitiontime`, in milliseconds: 0 to 3000 in steps of 50.
    var milliseconds: Int

    static let millisecondRange = 0...3000
    static let millisecondStep = 50

    /// A new playlist's (WE's playlist defaults: a fade of 1500 ms).
    static let playlistDefault = WallpaperTransitionSettings(choice: .kind(.fade), pool: nil, milliseconds: 1500)
    /// A playlist saved without transition settings, and wallpapers chosen by hand until the user
    /// picks one: WE's dialog shows "None (reduce flicker)" and 1000 ms then.
    static let unset = WallpaperTransitionSettings(choice: .noneReducingFlicker, pool: nil, milliseconds: 1000)

    init(choice: Choice, pool: [WallpaperTransitionKind]? = nil, milliseconds: Int) {
        self.choice = choice
        self.pool = pool
        self.milliseconds = Self.snapped(milliseconds)
    }

    var duration: TimeInterval { TimeInterval(milliseconds) / 1000 }

    /// Snapped to the slider's 50 ms steps, within its range.
    static func snapped(_ milliseconds: Int) -> Int {
        let clamped = min(max(milliseconds, millisecondRange.lowerBound), millisecondRange.upperBound)
        return (clamped + millisecondStep / 2) / millisecondStep * millisecondStep
    }

    /// The kinds Random picks from.
    var poolKinds: [WallpaperTransitionKind] { pool ?? WallpaperTransitionKind.menuOrder }

    func isInPool(_ kind: WallpaperTransitionKind) -> Bool { pool?.contains(kind) ?? true }

    /// WE's pool toggle (`transitionPoolToggle`): taking a kind out of the full pool lists the
    /// others; adding the last missing one makes it the full pool again.
    mutating func togglePool(_ kind: WallpaperTransitionKind) {
        if var kinds = pool {
            if let index = kinds.firstIndex(of: kind) {
                kinds.remove(at: index)
            } else {
                kinds.append(kind)
            }
            pool = Set(kinds) == Set(WallpaperTransitionKind.allCases) ? nil : kinds
        } else {
            pool = WallpaperTransitionKind.menuOrder.filter { $0 != kind }
        }
    }

    /// WE's Enable all / Disable all.
    mutating func setWholePool(_ enabled: Bool) {
        pool = enabled ? nil : []
    }

    /// The transition the next change shows; nil for none (no transition, a zero time, or Random
    /// with an empty pool).
    func pick(random: (Range<Int>) -> Int = { Int.random(in: $0) }) -> WallpaperTransitionKind? {
        guard milliseconds > 0 else { return nil }
        switch choice {
        case .noneReducingFlicker, .none: return nil
        case .kind(let kind): return kind
        case .random:
            let kinds = poolKinds
            return kinds.isEmpty ? nil : kinds[random(0..<kinds.count)]
        }
    }

    // MARK: - WE's keys

    private enum CodingKeys: String, CodingKey {
        case transition, transitionpool, transitiontime
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // WE's dialog: `true` is a fade, anything else that isn't a string is "-2". The Bool is an
        // optional reading of the key, which is usually a string.
        if let flag = try? container.decodeIfPresent(Bool.self, forKey: .transition) {
            choice = flag ? .kind(.fade) : .noneReducingFlicker
        } else if let value = try container.decodeIfPresent(String.self, forKey: .transition) {
            choice = Choice(storedValue: value) ?? .noneReducingFlicker
        } else {
            choice = .noneReducingFlicker
        }
        if let values = try container.decodeIfPresent([String].self, forKey: .transitionpool) {
            pool = values.compactMap(WallpaperTransitionKind.init(storedValue:))
        } else {
            pool = nil
        }
        milliseconds = Self.snapped(try container.decodeIfPresent(Int.self, forKey: .transitiontime) ?? 1000)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(choice.storedValue, forKey: .transition)
        try container.encodeIfPresent(pool?.map(\.storedValue), forKey: .transitionpool)
        try container.encode(milliseconds, forKey: .transitiontime)
    }
}
