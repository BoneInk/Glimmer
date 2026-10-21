import Foundation
import XCTest
@testable import OWETheming

/// The global preferences in memory.
final class FakeGlobalPreferences: GlobalPreferencesStore {
    var values: [String: CFPropertyList] = [:]
    private(set) var log: [String] = []

    func copyValue(forKey key: String) -> CFPropertyList? { values[key] }

    func setValue(_ value: CFPropertyList?, forKey key: String) {
        log.append("set \(key)")
        values[key] = value
    }

    func synchronize() { log.append("synchronize") }
}

final class FakeNotifications: DistributedNotificationPosting {
    private(set) var names: [String] = []
    func post(_ name: String) { names.append(name) }
}

final class FakeDock: DockRestarting {
    private(set) var restarts = 0
    func restartDock() throws { restarts += 1 }
}

/// A timer the test fires.
final class ManualTimer: SettleTimer {
    private var action: (() -> Void)?
    private(set) var schedules = 0
    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) {
        schedules += 1
        self.action = action
    }
    func cancel() { action = nil }
    func fire() {
        let pending = action
        action = nil
        pending?()
    }
}

final class LiveApplyTests: XCTestCase {
    func testTheWriterStoresInTheGlobalDomainAndSynchronizes() {
        let store = FakeGlobalPreferences()
        let writer = GlobalPreferencesWriter(store: store, notifications: FakeNotifications())
        writer.setValue(.string("1 0 0 Other"), for: .highlightColor)
        writer.setValue(.integer(3), for: .accentColor)
        XCTAssertEqual(store.log, ["set AppleHighlightColor", "synchronize", "set AppleAccentColor", "synchronize"])
        XCTAssertEqual(writer.value(for: .highlightColor), .string("1 0 0 Other"))
        XCTAssertEqual(writer.value(for: .accentColor), .integer(3))
        writer.setValue(nil, for: .accentColor)
        XCTAssertNil(writer.value(for: .accentColor))
    }

    func testAColourChangePostsWhatSystemSettingsPosts() {
        let notifications = FakeNotifications()
        let writer = GlobalPreferencesWriter(store: FakeGlobalPreferences(), notifications: notifications)
        writer.post(.colorPreferences)
        XCTAssertEqual(notifications.names, ["AppleAquaColorVariantChanged", "AppleColorPreferencesChangedNotification",
                                             "AppleInterfaceThemeChangedNotification"])
        writer.post(.iconAppearance)
        XCTAssertEqual(notifications.names.count, 3, "the icon appearance has no public notification")
    }

    func testTheApplierPostsTheColourNotificationsAfterWriting() {
        let store = FakeGlobalPreferences()
        let notifications = FakeNotifications()
        let applier = SystemThemeApplier(writer: GlobalPreferencesWriter(store: store, notifications: notifications),
                                         store: MemoryJournalStore())
        applier.apply([.accentColor: .integer(2)])
        XCTAssertEqual(notifications.names.first, "AppleAquaColorVariantChanged")
        applier.apply([.accentColor: .integer(2)])
        XCTAssertEqual(notifications.names.count, 3, "nothing written, nothing posted")
    }

    private func makeScheduler(_ writer: FakeAppearanceWriter) -> (DockRestartScheduler, FakeDock, ManualTimer) {
        let dock = FakeDock()
        let timer = ManualTimer()
        return (DockRestartScheduler(restarter: dock, writer: writer, timer: timer), dock, timer)
    }

    func testRapidChangesRestartTheDockOnceAfterTheySettle() {
        let writer = FakeAppearanceWriter([.iconTintColor: .string("Red")])
        let (scheduler, dock, timer) = makeScheduler(writer)
        for step in 0..<10 {
            writer.values[.iconCustomTintColor] = .string("0.\(step) 0 0 1.000000")
            scheduler.iconPreferencesChanged()
        }
        XCTAssertEqual(dock.restarts, 0, "nothing restarts while the colour moves")
        timer.fire()
        XCTAssertEqual(dock.restarts, 1)
        timer.fire()
        XCTAssertEqual(dock.restarts, 1, "one restart per settle")
        XCTAssertFalse(scheduler.isOutOfDate)
    }

    func testUnchangedValuesDontRestartTheDock() {
        let writer = FakeAppearanceWriter([.iconTintColor: .string("Red")])
        let (scheduler, dock, timer) = makeScheduler(writer)
        scheduler.iconPreferencesChanged()
        timer.fire()
        XCTAssertEqual(dock.restarts, 0, "the Dock already shows these values")

        writer.values[.iconTintColor] = .string("Blue")
        writer.values[.iconTintColor] = .string("Red")
        scheduler.iconPreferencesChanged()
        timer.fire()
        XCTAssertEqual(dock.restarts, 0, "changed and changed back before settling")

        writer.values[.accentColor] = .integer(4)
        scheduler.iconPreferencesChanged()
        timer.fire()
        XCTAssertEqual(dock.restarts, 0, "the accent colour isn't the Dock's")
    }

    func testSettleRestartsAtOnceOnlyWhenOutOfDate() {
        let writer = FakeAppearanceWriter()
        let (scheduler, dock, _) = makeScheduler(writer)
        XCTAssertFalse(scheduler.settle())
        writer.values[.iconAppearanceTheme] = .string("TintedAutomatic")
        XCTAssertTrue(scheduler.isOutOfDate)
        XCTAssertTrue(scheduler.settle())
        XCTAssertEqual(dock.restarts, 1)
    }

    func testRestartingTheDockIsOnByDefault() throws {
        XCTAssertTrue(ThemingSettings().restartsDockAutomatically)
        let old = try JSONDecoder().decode(ThemingSettings.self, from: Data(#"{"isEnabled": true}"#.utf8))
        XCTAssertTrue(old.restartsDockAutomatically)
    }
}
