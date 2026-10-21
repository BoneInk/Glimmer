import XCTest
@testable import OWETheming

final class SystemThemeApplierTests: XCTestCase {
    private let red = ThemeColor(red: 0.85, green: 0.15, blue: 0.2)
    private let green = ThemeColor(red: 0.3, green: 0.7, blue: 0.3)

    private func settings(accent: Bool = false, tinted: Bool = false, folder: Bool = false) -> ThemingSettings {
        var settings = ThemingSettings()
        settings.isEnabled = true
        settings.accentColor = accent
        settings.tintedIcons = tinted
        settings.folderColor = folder
        return settings
    }

    private func plan(_ color: ThemeColor?, _ settings: ThemingSettings, _ writer: FakeAppearanceWriter)
        -> [SystemPreferenceKey: PreferenceValue?] {
        ThemePlan.preferences(for: color, settings: settings, currentIconTheme: writer.value(for: .iconAppearanceTheme))
    }

    func testSavesAppliesAndRestores() {
        let writer = FakeAppearanceWriter([.accentColor: .integer(4),
                                           .highlightColor: .string("0.698039 0.843137 1.000000 Blue")])
        let store = MemoryJournalStore()
        let applier = SystemThemeApplier(writer: writer, store: store)

        applier.apply(plan(red, settings(accent: true), writer))
        XCTAssertEqual(writer.values[.accentColor], .integer(AccentPalette.red.rawValue))
        XCTAssertEqual(store.saved.entries[.accentColor]?.original, .integer(4))
        XCTAssertTrue(store.saved.isSessionActive)
        XCTAssertEqual(writer.posted, [.colorPreferences])

        applier.apply(plan(red, settings(), writer))
        XCTAssertEqual(writer.values[.accentColor], .integer(4))
        XCTAssertEqual(writer.values[.highlightColor], .string("0.698039 0.843137 1.000000 Blue"))
        XCTAssertTrue(store.saved.entries.isEmpty)
        XCTAssertFalse(store.saved.isSessionActive)
    }

    func testAbsentOriginalIsRemovedOnRestore() {
        let writer = FakeAppearanceWriter() // Multicolor, default icons: nothing stored.
        let applier = SystemThemeApplier(writer: writer, store: MemoryJournalStore())
        applier.apply(plan(red, settings(accent: true, folder: true), writer))
        XCTAssertNotNil(writer.values[.accentColor])
        XCTAssertEqual(writer.values[.iconTintColor], .string("Other"))
        XCTAssertNil(writer.values[.iconAppearanceTheme], "folders alone don't change the icon style")
        applier.restoreAll()
        XCTAssertTrue(writer.values.isEmpty)
    }

    func testUnchangedValuesAreNotWritten() {
        let writer = FakeAppearanceWriter()
        let applier = SystemThemeApplier(writer: writer, store: MemoryJournalStore())
        let desired = plan(red, settings(accent: true, tinted: true), writer)
        applier.apply(desired)
        writer.clearLog()

        XCTAssertTrue(applier.apply(desired).isEmpty)
        XCTAssertTrue(writer.writes.isEmpty)
        XCTAssertTrue(writer.posted.isEmpty)

        // A colour that maps to the same palette entry writes only what differs.
        applier.apply(plan(ThemeColor(red: 0.86, green: 0.16, blue: 0.2), settings(accent: true, tinted: true), writer))
        XCTAssertFalse(writer.writtenKeys.contains(.accentColor))
        XCTAssertFalse(writer.writtenKeys.contains(.iconAppearanceTheme))
        XCTAssertTrue(writer.writtenKeys.contains(.iconCustomTintColor))
    }

    func testAlreadyStoredValueIsNotWrittenEvenTheFirstTime() {
        let writer = FakeAppearanceWriter([.accentColor: .integer(AccentPalette.red.rawValue)])
        let applier = SystemThemeApplier(writer: writer, store: MemoryJournalStore())
        var only = plan(red, settings(accent: true), writer)
        only[.highlightColor] = nil
        applier.apply(only)
        XCTAssertTrue(writer.writes.isEmpty)
        applier.restoreAll()
        XCTAssertTrue(writer.writes.isEmpty)
        XCTAssertEqual(writer.values[.accentColor], .integer(AccentPalette.red.rawValue))
    }

    func testTurningOneCheckboxOffRestoresOnlyItsKeys() {
        let writer = FakeAppearanceWriter([.iconAppearanceTheme: .string("RegularDark")])
        let applier = SystemThemeApplier(writer: writer, store: MemoryJournalStore())
        applier.apply(plan(red, settings(accent: true, tinted: true), writer))
        XCTAssertEqual(writer.values[.iconAppearanceTheme], .string("TintedDark"))
        applier.apply(plan(red, settings(accent: true), writer))
        XCTAssertEqual(writer.values[.iconAppearanceTheme], .string("RegularDark"))
        XCTAssertNil(writer.values[.iconTintColor])
        XCTAssertEqual(writer.values[.accentColor], .integer(AccentPalette.red.rawValue))
    }

    func testUserChangeSinceIsKept() {
        let writer = FakeAppearanceWriter([.accentColor: .integer(4)])
        let applier = SystemThemeApplier(writer: writer, store: MemoryJournalStore())
        applier.apply(plan(red, settings(accent: true), writer))
        writer.values[.accentColor] = .integer(AccentPalette.green.rawValue) // The user picks green.
        applier.restoreAll()
        XCTAssertEqual(writer.values[.accentColor], .integer(AccentPalette.green.rawValue))
    }

