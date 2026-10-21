import Security
import XCTest
@testable import OpenWallpaperEngine

/// `AppIdentityMigration`: the move from the old bundle id to the new one, with stand-ins for the
/// defaults and the keychain and scratch folders for the support, caches and Library folders.
final class AppIdentityMigrationTests: XCTestCase {
    private static let old = "test.old-identity"
    private static let new = "test.new-identity"

    private var root: URL!
    private var preferences: FakePreferenceDomains!
    private var keychain: FakeKeychain!
    private var screenSaverReinstalls = 0
    private var loginItemRegistrations = 0

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "identity-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        preferences = FakePreferenceDomains()
        keychain = FakeKeychain()
        screenSaverReinstalls = 0
        loginItemRegistrations = 0
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private var support: URL { root.appending(path: "Support", directoryHint: .isDirectory) }
    private var caches: URL { root.appending(path: "Caches", directoryHint: .isDirectory) }
    private var library: URL { root.appending(path: "Library", directoryHint: .isDirectory) }

    private func migration(tag: String? = nil, caches: URL? = nil) -> AppIdentityMigration {
        var migration = AppIdentityMigration(
            isolationTag: tag, legacyIdentifier: Self.old, currentIdentifier: Self.new,
            supportDirectory: support, cachesDirectory: caches ?? self.caches, libraryDirectory: library,
            preferences: preferences, keychain: { [keychain] in keychain!.store($0) },
            keychainItems: [(suffix: "secret", account: "Account")])
        migration.reinstallScreenSaver = { [weak self] in self?.screenSaverReinstalls += 1 }
        migration.reregisterLoginItem = { [weak self] in self?.loginItemRegistrations += 1 }
        return migration
    }

