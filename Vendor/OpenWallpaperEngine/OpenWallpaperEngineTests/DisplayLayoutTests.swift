import XCTest
@testable import OpenWallpaperEngine

/// The display layout's model (WE's `wallpaperconfig.layout` and profile groups): saving and
/// reading it, group ids, the flip limitation, and how it resolves on the connected displays.
final class DisplayLayoutTests: XCTestCase {
    private let a = DisplayIdentity(screenId: "1", identity: "UUID-A")
    private let b = DisplayIdentity(screenId: "2", identity: "UUID-B")
    private let c = DisplayIdentity(screenId: "3", identity: "UUID-C")

    private func defaults() -> UserDefaults {
        let name = "owe-display-layout-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    // MARK: Persistence and migration

    func testWithoutASavedLayoutEveryDisplayShowsItsOwnWallpaper() {
        let layout = DisplayLayoutConfiguration.load(from: defaults())
        XCTAssertEqual(layout, DisplayLayoutConfiguration())
        XCTAssertEqual(layout.layout, .perDisplay)
        XCTAssertTrue(layout.groups.isEmpty)
        XCTAssertEqual(DisplayLayoutResolution(layout, displays: [a, b]), .empty, "nothing clones, flips or mutes")
    }

    func testTheLayoutRoundTrips() {
        let store = defaults()
        var layout = DisplayLayoutConfiguration()
        layout.addGroup(["UUID-A", "UUID-B"], layout: .clone)
        layout.setCloneSource("UUID-B", isSource: true, connected: ["UUID-A", "UUID-B"])
        layout.toggleFlip("UUID-A", connected: ["UUID-A", "UUID-B"])
        layout.toggleMute("UUID-C")
        layout.save(to: store)
        XCTAssertEqual(DisplayLayoutConfiguration.load(from: store), layout)
    }

    func testLayoutValuesAreWEs() {
        XCTAssertEqual(DisplayLayoutMode.perDisplay.rawValue, 0)
        XCTAssertEqual(DisplayLayoutMode.stretch.rawValue, 1)
        XCTAssertEqual(DisplayLayoutMode.clone.rawValue, 2)
    }

    func testAnUnreadableGroupDoesntDropTheOthers() throws {
        let json = #"{"layout":0,"groups":[{"members":"broken"},{"members":["UUID-A","UUID-B"],"layout":2}],"muted":["UUID-A"]}"#
        let layout = try JSONDecoder().decode(DisplayLayoutConfiguration.self, from: Data(json.utf8))
        XCTAssertEqual(layout.groups.map(\.members), [["UUID-A", "UUID-B"]])
        XCTAssertTrue(layout.isMuted("UUID-A"))
    }

    func testAnUnreadableLayoutFallsBackToAWallpaperPerDisplay() {
        let store = defaults()
        store.set(Data("not json".utf8), forKey: DisplayLayoutConfiguration.defaultsKey)
        XCTAssertEqual(DisplayLayoutConfiguration.load(from: store), DisplayLayoutConfiguration())
    }

    // MARK: Group ids

    func testAGroupsIdIsStableAndIgnoresMemberOrder() {
        XCTAssertEqual(DisplayGroup.id(for: ["UUID-A", "UUID-B"]), DisplayGroup.id(for: ["UUID-B", "UUID-A"]))
        // FNV-1a of the sorted identities: the same on every launch, unlike `Hasher`.
        XCTAssertEqual(DisplayGroup.id(for: ["UUID-B", "UUID-A"]), "group_1eee3829ef30595e")
        XCTAssertNotEqual(DisplayGroup.id(for: ["UUID-A", "UUID-B"]), DisplayGroup.id(for: ["UUID-A", "UUID-C"]))
    }

    // MARK: Groups

    func testADisplayJoiningAGroupLeavesItsOldOne() {
        var layout = DisplayLayoutConfiguration()
        layout.addGroup(["UUID-A", "UUID-B"], layout: .clone)
        layout.addGroup(["UUID-B", "UUID-C"], layout: .clone)
        XCTAssertEqual(layout.groups.map(\.members), [["UUID-B", "UUID-C"]], "the first group was left with one display")
    }

    func testAGroupNeedsTwoDisplays() {
        var layout = DisplayLayoutConfiguration()
        layout.addGroup(["UUID-A", "UUID-A"], layout: .clone)
        XCTAssertTrue(layout.groups.isEmpty)
        layout.addGroup(["UUID-A", "UUID-B", "UUID-C"], layout: .clone)
        layout.removeFromGroup("UUID-C")
        XCTAssertEqual(layout.groups.first?.members, ["UUID-A", "UUID-B"])
        layout.removeFromGroup("UUID-A")
        XCTAssertTrue(layout.groups.isEmpty, "a group of one is dissolved")
    }

    func testAGroupWithADisconnectedDisplayIsDormant() {
        var layout = DisplayLayoutConfiguration()
        layout.addGroup(["UUID-A", "UUID-B"], layout: .clone)
        XCTAssertTrue(DisplayLayoutResolution(layout, displays: [a, c]).clones.isEmpty, "display B is gone")
        XCTAssertEqual(layout.groups.count, 1, "the group is kept")
        XCTAssertEqual(DisplayLayoutResolution(layout, displays: [a, b, c]).sources, ["2": "1"], "B is back")
    }

    // MARK: Clone source and flip

    func testTheMainCloneDisplayIsTheFirstUnlessChosen() {
        var layout = DisplayLayoutConfiguration()
        layout.addGroup(["UUID-B", "UUID-A"], layout: .clone)
        XCTAssertEqual(DisplayLayoutResolution(layout, displays: [a, b]).sources, ["1": "2"])
        layout.setCloneSource("UUID-A", isSource: true, connected: ["UUID-A", "UUID-B"])
        XCTAssertEqual(DisplayLayoutResolution(layout, displays: [a, b]).sources, ["2": "1"])
        XCTAssertEqual(DisplayLayoutResolution(layout, displays: [b, c]).clones, [], "with A gone the group is dormant")
        layout.setCloneSource("UUID-A", isSource: false, connected: ["UUID-A", "UUID-B"])
        XCTAssertEqual(DisplayLayoutResolution(layout, displays: [a, b]).sources, ["1": "2"], "back to the first")
    }

    func testTheMainCloneDisplayCantBeFlipped() {
        var group = DisplayGroup(members: ["UUID-A", "UUID-B"], layout: .clone)
        XCTAssertFalse(group.toggleFlip("UUID-A"), "the main clone display")
        XCTAssertTrue(group.toggleFlip("UUID-B"))
        XCTAssertEqual(group.flipped, ["UUID-B"])
        group.setSource("UUID-B")
        XCTAssertEqual(group.flipped, [], "the new main display stops being flipped")
        XCTAssertTrue(group.toggleFlip("UUID-A"))
        group.remove("UUID-B")
        XCTAssertEqual(group.flipped, [], "A became the main display again")
    }

    func testAtLeastOneCloneMemberIsNeverFlipped() {
        var layout = DisplayLayoutConfiguration(layout: .clone)
        let connected = ["UUID-A", "UUID-B", "UUID-C"]
        for display in connected { layout.toggleFlip(display, connected: connected) }
        let resolution = DisplayLayoutResolution(layout, displays: [a, b, c])
        XCTAssertEqual(resolution.flipped, ["2", "3"])
        XCTAssertFalse(resolution.flipped.contains(resolution.clones[0].source))
    }

    func testTheCloneLayoutClonesEveryDisplayFromTheMainOne() {
        let layout = DisplayLayoutConfiguration(layout: .clone)
        let resolution = DisplayLayoutResolution(layout, displays: [b, a, c])
        XCTAssertEqual(resolution.sources, ["1": "2", "3": "2"], "the main display (listed first) is the source")
        XCTAssertEqual(resolution.clones.map(\.id), [DisplayLayoutResolution.globalCloneID])
        XCTAssertEqual(resolution.expandingClones(["3"]), ["1", "2", "3"])
    }

    func testGroupsApplyUnderAWallpaperPerDisplayOnly() {
        var layout = DisplayLayoutConfiguration()
        layout.addGroup(["UUID-A", "UUID-B"], layout: .clone)
        layout.layout = .stretch
        let resolution = DisplayLayoutResolution(layout, displays: [a, b])
        XCTAssertTrue(resolution.clones.isEmpty)
        XCTAssertEqual(resolution.stretches.map(\.id), [DisplayLayoutResolution.globalStretchID],
                       "the stretch layout spans every display instead")
    }

    func testMuteFollowsTheDisplay() {
        var layout = DisplayLayoutConfiguration()
        layout.toggleMute("UUID-B")
        XCTAssertEqual(DisplayLayoutResolution(layout, displays: [a, b]).muted, ["2"])
        XCTAssertEqual(DisplayLayoutResolution(layout, displays: [a, DisplayIdentity(screenId: "7", identity: "UUID-B")]).muted,
                       ["7"], "the display came back with another id")
        layout.toggleMute("UUID-B")
        XCTAssertTrue(DisplayLayoutResolution(layout, displays: [a, b]).muted.isEmpty)
    }
}
