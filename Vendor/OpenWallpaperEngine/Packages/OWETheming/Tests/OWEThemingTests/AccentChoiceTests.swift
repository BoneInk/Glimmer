import XCTest
@testable import OWETheming

/// Accent Color's two system-wide choices, Nearest Apple accent and Multicolor, and the tint of the
/// app's own windows. Everything is written to `FakeAppearanceWriter`, never the Mac's settings.
final class AccentChoiceTests: XCTestCase {
    private let red = ThemeColor(red: 0.85, green: 0.15, blue: 0.2)
    private let blueHighlight = PreferenceValue.string("0.698039 0.843137 1.000000 Blue")

    private func settings(_ choice: SystemAccentChoice, app: AppAccentChoice = .themeColor) -> ThemingSettings {
        var settings = ThemingSettings()
        settings.isEnabled = true
        settings.accentColor = true
        settings.systemAccent = choice
        settings.appAccent = app
        return settings
    }

    private func apply(_ choice: SystemAccentChoice, _ applier: SystemThemeApplier, _ writer: FakeAppearanceWriter) {
        applier.apply(ThemePlan.preferences(for: red, settings: settings(choice),
                                            currentIconTheme: writer.value(for: .iconAppearanceTheme)))
    }

    func testDefaultsAreTodaysBehaviour() {
        let settings = ThemingSettings()
        XCTAssertEqual(settings.systemAccent, .nearestApple)
        XCTAssertEqual(settings.appAccent, .themeColor)
    }

    func testNearestAppleWritesThePaletteEntryAndTheHighlight() {
        let values = ThemePlan.preferences(for: red, settings: settings(.nearestApple), currentIconTheme: nil)
        XCTAssertEqual(values[.accentColor] ?? nil, .integer(AccentPalette.red.rawValue))
        XCTAssertEqual(values[.highlightColor] ?? nil, .string(HighlightColor.preferenceValue(for: red)))
    }

    func testMulticolorRemovesTheAccentAndKeepsTheExactHighlight() {
        let values = ThemePlan.preferences(for: red, settings: settings(.multicolor), currentIconTheme: nil)
        XCTAssertTrue(values.keys.contains(.accentColor), "the accent is named, to be removed")
        XCTAssertNil(values[.accentColor] ?? nil)
        XCTAssertEqual(values[.highlightColor] ?? nil, .string(HighlightColor.preferenceValue(for: red)))

        let writer = FakeAppearanceWriter([.accentColor: .integer(4), .highlightColor: blueHighlight])
        let applier = SystemThemeApplier(writer: writer, store: MemoryJournalStore())
        apply(.multicolor, applier, writer)
        XCTAssertNil(writer.values[.accentColor], "AppleAccentColor is removed")
        XCTAssertTrue(writer.writes.contains { $0.0 == .accentColor && $0.1 == nil })
        XCTAssertEqual(writer.values[.highlightColor], .string(HighlightColor.preferenceValue(for: red)))
        XCTAssertEqual(writer.posted, [.colorPreferences])
    }

    func testRestoreAfterNearestApple() {
        let writer = FakeAppearanceWriter([.accentColor: .integer(3), .highlightColor: blueHighlight])
        let applier = SystemThemeApplier(writer: writer, store: MemoryJournalStore())
        apply(.nearestApple, applier, writer)
        applier.restoreAll()
        XCTAssertEqual(writer.values, [.accentColor: .integer(3), .highlightColor: blueHighlight])
    }

    func testRestoreAfterMulticolorPutsTheAccentBack() {
        let writer = FakeAppearanceWriter([.accentColor: .integer(3), .highlightColor: blueHighlight])
        let store = MemoryJournalStore()
        let applier = SystemThemeApplier(writer: writer, store: store)
        apply(.multicolor, applier, writer)
        XCTAssertEqual(store.saved.entries[.accentColor], .init(original: .integer(3), written: nil))
        applier.restoreAll()
        XCTAssertEqual(writer.values, [.accentColor: .integer(3), .highlightColor: blueHighlight])
        XCTAssertTrue(store.saved.entries.isEmpty)
    }

    func testRestoreAfterMulticolorWhenTheUserWasMulticolor() {
        let writer = FakeAppearanceWriter([.highlightColor: blueHighlight]) // Multicolor: no accent stored.
        let applier = SystemThemeApplier(writer: writer, store: MemoryJournalStore())
        apply(.multicolor, applier, writer)
        XCTAssertFalse(writer.writes.contains { $0.0 == .accentColor }, "already absent: nothing written")
        applier.restoreAll()
        XCTAssertEqual(writer.values, [.highlightColor: blueHighlight])
    }

