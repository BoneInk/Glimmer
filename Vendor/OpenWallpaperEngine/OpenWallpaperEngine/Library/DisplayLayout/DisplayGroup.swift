import Foundation

/// A stretch or clone group of some of the displays, beside the per-display wallpapers of the
/// others: WE's `profile.groups["group_" + hash(locations)]` under the "Wallpaper per display"
/// layout, `{monitors, layout, source, monitorconfig: {location: {flip}}}`.
///
/// Members are display identities (`DisplayIdentity`), which stay the same across reboots and
/// reconnections, unlike a display's id. A group whose displays aren't connected (fewer than two
/// of them) is dormant: it is kept, and comes back when they are.
struct DisplayGroup: Codable, Hashable, Identifiable {
    /// The member displays, in the order they joined: the first is the main clone display unless
    /// `source` names another.
    private(set) var members: [String]
    var layout: DisplayLayoutMode
    /// The main clone display, whose wallpaper the others show; nil: the first member.
    private(set) var source: String?
    /// The members that show the clone mirrored horizontally. Never the main clone display, so at
    /// least one member always shows the wallpaper as it is (WE's flip limitation).
    private(set) var flipped: Set<String>

    init(members: [String], layout: DisplayLayoutMode, source: String? = nil, flipped: Set<String> = []) {
        var unique: [String] = []
        for member in members where !unique.contains(member) { unique.append(member) }
        self.members = unique
        self.layout = layout
        self.source = source.flatMap { unique.contains($0) ? $0 : nil }
        self.flipped = flipped.intersection(unique)
        self.flipped.remove(mainDisplay ?? "")
    }

    /// `"group_" + hash`, from the members whatever their order, the same on every launch.
    var id: String { Self.id(for: members) }

    static func id(for members: [String]) -> String {
        // FNV-1a over the sorted identities: Swift's `Hasher` is seeded per process.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in members.sorted().joined(separator: "\n").utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return "group_" + String(hash, radix: 16)
    }

    /// The main clone display among all the members.
    var mainDisplay: String? { source ?? members.first }

    /// The main clone display among the `connected` members: the chosen one, else the first.
    func mainDisplay(connected: Set<String>) -> String? {
        if let source, connected.contains(source) { return source }
        return members.first(where: connected.contains)
    }

    /// Makes `display` the main clone display; it is no longer flipped.
    mutating func setSource(_ display: String?) {
        guard let display else { source = nil; return }
        guard members.contains(display) else { return }
        source = display
        flipped.remove(display)
    }

    /// Flips `display` or turns its flip off. False, and nothing changes, for the main clone
    /// display, which can't be flipped.
    @discardableResult
    mutating func toggleFlip(_ display: String) -> Bool {
        guard members.contains(display), display != mainDisplay else { return false }
        if flipped.remove(display) == nil { flipped.insert(display) }
        return true
    }

    /// Takes `display` out; the main clone display falls back to the first member when it was it.
    mutating func remove(_ display: String) {
        members.removeAll { $0 == display }
        flipped.remove(display)
        if source == display { source = nil }
        flipped.remove(mainDisplay ?? "")
    }

    private enum CodingKeys: String, CodingKey { case members, layout, source, flipped }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(members: try container.decode([String].self, forKey: .members),
                  layout: try container.decode(DisplayLayoutMode.self, forKey: .layout),
                  source: try container.decodeIfPresent(String.self, forKey: .source),
                  flipped: try container.decodeIfPresent(Set<String>.self, forKey: .flipped) ?? [])
    }
}