    private func write(_ text: String, to url: URL, modified: Date? = nil) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path(percentEncoded: false))
        }
    }

    private func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

    // MARK: Defaults

    func testMovesDefaultsKeepingNewerValuesAndRemovesTheOldDomain() {
        preferences.domains[Self.old] = ["GlobalSettings": Data([1, 2]), "Volume": 0.5, "SUSkippedVersion": "9"]
        preferences.domains[Self.new] = ["Volume": 0.8]

        let journal = migration().run()

        XCTAssertEqual(preferences.domains[Self.new]?["GlobalSettings"] as? Data, Data([1, 2]))
        XCTAssertEqual(preferences.domains[Self.new]?["SUSkippedVersion"] as? String, "9", "Sparkle's state moves with the defaults")
        XCTAssertEqual(preferences.domains[Self.new]?["Volume"] as? Double, 0.8, "a value the new domain has stays")
        XCTAssertTrue(preferences.domains[Self.old, default: [:]].isEmpty, "the old domain is removed")
        XCTAssertTrue(journal.finished)
        XCTAssertTrue(journal.foundLegacyState)
        XCTAssertTrue(AppIdentityNotice.isPending(journal))
    }

    func testMovesTheEditorDomainToo() {
        preferences.domains[Self.old + ".editor"] = ["NSWindow Frame Editor": "0 0 800 600"]

        migration().run()

        XCTAssertEqual(preferences.domains[Self.new + ".editor"]?["NSWindow Frame Editor"] as? String, "0 0 800 600")
        XCTAssertTrue(preferences.domains[Self.old + ".editor", default: [:]].isEmpty)
    }

    func testKeepsTheOldDomainWhenTheNewOneDoesNotHoldTheValues() {
        preferences.domains[Self.old] = ["GlobalSettings": Data([1])]
        preferences.dropsWritesTo = [Self.new]

        let journal = migration().run()

        XCTAssertEqual(preferences.domains[Self.old]?["GlobalSettings"] as? Data, Data([1]), "never removed before the copy is verified")
        XCTAssertFalse(journal.finished)
        XCTAssertFalse(journal.completed.contains(AppIdentityMigration.Step.defaults.rawValue))

        // The next launch tries again.
        preferences.dropsWritesTo = []
        let retried = migration().run()
        XCTAssertTrue(retried.finished)
        XCTAssertEqual(preferences.domains[Self.new]?["GlobalSettings"] as? Data, Data([1]))
        XCTAssertTrue(preferences.domains[Self.old, default: [:]].isEmpty)
    }

    // MARK: Folders

    func testRenamesTheCachesFolder() throws {
        let file = caches.appending(path: "\(Self.old)/shader-variants/r1/a.msl")
        try write("variant", to: file)

        migration().run()

        XCTAssertEqual(try read(caches.appending(path: "\(Self.new)/shader-variants/r1/a.msl")), "variant")
        XCTAssertFalse(exists(caches.appending(path: Self.old)), "the old caches are gone, not copied")
    }

    func testMergesIntoAFolderAPartialRunLeftKeepingTheNewerFile() throws {
        let past = Date(timeIntervalSinceNow: -3600)
        let oldFolder = caches.appending(path: Self.old, directoryHint: .isDirectory)
        let newFolder = caches.appending(path: Self.new, directoryHint: .isDirectory)
        try write("old stale", to: oldFolder.appending(path: "pipeline-archives/a.bin"), modified: past)
        try write("old only", to: oldFolder.appending(path: "shader-variants/b.msl"))
        try write("old newer", to: oldFolder.appending(path: "shader-variants/c.msl"))
        try write("new current", to: newFolder.appending(path: "pipeline-archives/a.bin"))
        try write("new older", to: newFolder.appending(path: "shader-variants/c.msl"), modified: past)

        migration().run()

        XCTAssertEqual(try read(newFolder.appending(path: "pipeline-archives/a.bin")), "new current", "newer data is never overwritten")
        XCTAssertEqual(try read(newFolder.appending(path: "shader-variants/b.msl")), "old only")
        XCTAssertEqual(try read(newFolder.appending(path: "shader-variants/c.msl")), "old newer")
        XCTAssertFalse(exists(oldFolder))
    }

    func testMovesTheWebViewDataAndTheEditorCaches() throws {
        try write("local storage", to: library.appending(path: "WebKit/\(Self.old)/WebsiteData/LocalStorage/x.sqlite3"))
        try write("cookies", to: library.appending(path: "HTTPStorages/\(Self.old).binarycookies"))
        try write("editor cache", to: caches.appending(path: "\(Self.old).editor/Cache.db"))

        migration().run()

        XCTAssertEqual(try read(library.appending(path: "WebKit/\(Self.new)/WebsiteData/LocalStorage/x.sqlite3")), "local storage")
        XCTAssertEqual(try read(library.appending(path: "HTTPStorages/\(Self.new).binarycookies")), "cookies")
        XCTAssertEqual(try read(caches.appending(path: "\(Self.new).editor/Cache.db")), "editor cache")
        XCTAssertFalse(exists(library.appending(path: "WebKit/\(Self.old)")))
        XCTAssertFalse(exists(library.appending(path: "HTTPStorages/\(Self.old).binarycookies")))
    }

    // MARK: Keychain

    func testMovesKeychainItemsAndDeletesTheOldOnesAfterVerifying() {
        keychain.items["\(Self.old).secret"] = ["Account": "key"]

        migration().run()

        XCTAssertEqual(keychain.items["\(Self.new).secret"]?["Account"], "key")
        XCTAssertNil(keychain.items["\(Self.old).secret"]?["Account"])
        XCTAssertEqual(keychain.log, ["read \(Self.old).secret", "read \(Self.new).secret", "set \(Self.new).secret",
                                      "read \(Self.new).secret", "remove \(Self.old).secret"],
                       "the old item is deleted only after the new one is read back")
    }

    func testKeepsTheOldKeychainItemWhenTheNewOneCantBeVerified() {
        keychain.items["\(Self.old).secret"] = ["Account": "key"]
        keychain.dropsWritesTo = ["\(Self.new).secret"]

        let journal = migration().run()

        XCTAssertEqual(keychain.items["\(Self.old).secret"]?["Account"], "key")
        XCTAssertFalse(journal.finished, "tried again at the next launch")
        XCTAssertFalse(keychain.log.contains("remove \(Self.old).secret"))
    }

    func testADeclinedKeychainPromptLeavesTheOldItem() {
        keychain.items["\(Self.old).secret"] = ["Account": "key"]
        keychain.declines = ["\(Self.old).secret"]

        let journal = migration().run()

        XCTAssertEqual(keychain.items["\(Self.old).secret"]?["Account"], "key")
        XCTAssertNil(keychain.items["\(Self.new).secret"]?["Account"])
        XCTAssertTrue(journal.finished, "a declined prompt isn't asked again at every launch")
    }

    // MARK: Journal, idempotence, isolation

    func testASecondRunDoesNothing() throws {
        preferences.domains[Self.old] = ["A": 1]
        keychain.items["\(Self.old).secret"] = ["Account": "key"]
        try write("x", to: caches.appending(path: "\(Self.old)/f"))
        migration().run()
        let writes = preferences.writeCount
        keychain.log = []

        // Something the old version writes after the move (a downgrade) stays its own.
        preferences.domains[Self.old] = ["A": 2]
        let journal = migration().run()

        XCTAssertTrue(journal.finished)
        XCTAssertEqual(preferences.writeCount, writes)
        XCTAssertEqual(preferences.domains[Self.new]?["A"] as? Int, 1)
        XCTAssertEqual(keychain.log, [])
        XCTAssertEqual(screenSaverReinstalls, 1)
        XCTAssertEqual(loginItemRegistrations, 1)
    }

    func testResumesFromTheJournalAfterACrash() throws {
        // A crash after the defaults step: the journal has it, the caches are still to move.
        var journal = AppIdentityMigrationJournal()
        journal.completed = [AppIdentityMigration.Step.defaults.rawValue]
        journal.foundLegacyState = true
        try journal.save(to: AppIdentityMigrationJournal.url(in: support))
        preferences.domains[Self.old] = ["WrittenAfterTheMove": true]
        try write("variant", to: caches.appending(path: "\(Self.old)/shader-variants/a.msl"))

        let resumed = migration().run()

        XCTAssertTrue(resumed.finished)
        XCTAssertEqual(resumed.completed, AppIdentityMigration.Step.allCases.map(\.rawValue))
        XCTAssertEqual(preferences.domains[Self.old]?["WrittenAfterTheMove"] as? Bool, true, "a finished step isn't run again")
        XCTAssertEqual(try read(caches.appending(path: "\(Self.new)/shader-variants/a.msl")), "variant")
        XCTAssertEqual(loginItemRegistrations, 1, "the journal remembers the old state was found")
        XCTAssertEqual(AppIdentityMigrationJournal.load(from: AppIdentityMigrationJournal.url(in: support)), resumed)
    }

    func testAFreshInstallFinishesWithoutTheNotice() {
        let journal = migration().run()

        XCTAssertTrue(journal.finished)
        XCTAssertFalse(journal.foundLegacyState)
        XCTAssertFalse(AppIdentityNotice.isPending(journal))
        XCTAssertEqual(loginItemRegistrations, 0)
    }

    func testTheNoticeIsShownOnce() {
        var journal = AppIdentityMigrationJournal(completed: [], finished: true, foundLegacyState: true)
        XCTAssertTrue(AppIdentityNotice.isPending(journal))
        journal.noticeShown = true
        XCTAssertFalse(AppIdentityNotice.isPending(journal))
    }

    func testAnIsolatedCopyMovesOnlyItsOwnTag() throws {
        preferences.domains["\(Self.old).isolated.shots"] = ["A": 1]
        preferences.domains["\(Self.old).isolated.other"] = ["B": 2]
        preferences.domains[Self.old] = ["C": 3]
        preferences.domains[Self.old + ".editor"] = ["D": 4]
        keychain.items["\(Self.old).isolated.shots.secret"] = ["Account": "shots"]
        keychain.items["\(Self.old).secret"] = ["Account": "real"]
        let isolatedCaches = caches.appending(path: "Open Wallpaper Engine (isolated shots)", directoryHint: .isDirectory)
        try write("isolated", to: isolatedCaches.appending(path: "\(Self.old)/shader-variants/a.msl"))
        try write("real", to: caches.appending(path: "\(Self.old)/shader-variants/a.msl"))
        try write("web", to: library.appending(path: "WebKit/\(Self.old)/x"))

        migration(tag: "shots", caches: isolatedCaches).run()

        XCTAssertEqual(preferences.domains["\(Self.new).isolated.shots"]?["A"] as? Int, 1)
        XCTAssertEqual(preferences.domains["\(Self.old).isolated.other"]?["B"] as? Int, 2)
        XCTAssertEqual(preferences.domains[Self.old]?["C"] as? Int, 3)
        XCTAssertEqual(preferences.domains[Self.old + ".editor"]?["D"] as? Int, 4)
        XCTAssertNil(preferences.domains[Self.new])
        XCTAssertEqual(keychain.items["\(Self.new).isolated.shots.secret"]?["Account"], "shots")
        XCTAssertEqual(keychain.items["\(Self.old).secret"]?["Account"], "real")
        XCTAssertEqual(try read(isolatedCaches.appending(path: "\(Self.new)/shader-variants/a.msl")), "isolated")
        XCTAssertEqual(try read(caches.appending(path: "\(Self.old)/shader-variants/a.msl")), "real")
        XCTAssertTrue(exists(library.appending(path: "WebKit/\(Self.old)/x")))
        XCTAssertEqual(screenSaverReinstalls, 0)
        XCTAssertEqual(loginItemRegistrations, 0)
    }

    func testTheProductionMigrationTargetsThisCopy() {
        let production = AppIdentityMigration.forCurrentProcess()
        XCTAssertEqual(production.isolationTag, AppStorageLocation.testsTag)
        XCTAssertEqual(production.currentIdentifier, AppStorageLocation.realBundleIdentifier)
        XCTAssertNotEqual(production.legacyIdentifier, production.currentIdentifier)
        XCTAssertEqual(production.scoped(production.currentIdentifier), AppStorageLocation.current.keychainServicePrefix)
        XCTAssertEqual(production.journalURL, AppIdentityMigrationJournal.url(in: AppStorageLocation.current.supportDirectory))
        XCTAssertEqual(production.steps, AppIdentityMigration.Step.isolated)
    }

    // MARK: The system's defaults

    func testSystemPreferenceDomainsWriteReadAndRemove() {
        let domain = "test.identity-migration.\(UUID().uuidString)"
        let system = SystemPreferenceDomains()
        defer { system.remove(Array(system.values(in: domain).keys), from: domain) }
        XCTAssertTrue(system.values(in: domain).isEmpty)

        system.set(["A": 1, "B": "two"], in: domain)
        XCTAssertEqual(system.values(in: domain)["A"] as? Int, 1)
        XCTAssertEqual(system.values(in: domain)["B"] as? String, "two")

        system.remove(["A", "B"], from: domain)
        XCTAssertTrue(system.values(in: domain).isEmpty)
    }
}