    func testRestoreAfterNearestAppleWhenTheUserWasMulticolorRemovesTheKey() {
        let writer = FakeAppearanceWriter()
        let applier = SystemThemeApplier(writer: writer, store: MemoryJournalStore())
        apply(.nearestApple, applier, writer)
        XCTAssertNotNil(writer.values[.accentColor])
        applier.restoreAll()
        XCTAssertTrue(writer.values.isEmpty)
    }

    /// Switching back and forth keeps the user's own accent as the one to restore.
    func testSwitchingChoicesKeepsTheOriginal() {
        let writer = FakeAppearanceWriter([.accentColor: .integer(5), .highlightColor: blueHighlight])
        let store = MemoryJournalStore()
        let applier = SystemThemeApplier(writer: writer, store: store)
        apply(.nearestApple, applier, writer)
        apply(.multicolor, applier, writer)
        XCTAssertNil(writer.values[.accentColor])
        apply(.nearestApple, applier, writer)
        XCTAssertEqual(writer.values[.accentColor], .integer(AccentPalette.red.rawValue))
        apply(.multicolor, applier, writer)
        XCTAssertEqual(store.saved.entries[.accentColor]?.original, .integer(5))
        XCTAssertEqual(store.saved.entries[.highlightColor]?.original, blueHighlight)
        applier.restoreAll()
        XCTAssertEqual(writer.values, [.accentColor: .integer(5), .highlightColor: blueHighlight])
    }

    /// The user picks an accent in System Settings while Multicolor is on: theirs stays.
    func testUserAccentAfterMulticolorIsKept() {
        let writer = FakeAppearanceWriter([.accentColor: .integer(5)])
        let applier = SystemThemeApplier(writer: writer, store: MemoryJournalStore())
        apply(.multicolor, applier, writer)
        writer.values[.accentColor] = .integer(2)
        applier.restoreAll()
        XCTAssertEqual(writer.values[.accentColor], .integer(2))
    }

    func testAfterACrashMulticolorIsRestoredAtTheNextLaunch() {
        let writer = FakeAppearanceWriter([.accentColor: .integer(1)])
        let store = MemoryJournalStore()
        apply(.multicolor, SystemThemeApplier(writer: writer, store: store), writer)
        let relaunched = SystemThemeApplier(writer: writer, store: store)
        XCTAssertTrue(relaunched.recoverAfterUncleanExit())
        XCTAssertEqual(writer.values[.accentColor], .integer(1))
    }

    func testJournalKeepsARemovedAccentThroughUserDefaults() throws {
        let suite = "OWEThemingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsJournalStore(defaults: defaults, logError: { XCTFail($0) })
        let journal = ThemingJournal(entries: [.accentColor: .init(original: .integer(3), written: nil)],
                                     isSessionActive: true)
        store.save(journal)
        XCTAssertEqual(store.load(), journal)
    }

    func testAppTintFollowsTheSetting() {
        XCTAssertEqual(settings(.nearestApple).appTint(for: red), red)
        XCTAssertEqual(settings(.multicolor).appTint(for: red), red, "Multicolor still tints the app")
        XCTAssertNil(settings(.nearestApple, app: .system).appTint(for: red))
        XCTAssertNil(settings(.nearestApple).appTint(for: nil))
        var off = settings(.nearestApple)
        off.isEnabled = false
        XCTAssertNil(off.appTint(for: red), "theming off: the system accent")
        var noAccent = settings(.nearestApple)
        noAccent.accentColor = false
        XCTAssertNil(noAccent.appTint(for: red))
    }

    func testChoicesRoundTripAndOldSettingsKeepDefaults() throws {
        let stored = try JSONEncoder().encode(settings(.multicolor, app: .system))
        let decoded = try JSONDecoder().decode(ThemingSettings.self, from: stored)
        XCTAssertEqual(decoded.systemAccent, .multicolor)
        XCTAssertEqual(decoded.appAccent, .system)

        let old = try JSONDecoder().decode(ThemingSettings.self, from: Data(#"{"isEnabled": true}"#.utf8))
        XCTAssertEqual(old.systemAccent, .nearestApple)
        XCTAssertEqual(old.appAccent, .themeColor)
        let unknown = try JSONDecoder().decode(ThemingSettings.self,
                                               from: Data(#"{"systemAccent": "rainbow", "accentColor": true}"#.utf8))
        XCTAssertEqual(unknown.systemAccent, .nearestApple)
        XCTAssertTrue(unknown.accentColor)
    }
}
