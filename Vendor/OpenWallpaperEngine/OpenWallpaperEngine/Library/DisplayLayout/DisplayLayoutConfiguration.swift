import Foundation

/// The user's display layout, as WE keeps it (`wallpaperconfig.layout`, the profile's `groups`
/// and `splits`, each monitor's flip and mute), saved in the app's defaults. Every display is
/// named by its identity (`DisplayIdentity`). Without a saved layout every display shows its own
/// wallpaper, so the per-display wallpapers saved before layouts existed show as they did.
struct DisplayLayoutConfiguration: Codable, Equatable {
    static let defaultsKey = "DisplayLayout"

    var layout: DisplayLayoutMode = .perDisplay
    /// Clone and stretch groups of some displays, used under `.perDisplay` only.
    private(set) var groups: [DisplayGroup] = []
    /// Splits of displays into regions (WE's `profile.splits`), keyed by location: a display's
    /// identity, or a region's (`<identity>/L`, `<identity>/L/R`…). Used under `.perDisplay` only,
    /// on displays in no group.
    private(set) var splits: [String: DisplaySplit] = [:]
    /// The clone layout's main display; nil: the first connected display (the main one).
    private(set) var cloneSource: String?
    /// The displays the clone layout shows mirrored.
    private(set) var cloneFlipped: Set<String> = []
    /// Displays whose wallpaper's sound is muted (WE mutes per display).
    private(set) var muted: Set<String> = []

    init(layout: DisplayLayoutMode = .perDisplay) {
        self.layout = layout
    }

    // MARK: Groups

    /// The group `display` belongs to.
    func group(containing display: String) -> DisplayGroup? {
        groups.first { $0.members.contains(display) }
    }

    /// Groups `displays` into a clone or stretch group (at least two). They leave the groups they
    /// were in, and a group left with fewer than two displays is removed. A stretch group removes
    /// its displays' splits, as WE's does (a clone group keeps them, unused while it lasts).
    mutating func addGroup(_ displays: [String], layout: DisplayLayoutMode) {
        let group = DisplayGroup(members: displays, layout: layout)
        guard group.members.count >= 2, layout != .perDisplay else { return }
        for display in group.members { removeFromGroup(display) }
        if layout == .stretch {
            for display in group.members { removeAllSplits(of: display) }
        }
        groups.append(group)
    }

    /// Takes `display` out of its group; a group left with one display is removed. A display that
    /// is only disconnected stays in its group (`DisplayLayoutResolution` leaves it dormant).
    mutating func removeFromGroup(_ display: String) {
        guard let index = groups.firstIndex(where: { $0.members.contains(display) }) else { return }
        groups[index].remove(display)
        if groups[index].members.count < 2 { groups.remove(at: index) }
    }

    mutating func removeGroup(id: String) {
        groups.removeAll { $0.id == id }
    }

    // MARK: Clone source and flip

    /// The clone that `display` is part of among the `connected` displays: the clone layout's
    /// (every connected display), or its clone group's under the per-display layout.
    func clone(containing display: String, connected: [String]) -> DisplayGroup? {
        switch layout {
        case .clone:
            guard connected.contains(display) else { return nil }
            return DisplayGroup(members: connected, layout: .clone, source: cloneSource, flipped: cloneFlipped)
        case .perDisplay:
            return group(containing: display).flatMap { $0.layout == .clone ? $0 : nil }
        case .stretch:
            return nil
        }
    }

    /// Makes `display` the main clone display of its clone (nil: back to the first display).
    mutating func setCloneSource(_ display: String, isSource: Bool, connected: [String]) {
        updateClone(containing: display, connected: connected) { $0.setSource(isSource ? display : nil) }
    }

    /// Flips `display` or turns its flip off. False when it is its clone's main display, which
    /// can't be flipped, or isn't in a clone.
    @discardableResult
    mutating func toggleFlip(_ display: String, connected: [String]) -> Bool {
        var changed = false
        updateClone(containing: display, connected: connected) { changed = $0.toggleFlip(display) }
        return changed
    }

    private mutating func updateClone(containing display: String, connected: [String],
                                      _ change: (inout DisplayGroup) -> Void) {
        switch layout {
        case .clone:
            guard var clone = clone(containing: display, connected: connected) else { return }
            change(&clone)
            cloneSource = clone.source
            // Flips of displays not connected now stay for when they are.
            cloneFlipped = clone.flipped.union(cloneFlipped.subtracting(connected))
            cloneFlipped.remove(clone.mainDisplay ?? "")
        case .perDisplay:
            guard let index = groups.firstIndex(where: { $0.members.contains(display) }),
                  groups[index].layout == .clone else { return }
            change(&groups[index])
        case .stretch:
            return
        }
    }

