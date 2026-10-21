import Foundation

/// The display layout in a Wallpaper Engine `config.json`: the user's `general.wallpaperconfig`
/// (`layout`, and the `profile`'s `groups`, `splits`, `source` and `monitorconfig` flips) and
/// `general.wallpaperconfigscreensaver`.
///
/// WE names monitors by their Windows device paths, which say nothing about a Mac's displays, so
/// they are matched by order: a location `MonitorN` to the Nth connected display, any other to the
/// remaining displays (main display first) in the order of the locations' names. What can't be
/// matched (more WE monitors than displays) is skipped, a group with it too. The selected
/// wallpapers are Windows paths and aren't imported.
struct WallpaperEngineDisplayConfig {
    enum ImportError: LocalizedError, Equatable {
        case notAConfig
        case noDisplayLayout

        var errorDescription: String? {
            switch self {
            case .notAConfig: String(localized: "This file isn't a Wallpaper Engine config.json.")
            case .noDisplayLayout: String(localized: "This Wallpaper Engine config has no display layout.")
            }
        }
    }

    let layoutMode: DisplayLayoutMode
    /// Nil when the config has no `wallpaperconfigscreensaver`.
    let screenSaverLayout: ScreenSaverDisplayLayout?
    private let profile: Profile?

    init(contentsOf url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    init(data: Data) throws {
        let root: Root
        do {
            root = try JSONDecoder().decode(Root.self, from: data)
        } catch {
            OWELog.error(.importer, "Wallpaper Engine config unreadable: \(error)")
            throw ImportError.notAConfig
        }
        guard let general = root.general, let config = general.wallpaperconfig else {
            throw ImportError.noDisplayLayout
        }
        layoutMode = config.layout.flatMap(DisplayLayoutMode.init(rawValue:)) ?? .perDisplay
        profile = config.profile
        screenSaverLayout = general.wallpaperconfigscreensaver
    }

    /// The layout on the `connected` displays (main display first), WE's monitors matched by order.
    func layout(on connected: [DisplayIdentity]) -> DisplayLayoutConfiguration {
        var configuration = DisplayLayoutConfiguration()
        guard let profile else {
            configuration.layout = layoutMode
            return configuration
        }
        let identities = connected.map(\.identity)
        let displays = Self.match(profile.monitorLocations, to: identities)
        func location(_ weLocation: String) -> String? {
            let monitor = DisplayLayoutConfiguration.display(of: weLocation)
            return displays[monitor].map { $0 + weLocation.dropFirst(monitor.count) }
        }

        // Groups first: a split of a display in a group isn't kept (WE doesn't offer one there).
        for (id, group) in profile.groups.sorted(by: { $0.key < $1.key }) {
            let members = group.monitors.compactMap(location)
            guard let mode = DisplayLayoutMode(rawValue: group.layout), mode != .perDisplay,
                  members.count == group.monitors.count else {
                OWELog.info(.importer, "Wallpaper Engine group \(id) skipped: its displays can't be matched")
                continue
            }
            configuration.addGroup(members, layout: mode)
            guard mode == .clone else { continue }
            if let source = group.source.flatMap(location) {
                configuration.setCloneSource(source, isSource: true, connected: identities)
            }
            for (monitor, config) in group.monitorconfig where config.flip {
                if let display = location(monitor) { configuration.toggleFlip(display, connected: identities) }
            }
        }
        for (weLocation, split) in profile.splits {
            guard let splitLocation = location(weLocation) else { continue }
            configuration.setSplit(split, at: splitLocation)
        }
        // The clone layout's source and flips, kept for when it is chosen, as WE keeps them.
        configuration.layout = .clone
        if let source = profile.source.flatMap(location) {
            configuration.setCloneSource(source, isSource: true, connected: identities)
        }
        for (monitor, config) in profile.monitorconfig where config.flip {
            if let display = location(monitor) { configuration.toggleFlip(display, connected: identities) }
        }
        configuration.layout = layoutMode
        return configuration
    }

    /// WE's monitor locations matched to display identities: `MonitorN` to the Nth, the others in
    /// name order to the displays left.
    static func match(_ locations: Set<String>, to identities: [String]) -> [String: String] {
        var matched: [String: String] = [:]
        var taken = Set<Int>()
        for location in locations {
            guard let index = monitorIndex(location), identities.indices.contains(index) else { continue }
            matched[location] = identities[index]
            taken.insert(index)
        }
        var free = identities.indices.filter { !taken.contains($0) }.makeIterator()
        for location in locations.sorted() where matched[location] == nil && monitorIndex(location) == nil {
            guard let index = free.next() else { break }
            matched[location] = identities[index]
        }
        for location in locations.sorted() where matched[location] == nil {
            OWELog.info(.importer, "Wallpaper Engine monitor \(location) has no display to match, skipped")
        }
        return matched
    }

    private static func monitorIndex(_ location: String) -> Int? {
        guard location.hasPrefix("Monitor") else { return nil }
        return Int(location.dropFirst("Monitor".count))
    }

    // MARK: WE's format

    /// The top level: the users' objects beside other values (`?installdirectory`); the first user
    /// by name with a `wallpaperconfig` is read.
    private struct Root: Decodable {
        let general: General?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: AnyCodingKey.self)
            var found: General?
            for key in container.allKeys.sorted(by: { $0.stringValue < $1.stringValue }) {
                // Not every top-level value is a user: a value that isn't one is skipped.
                guard let user = try? container.decode(User.self, forKey: key),
                      let general = user.general, general.wallpaperconfig != nil else { continue }
                found = general
                break
            }
            general = found
        }
    }

    private struct User: Decodable {
        let general: General?
    }

    private struct General: Decodable {
        let wallpaperconfig: WallpaperConfig?
        let wallpaperconfigscreensaver: ScreenSaverDisplayLayout?

        private enum CodingKeys: String, CodingKey { case wallpaperconfig, wallpaperconfigscreensaver }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            wallpaperconfig = container.decodeLogged(WallpaperConfig.self, forKey: .wallpaperconfig,
                                                     userInfo: decoder.userInfo)
            wallpaperconfigscreensaver = container.decodeLogged(ScreenSaverDisplayLayout.self,
                                                                forKey: .wallpaperconfigscreensaver,
                                                                userInfo: decoder.userInfo)
        }
    }

    private struct WallpaperConfig: Decodable {
        let layout: Int?
        let profile: Profile?

        private enum CodingKeys: String, CodingKey { case layout, profile }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            layout = container.decodeLogged(Int.self, forKey: .layout, userInfo: decoder.userInfo)
            profile = container.decodeLogged(Profile.self, forKey: .profile, userInfo: decoder.userInfo)
        }
    }

    private struct MonitorConfig: Decodable {
        let flip: Bool

        private enum CodingKeys: String, CodingKey { case flip }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            flip = try container.decodeIfPresent(Bool.self, forKey: .flip) ?? false
        }
    }

    private struct Group: Decodable {
        let monitors: [String]
        let layout: Int
        let source: String?
        let monitorconfig: [String: MonitorConfig]

        private enum CodingKeys: String, CodingKey { case monitors, layout, source, monitorconfig }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            monitors = try container.decode([String].self, forKey: .monitors)
            layout = try container.decode(Int.self, forKey: .layout)
            source = try container.decodeIfPresent(String.self, forKey: .source)
            monitorconfig = container.decodeEntries(MonitorConfig.self, forKey: .monitorconfig,
                                                    userInfo: decoder.userInfo) ?? [:]
        }
    }

    private struct Profile: Decodable {
        let groups: [String: Group]
        let splits: [String: DisplaySplit]
        let source: String?
        let monitorconfig: [String: MonitorConfig]

        private enum CodingKeys: String, CodingKey { case groups, splits, source, monitorconfig }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // Entry by entry, so one that can't be read doesn't drop the others.
            groups = container.decodeEntries(Group.self, forKey: .groups, userInfo: decoder.userInfo) ?? [:]
            splits = container.decodeEntries(DisplaySplit.self, forKey: .splits, userInfo: decoder.userInfo) ?? [:]
            source = container.decodeLogged(String.self, forKey: .source, userInfo: decoder.userInfo)
            monitorconfig = container.decodeEntries(MonitorConfig.self, forKey: .monitorconfig,
                                                    userInfo: decoder.userInfo) ?? [:]
        }

        /// Every monitor the profile names, without region suffixes.
        var monitorLocations: Set<String> {
            var locations = Set(splits.keys.map(DisplayLayoutConfiguration.display(of:)))
            for group in groups.values {
                locations.formUnion(group.monitors.map(DisplayLayoutConfiguration.display(of:)))
                if let source = group.source { locations.insert(DisplayLayoutConfiguration.display(of: source)) }
                locations.formUnion(group.monitorconfig.keys.map(DisplayLayoutConfiguration.display(of:)))
            }
            if let source { locations.insert(DisplayLayoutConfiguration.display(of: source)) }
            locations.formUnion(monitorconfig.keys.map(DisplayLayoutConfiguration.display(of:)))
            return locations
        }
    }
}
