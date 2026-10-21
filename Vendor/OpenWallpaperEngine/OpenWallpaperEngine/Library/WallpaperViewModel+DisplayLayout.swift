import Foundation

/// The display layout's side of the displays' wallpapers (docs/architecture.md "Display layouts"):
/// the Displays sheet changes it by display id, the model keeps it by display identity.
extension WallpaperViewModel {
    /// Resolves the layout on the connected displays (a clone member then shows its main display's
    /// wallpaper, `wallpaper(for:)`, its own selection untouched) and regroups the instances and
    /// the displays' playback.
    func refreshDisplayLayout() {
        let resolution = DisplayLayoutResolution(displayLayout, displays: connectedDisplays())
        if resolution != layoutResolution { layoutResolution = resolution }
        refreshInstanceKeys()
        refreshDisplayPlayback()
    }

    // MARK: Changes from the Displays sheet, by display id

    private func identity(of screenId: String) -> String? {
        connectedDisplays().first { $0.screenId == screenId }?.identity
    }

    private var connectedIdentities: [String] { connectedDisplays().map(\.identity) }

    func setLayout(_ layout: DisplayLayoutMode) {
        displayLayout.layout = layout
    }

    /// Groups `screenIds` (at least two) into a clone group.
    func addCloneGroup(_ screenIds: Set<String>) {
        addGroup(screenIds, layout: .clone)
    }

    /// Groups `screenIds` (at least two) into a stretch group: one wallpaper over their canvas.
    func addStretchGroup(_ screenIds: Set<String>) {
        addGroup(screenIds, layout: .stretch)
    }

    /// Regions stand for their display: a group takes whole displays.
    private func addGroup(_ screenIds: Set<String>, layout: DisplayLayoutMode) {
        let screens = Set(screenIds.map(DisplayLayoutResolution.screen(of:)))
        let displays = connectedDisplays().filter { screens.contains($0.screenId) }.map(\.identity)
        displayLayout.addGroup(displays, layout: layout)
    }

    func removeFromGroup(_ screenId: String) {
        guard let display = identity(of: screenId) else { return }
        displayLayout.removeFromGroup(display)
    }

    /// WE's "Remove Group": every display of `screenId`'s group shows its own wallpaper again.
    func removeGroup(containing screenId: String) {
        guard let display = identity(of: screenId), let group = displayLayout.group(containing: display) else { return }
        displayLayout.removeGroup(id: group.id)
    }

    /// Whether `screenId` is in a stretch (a group, or every display under the stretch layout).
    func isStretched(_ screenId: String) -> Bool {
        layoutResolution.stretch(containing: screenId) != nil
    }

    /// Whether `screenId` is in a clone (a group, or every display under the clone layout).
    func isCloned(_ screenId: String) -> Bool {
        layoutResolution.clone(containing: screenId) != nil
    }

    /// Whether `screenId` is its clone's main display.
    func isMainCloneDisplay(_ screenId: String) -> Bool {
        layoutResolution.clone(containing: screenId)?.source == screenId
    }

    /// Whether `screenId` is the main display the user chose (rather than the first by default).
    func isChosenMainCloneDisplay(_ screenId: String) -> Bool {
        guard let display = identity(of: screenId),
              let clone = displayLayout.clone(containing: display, connected: connectedIdentities) else { return false }
        return clone.source == display
    }

    func setMainCloneDisplay(_ screenId: String, _ isMain: Bool) {
        guard let display = identity(of: screenId) else { return }
        displayLayout.setCloneSource(display, isSource: isMain, connected: connectedIdentities)
    }

    func isFlipped(_ screenId: String) -> Bool { layoutResolution.flipped.contains(screenId) }

    /// Flips `screenId`'s clone or turns it off; false for a clone's main display, which can't be.
    @discardableResult
    func toggleFlip(_ screenId: String) -> Bool {
        guard let display = identity(of: screenId) else { return false }
        return displayLayout.toggleFlip(display, connected: connectedIdentities)
    }

    func isMuted(_ screenId: String) -> Bool {
        layoutResolution.muted.contains(DisplayLayoutResolution.screen(of: screenId))
    }

    func toggleMute(_ screenId: String) {
        guard let display = identity(of: DisplayLayoutResolution.screen(of: screenId)) else { return }
        displayLayout.toggleMute(display)
    }

    // MARK: Splits (a display or a region, by id)