/// Defaults domains in memory.
private final class FakePreferenceDomains: PreferenceDomains {
    var domains: [String: [String: Any]] = [:]
    /// Domains whose writes are lost, as if the disk refused them.
    var dropsWritesTo: Set<String> = []
    var writeCount = 0

    func values(in domain: String) -> [String: Any] { domains[domain] ?? [:] }

    func set(_ values: [String: Any], in domain: String) {
        guard !values.isEmpty else { return }
        writeCount += 1
        guard !dropsWritesTo.contains(domain) else { return }
        domains[domain, default: [:]].merge(values) { _, new in new }
    }

    func remove(_ keys: [String], from domain: String) {
        writeCount += 1
        for key in keys { domains[domain]?.removeValue(forKey: key) }
    }
}

/// Keychain services in memory, recording each call.
private final class FakeKeychain {
    var items: [String: [String: String]] = [:]
    var dropsWritesTo: Set<String> = []
    /// Services whose read is declined at the prompt.
    var declines: Set<String> = []
    var log: [String] = []

    func store(_ service: String) -> KeychainStoring { Store(service: service, keychain: self) }

    private struct Store: KeychainStoring {
        let service: String
        let keychain: FakeKeychain

        func string(forAccount account: String) throws -> String? {
            keychain.log.append("read \(service)")
            if keychain.declines.contains(service) {
                throw KeychainStore.Failure(operation: "read", status: errSecUserCanceled)
            }
            return keychain.items[service]?[account]
        }

        func set(_ value: String, forAccount account: String) throws {
            keychain.log.append("set \(service)")
            guard !keychain.dropsWritesTo.contains(service) else { return }
            keychain.items[service, default: [:]][account] = value
        }

        func removeValue(forAccount account: String) throws {
            keychain.log.append("remove \(service)")
            keychain.items[service]?.removeValue(forKey: account)
        }
    }
}
