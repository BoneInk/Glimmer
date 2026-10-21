import CoreGraphics

/// The display layout (`DisplayLayoutConfiguration`) on the displays connected now, by display id:
/// which displays clone or stretch with which, the canvas each stretched display shows its part
/// of, the regions split displays are divided into, which displays are flipped or muted, and the
/// groups to outline.
///
/// A clone or a stretch shows its source display's wallpaper on every member through the one
/// running instance (`WallpaperViewModel.instanceKey(for:)`), as WE renders a clone or a span
/// once: a clone member places the whole frame at its own size (mirrored when flipped), a stretch
/// member shows its rect of the canvas (`canvases`). A group with fewer than two connected
/// displays is dormant and changes nothing.
///
/// A split display's regions (`regions`) are displays of their own, named `<display id>/L`,
/// `<display id>/L/R`… as WE names them: each has its own wallpaper and view. The display itself
/// shows nothing of its own while it is split.
struct DisplayLayoutResolution: Equatable {
    /// A clone on the connected displays.
    struct Clone: Equatable, Identifiable {
        /// The group's id; `DisplayLayoutResolution.globalCloneID` for the clone layout.
        let id: String
        /// Member display ids, in the group's order.
        let screens: [String]
        let source: String
    }

    /// A stretch on the connected displays: one wallpaper over `canvas`.
    struct Stretch: Equatable, Identifiable {
        /// The group's id; `DisplayLayoutResolution.globalStretchID` for the stretch layout.
        let id: String
        /// Member display ids, in the group's order.
        let screens: [String]
        /// The display whose selection the stretch shows: its first connected member.
        let source: String
        /// The members' bounding box in global points (`DisplayCanvas`).
        let canvas: CGRect
    }

    /// A region of a split display, a display of its own.
    struct Region: Equatable, Identifiable {
        /// `<display id><path>`, what its wallpaper and playback are keyed by.
        let id: String
        /// The split display's id.
        let screen: String
        /// Its location in the layout: `<identity><path>` (WE's `<location>/L…`).
        let location: String
        /// Its rect in global desktop points.
        let rect: CGRect
    }

    static let globalCloneID = "clone"
    static let globalStretchID = "stretch"

    /// Each member display's source display (a clone's main display, a stretch's first member),
    /// for the members that aren't it.
    private(set) var sources: [String: String] = [:]
    private(set) var clones: [Clone] = []
    private(set) var stretches: [Stretch] = []
    /// Each stretched display's canvas.
    private(set) var canvases: [String: CGRect] = [:]
    /// Each split display's regions, first regions first.
    private(set) var regions: [String: [Region]] = [:]
    private(set) var flipped: Set<String> = []
    private(set) var muted: Set<String> = []

    static let empty = DisplayLayoutResolution()

    private init() {}

    init(_ configuration: DisplayLayoutConfiguration, displays: [DisplayIdentity]) {
        let screenIds = Dictionary(displays.map { ($0.identity, $0.screenId) }, uniquingKeysWith: { first, _ in first })
        let frames = Dictionary(displays.map { ($0.identity, $0.frame) }, uniquingKeysWith: { first, _ in first })
        let connected = displays.map(\.identity)
        let connectedSet = Set(connected)
        muted = Set(configuration.muted.compactMap { screenIds[$0] })

        var cloneGroups: [(id: String, group: DisplayGroup)] = []
        var stretchGroups: [(id: String, group: DisplayGroup)] = []
        switch configuration.layout {
        case .clone:
            if let first = connected.first, let clone = configuration.clone(containing: first, connected: connected) {
                cloneGroups.append((Self.globalCloneID, clone))
            }
        case .stretch:
            stretchGroups.append((Self.globalStretchID, DisplayGroup(members: connected, layout: .stretch)))
        case .perDisplay:
            for group in configuration.groups {
                switch group.layout {
                case .clone: cloneGroups.append((group.id, group))
                case .stretch: stretchGroups.append((group.id, group))
                case .perDisplay: break
                }
            }
        }
        for (id, group) in cloneGroups {
            let members = group.members.filter(connectedSet.contains)
            guard members.count >= 2, let main = group.mainDisplay(connected: connectedSet),
                  let source = screenIds[main] else { continue }
            let screens = members.compactMap { screenIds[$0] }
            clones.append(Clone(id: id, screens: screens, source: source))
            for member in members where member != main {
                guard let screen = screenIds[member] else { continue }
                sources[screen] = source
                if group.flipped.contains(member) { flipped.insert(screen) }
            }
        }
        for (id, group) in stretchGroups {
            let members = group.members.filter(connectedSet.contains)
            guard members.count >= 2, let source = screenIds[members[0]] else { continue }
            let screens = members.compactMap { screenIds[$0] }
            let canvas = DisplayCanvas.bounds(of: members.compactMap { frames[$0] })
            stretches.append(Stretch(id: id, screens: screens, source: source, canvas: canvas))
            for screen in screens {
                canvases[screen] = canvas
                if screen != source { sources[screen] = source }
            }
        }
        // Splits only divide displays shown on their own (WE skips grouped ones).
        guard configuration.layout == .perDisplay else { return }
        let grouped = Set(clones.flatMap(\.screens) + stretches.flatMap(\.screens))
        for display in displays where !grouped.contains(display.screenId) {
            let splits = configuration.splits(of: display.identity)
            guard !splits.isEmpty else { continue }
            regions[display.screenId] = DisplaySplitLayout.regions(of: display.frame, splits: splits).map {
                Region(id: display.screenId + $0.path, screen: display.screenId,
                       location: display.identity + $0.path, rect: $0.rect)
            }
        }
    }