    /// The layout location of a display or region id (`<identity><path>`).
    private func location(of id: String) -> String? {
        let screen = DisplayLayoutResolution.screen(of: id)
        guard let display = identity(of: screen) else { return nil }
        return display + id.dropFirst(screen.count)
    }

    /// The rect of a display or region id in global points.
    func displayRect(of id: String) -> CGRect? {
        if let region = layoutResolution.region(id) { return region.rect }
        return connectedDisplays().first { $0.screenId == id }?.frame
    }

    /// Whether `id` (a display or a region) can be split: under a wallpaper per display, outside
    /// any group (WE doesn't offer it there), and at least two points along one side.
    func canSplit(_ id: String) -> Bool {
        guard displayLayout.layout == .perDisplay, let location = location(of: id),
              displayLayout.group(containing: DisplayLayoutConfiguration.display(of: location)) == nil,
              let rect = displayRect(of: id) else { return false }
        return rect.width >= 2 || rect.height >= 2
    }

    /// Whether `id` is a region of a split display.
    func isSplitRegion(_ id: String) -> Bool { layoutResolution.region(id) != nil }

    /// Splits `id` (a display or a region) into two regions; the first takes what it showed, as
    /// WE moves the wallpaper to the new left region. The position is kept a point inside.
    func split(_ id: String, _ split: DisplaySplit) {
        guard canSplit(id), let location = location(of: id), let rect = displayRect(of: id) else { return }
        let extent = split.direction == .vertical ? rect.width : rect.height
        guard let position = DisplaySplit.clampedPosition(split.position, extent: extent) else { return }
        let shown = wallpapers[id]
        displayLayout.setSplit(DisplaySplit(direction: split.direction, position: position), at: location)
        let first = id + DisplaySplit.first
        if wallpapers[first] == nil, let shown { wallpapers[first] = shown }
        if selectedScreenIds.contains(id) {
            selectedScreenIds.remove(id)
            selectedScreenIds.insert(first)
        }
        if selectedScreenId == id { selectedScreenId = first }
    }

    /// The split `region` came from, to edit (WE's "Edit Split"), with the region it divides.
    func parentSplit(of region: String) -> (id: String, split: DisplaySplit)? {
        guard isSplitRegion(region), let location = location(of: region) else { return nil }
        let parentLocation = String(location.dropLast(DisplaySplit.first.count))
        let parent = String(region.dropLast(DisplaySplit.first.count))
        return displayLayout.splits[parentLocation].map { (parent, $0) }
    }

    /// Changes the split that divides `parent` (a display or region id).
    func editSplit(_ parent: String, _ split: DisplaySplit) {
        guard let location = location(of: parent), displayLayout.splits[location] != nil,
              let rect = splitRect(of: parent) else { return }
        let extent = split.direction == .vertical ? rect.width : rect.height
        guard let position = DisplaySplit.clampedPosition(split.position, extent: extent) else { return }
        displayLayout.setSplit(DisplaySplit(direction: split.direction, position: position), at: location)
    }

    /// The rect of a display or any of its regions, leaf or split, in global points.
    func splitRect(of id: String) -> CGRect? {
        let screen = DisplayLayoutResolution.screen(of: id)
        guard let display = connectedDisplays().first(where: { $0.screenId == screen }) else { return nil }
        return DisplaySplitLayout.rect(of: String(id.dropFirst(screen.count)), in: display.frame,
                                       splits: displayLayout.splits(of: display.identity))
    }

    /// WE's "Remove Split": `region` and its sibling become the region they were split from.
    func removeSplit(_ region: String) {
        guard let location = location(of: region) else { return }
        displayLayout.removeSplit(containing: location)
        selectAfterSplitChange(of: region)
    }

    /// WE's "Remove All Splits": the display `id` is on is one region again.
    func removeAllSplits(_ id: String) {
        let screen = DisplayLayoutResolution.screen(of: id)
        guard let display = identity(of: screen) else { return }
        displayLayout.removeAllSplits(of: display)
        selectAfterSplitChange(of: id)
    }

    /// Selections of regions that are gone fall back to the nearest one that is left.
    private func selectAfterSplitChange(of id: String) {
        let shown = Set(layoutResolution.shownDisplays(Array(connectedDisplays().map(\.screenId))))
        func nearest(_ id: String) -> String {
            var candidate = id
            while !shown.contains(candidate), candidate.contains("/") { candidate = String(candidate.dropLast(2)) }
            return candidate
        }
        selectedScreenIds = Set(selectedScreenIds.map(nearest))
        selectedScreenId = nearest(selectedScreenId)
    }
}