    func testOriginalIsTheUsersAcrossColorChanges() {
        let writer = FakeAppearanceWriter([.accentColor: .integer(4)])
        let store = MemoryJournalStore()
        let applier = SystemThemeApplier(writer: writer, store: store)
        applier.apply(plan(red, settings(accent: true), writer))
        applier.apply(plan(green, settings(accent: true), writer))
        XCTAssertEqual(writer.values[.accentColor], .integer(AccentPalette.green.rawValue))
        XCTAssertEqual(store.saved.entries[.accentColor]?.original, .integer(4))
        applier.restoreAll()
        XCTAssertEqual(writer.values[.accentColor], .integer(4))
    }

    func testCrashRecoveryOnNextLaunch() {
        let writer = FakeAppearanceWriter([.accentColor: .integer(4)])
        let store = MemoryJournalStore()
        SystemThemeApplier(writer: writer, store: store).apply(plan(red, settings(accent: true), writer))
        // The process dies here: no endSession.

        let relaunched = SystemThemeApplier(writer: writer, store: store)
        XCTAssertTrue(relaunched.recoverAfterUncleanExit())
        XCTAssertEqual(writer.values[.accentColor], .integer(4))
        XCTAssertTrue(store.saved.entries.isEmpty)
        XCTAssertFalse(SystemThemeApplier(writer: writer, store: store).recoverAfterUncleanExit())
    }

    func testCrashBetweenSavingOriginalAndWritingStillRestores() {
        let writer = FakeAppearanceWriter([.accentColor: .integer(4)])
        let store = MemoryJournalStore()
        // Saved before the write: what a crash right after the save leaves on disk.
        store.saved = ThemingJournal(entries: [.accentColor: .init(original: .integer(4), written: .integer(4))],
                                     isSessionActive: true)
        XCTAssertTrue(SystemThemeApplier(writer: writer, store: store).recoverAfterUncleanExit())
        XCTAssertTrue(writer.writes.isEmpty, "the value never changed, so nothing is written")
    }

    func testCleanQuitWithoutRestoreKeepsValuesAndOriginals() {
        let writer = FakeAppearanceWriter([.accentColor: .integer(4)])
        let store = MemoryJournalStore()
        SystemThemeApplier(writer: writer, store: store).apply(plan(red, settings(accent: true), writer))
        SystemThemeApplier(writer: writer, store: store).endSession(restoring: false)
        XCTAssertEqual(writer.values[.accentColor], .integer(AccentPalette.red.rawValue))

        let relaunched = SystemThemeApplier(writer: writer, store: store)
        XCTAssertFalse(relaunched.recoverAfterUncleanExit())
        relaunched.apply([:]) // Theming turned off later.
        XCTAssertEqual(writer.values[.accentColor], .integer(4))
    }

    func testQuitWithRestore() {
        let writer = FakeAppearanceWriter([.accentColor: .integer(4)])
        let store = MemoryJournalStore()
        let applier = SystemThemeApplier(writer: writer, store: store)
        applier.apply(plan(red, settings(accent: true, folder: true), writer))
        applier.endSession(restoring: true)
        XCTAssertEqual(writer.values, [.accentColor: .integer(4)])
        XCTAssertEqual(store.saved, ThemingJournal())
    }

    func testMasterOffOrNoColorRestoresEverything() {
        var off = settings(accent: true, tinted: true, folder: true)
        off.isEnabled = false
        XCTAssertTrue(ThemePlan.preferences(for: red, settings: off, currentIconTheme: nil).isEmpty)
        XCTAssertTrue(ThemePlan.preferences(for: nil, settings: settings(accent: true), currentIconTheme: nil).isEmpty)
    }

    func testTintedThemeKeepsVariant() {
        XCTAssertEqual(ThemePlan.tintedTheme(keepingVariantOf: nil), "TintedAutomatic")
        XCTAssertEqual(ThemePlan.tintedTheme(keepingVariantOf: .string("ClearLight")), "TintedLight")
        XCTAssertEqual(ThemePlan.tintedTheme(keepingVariantOf: .string("RegularAutomatic")), "TintedAutomatic")
        XCTAssertEqual(ThemePlan.tintedTheme(keepingVariantOf: .string("TintedDark")), "TintedDark")
    }

    func testCustomTintColorFormat() {
        let values = ThemePlan.preferences(for: ThemeColor(red: 0.5, green: 0.25, blue: 1),
                                           settings: settings(tinted: true), currentIconTheme: nil)
        XCTAssertEqual(values[.iconCustomTintColor] ?? nil, .string("0.500000 0.250000 1.000000 1.000000"))
        XCTAssertEqual(values[.iconTintColor] ?? nil, .string("Other"))
    }

    func testJournalRoundTripsThroughUserDefaults() throws {
        let suite = "OWEThemingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsJournalStore(defaults: defaults, logError: { XCTFail($0) })
        let journal = ThemingJournal(entries: [.accentColor: .init(original: nil, written: .integer(3)),
                                               .highlightColor: .init(original: .string("a"), written: .string("b"))],
                                     isSessionActive: true)
        store.save(journal)
        XCTAssertEqual(store.load(), journal)
        store.save(ThemingJournal())
        XCTAssertNil(defaults.object(forKey: "ThemingJournal"))
    }
}