    /// The display whose wallpaper `screenId` shows: its clone's or stretch's source, or itself.
    func source(of screenId: String) -> String { sources[screenId] ?? screenId }

    /// The physical display a display id or region id is on.
    static func screen(of id: String) -> String {
        guard let slash = id.firstIndex(of: "/") else { return id }
        return String(id[..<slash])
    }

    /// Every display that shows a wallpaper of its own or of its group: each display, a split one
    /// replaced by its regions.
    func shownDisplays(_ screenIds: [String]) -> [String] {
        screenIds.flatMap { screen in regions[screen].map { $0.map(\.id) } ?? [screen] }
    }

    /// Where a wallpaper set on `screenIds` goes: a split display's regions, and each clone or
    /// stretch member's source display (so every member shows it, and the members' own
    /// selections stay for when they leave).
    func targets(of screenIds: Set<String>) -> Set<String> {
        Set(shownDisplays(Array(screenIds)).map(source(of:)))
    }

    /// What each display of `selections` (each display's or region's own) shows: a clone or
    /// stretch member its source's, a region its own, the others their own. A split display shows
    /// nothing of its own, and a region of a split that is gone shows nothing.
    func shown<Wallpaper>(_ selections: [String: Wallpaper]) -> [String: Wallpaper] {
        var shown = selections
        for (member, source) in sources { shown[member] = selections[source] }
        let regionIds = Set(regions.values.flatMap { $0.map(\.id) })
        for id in selections.keys where id.contains("/") && !regionIds.contains(id) { shown[id] = nil }
        for screen in regions.keys { shown[screen] = nil }
        return shown
    }

    /// The clone `screenId` is part of.
    func clone(containing screenId: String) -> Clone? {
        clones.first { $0.screens.contains(screenId) }
    }

    /// The stretch `screenId` is part of.
    func stretch(containing screenId: String) -> Stretch? {
        stretches.first { $0.screens.contains(screenId) }
    }

    /// The display whose web page `screenId` mirrors: its clone's or stretch's source, while that
    /// display is `shown` (its window shows the page). Nil for the source itself, a display in no
    /// group, or a group whose source shows nothing: such a display loads its own page.
    func pageSource(of screenId: String, shown: Set<String>) -> String? {
        guard let source = clone(containing: screenId)?.source ?? stretch(containing: screenId)?.source,
              source != screenId, shown.contains(source) else { return nil }
        return source
    }

    /// The shown displays that show `screenId`'s page: itself and, when it is a group's source,
    /// the members mirroring it (`pageSource`). Its pause and sound follow all of them.
    func pageMembers(of screenId: String, shown: Set<String>) -> [String] {
        let group = clone(containing: screenId)?.screens ?? stretch(containing: screenId)?.screens ?? []
        return [screenId] + group.filter {
            $0 != screenId && shown.contains($0) && pageSource(of: $0, shown: shown) == screenId
        }
    }

    /// The region with id `id`.
    func region(_ id: String) -> Region? {
        regions[Self.screen(of: id)]?.first { $0.id == id }
    }

    /// `screenIds` and every display that shares a clone or stretch with one of them.
    func expandingClones(_ screenIds: Set<String>) -> Set<String> {
        var result = screenIds
        for clone in clones where !screenIds.isDisjoint(with: clone.screens) { result.formUnion(clone.screens) }
        for stretch in stretches where !screenIds.isDisjoint(with: stretch.screens) { result.formUnion(stretch.screens) }
        return result
    }
}