    // MARK: Splits

    /// The splits below `display`, keyed by path (`""` the display itself, `/L`…).
    func splits(of display: String) -> [String: DisplaySplit] {
        var result: [String: DisplaySplit] = [:]
        for (location, split) in splits {
            guard let path = Self.path(of: location, below: display) else { continue }
            result[path] = split
        }
        return result
    }

    /// Splits the display or region at `location` (`<identity>` or `<identity>/L…`), or changes its
    /// split. A display in a group isn't split (WE doesn't offer it).
    mutating func setSplit(_ split: DisplaySplit, at location: String) {
        guard group(containing: Self.display(of: location)) == nil else { return }
        splits[location] = split
    }

    /// WE's "Remove Split" on a region: the split it came from goes, with every split inside it.
    /// Nothing for a display that isn't a region of a split.
    mutating func removeSplit(containing region: String) {
        guard region.hasSuffix(DisplaySplit.first) || region.hasSuffix(DisplaySplit.second) else { return }
        let parent = String(region.dropLast(DisplaySplit.first.count))
        removeSplits(below: parent)
        splits[parent] = nil
    }

    /// WE's "Remove All Splits": `display` is one region again.
    mutating func removeAllSplits(of display: String) {
        removeSplits(below: display)
        splits[display] = nil
    }

    private mutating func removeSplits(below location: String) {
        for key in splits.keys where key != location && Self.path(of: key, below: location) != nil {
            splits[key] = nil
        }
    }

    /// The display a location names: the identity before its first region suffix.
    static func display(of location: String) -> String {
        guard let slash = location.firstIndex(of: "/") else { return location }
        return String(location[..<slash])
    }

    /// `location`'s path below `ancestor` (`""` when they're the same), or nil when it isn't below it.
    private static func path(of location: String, below ancestor: String) -> String? {
        guard location.hasPrefix(ancestor) else { return nil }
        let rest = location.dropFirst(ancestor.count)
        guard rest.isEmpty || rest.hasPrefix("/") else { return nil }
        // WE's own check: the rest is only region steps.
        guard rest.allSatisfy({ $0 == "/" || $0 == "L" || $0 == "R" }) else { return nil }
        return String(rest)
    }

    // MARK: Mute

    func isMuted(_ display: String) -> Bool { muted.contains(display) }

    mutating func toggleMute(_ display: String) {
        if muted.remove(display) == nil { muted.insert(display) }
    }

    // MARK: Persistence

    static func load(from defaults: UserDefaults) -> DisplayLayoutConfiguration {
        guard let data = defaults.data(forKey: defaultsKey) else { return DisplayLayoutConfiguration() }
        do {
            return try JSONDecoder().decode(DisplayLayoutConfiguration.self, from: data)
        } catch {
            OWELog.error(.app, "Display layout unreadable, using a wallpaper per display: \(error)")
            return DisplayLayoutConfiguration()
        }
    }

    func save(to defaults: UserDefaults) {
        do {
            defaults.set(try JSONEncoder().encode(self), forKey: Self.defaultsKey)
        } catch {
            OWELog.error(.app, "Display layout not saved: \(error)")
        }
    }

    private enum CodingKeys: String, CodingKey { case layout, groups, cloneSource, cloneFlipped, muted, splits }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        layout = try container.decodeIfPresent(DisplayLayoutMode.self, forKey: .layout) ?? .perDisplay
        cloneSource = try container.decodeIfPresent(String.self, forKey: .cloneSource)
        cloneFlipped = try container.decodeIfPresent(Set<String>.self, forKey: .cloneFlipped) ?? []
        muted = try container.decodeIfPresent(Set<String>.self, forKey: .muted) ?? []
        // Split by split, so one that can't be read doesn't drop the others.
        splits = container.decodeEntries(DisplaySplit.self, forKey: .splits, userInfo: decoder.userInfo) ?? [:]
        // Group by group, so one that can't be read doesn't drop the others.
        groups = container.decodeElements(DisplayGroup.self, forKey: .groups, userInfo: decoder.userInfo) ?? []
    }
}
