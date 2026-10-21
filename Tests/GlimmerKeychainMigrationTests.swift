import Foundation
import Security

private struct KeychainTestFailure: Error, CustomStringConvertible {
    let description: String
}

private final class FakeSessionDefaults: SteamContentSessionDefaultsStoring, @unchecked Sendable {
    var values: [String: Any] = [:]
    var synchronizeResult = true

    func bool(forKey: String) -> Bool {
        values[forKey] as? Bool ?? false
    }

    func set(_ value: Any?, forKey: String) {
        if let value {
            values[forKey] = value
        } else {
            values.removeValue(forKey: forKey)
        }
    }

    func synchronize() -> Bool {
        synchronizeResult
    }
}

private final class MockKeychain: SteamContentKeychainAccessing, @unchecked Sendable {
    var items: [String: Data] = [:]
    var rejectLoadServices: Set<String> = []
    private(set) var loadServices: [String] = []
    private(set) var addServices: [String] = []
    private(set) var updateServices: [String] = []
    private(set) var deleteServices: [String] = []

    private func service(_ query: [String: Any]) -> String? {
        query[kSecAttrService as String] as? String
    }

    func load(_ query: [String: Any]) -> (OSStatus, Data?) {
        guard let service = service(query) else { return (errSecParam, nil) }
        loadServices.append(service)
        if rejectLoadServices.contains(service) { return (errSecAuthFailed, nil) }
        guard let data = items[service] else { return (errSecItemNotFound, nil) }
        return (errSecSuccess, data)
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        guard let service = service(attributes),
              let data = attributes[kSecValueData as String] as? Data else {
            return errSecParam
        }
        addServices.append(service)
        guard items[service] == nil else { return errSecDuplicateItem }
        items[service] = data
        return errSecSuccess
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        guard let service = service(query),
              let data = attributes[kSecValueData as String] as? Data else {
            return errSecParam
        }
        updateServices.append(service)
        guard items[service] != nil else { return errSecItemNotFound }
        items[service] = data
        return errSecSuccess
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        guard let service = service(query) else { return errSecParam }
        deleteServices.append(service)
        guard items.removeValue(forKey: service) != nil else { return errSecItemNotFound }
        return errSecSuccess
    }
}

@main
@MainActor
struct GlimmerKeychainMigrationTests {
    private static var checks = 0

    static func main() async throws {
        try await testLegacyCopyAndDeleteTombstone()
        try await testLegacyReadRejectionPreservesOldData()
        try await testDeleteRequiresDurableTombstone()
        print("GlimmerKeychainMigrationTests: \(checks) checks passed; mock Security boundary, no real Keychain")
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
        guard condition() else { throw KeychainTestFailure(description: label) }
        checks += 1
        print("PASS \(label)")
    }

    private static func testLegacyCopyAndDeleteTombstone() async throws {
        let defaults = FakeSessionDefaults()
        let keychain = MockKeychain()
        let legacy = SteamContentSavedSession(
            username: "legacy-fixture", refreshToken: "legacy-token", guardData: "legacy-guard")
        let legacyData = try JSONEncoder().encode(legacy)
        keychain.items[SteamContentKeychainSessionStore.legacyService] = legacyData

        let store = SteamContentKeychainSessionStore(api: keychain, defaults: defaults)
        let loaded = try await store.load()
        try check(loaded == legacy,
                  "legacy credential is read through the compatibility service")
        try check(keychain.items[SteamContentKeychainSessionStore.service] != nil,
                  "legacy credential is copied into the Glimmer service")
        try check(keychain.items[SteamContentKeychainSessionStore.legacyService] == legacyData,
                  "legacy credential remains in the old service")
        try check(!keychain.deleteServices.contains(SteamContentKeychainSessionStore.legacyService),
                  "legacy migration never deletes the old keychain item")
        try check(defaults.bool(forKey: SteamContentKeychainSessionStore.legacyMigrationAttemptedKey),
                  "legacy migration attempt is recorded in the injected defaults")

        let reopened = SteamContentKeychainSessionStore(api: keychain, defaults: defaults)
        let reopenedSession = try await reopened.load()
        try check(reopenedSession == legacy,
                  "a fresh store instance reads the copied Glimmer credential")

        try await reopened.delete()
        try check(keychain.items[SteamContentKeychainSessionStore.service] == nil,
                  "explicit delete removes the Glimmer credential")
        try check(keychain.items[SteamContentKeychainSessionStore.legacyService] == legacyData,
                  "explicit delete leaves the legacy credential untouched")
        try check(defaults.bool(forKey: SteamContentKeychainSessionStore.suppressionKey),
                  "explicit delete persists a restore-suppression tombstone")

        let afterDelete = SteamContentKeychainSessionStore(api: keychain, defaults: defaults)
        let legacyLoadsBefore = keychain.loadServices.filter {
            $0 == SteamContentKeychainSessionStore.legacyService
        }.count
        let suppressedSession = try await afterDelete.load()
        try check(suppressedSession == nil,
                  "suppression prevents the old credential from reviving after delete")
        let legacyLoadsAfter = keychain.loadServices.filter {
            $0 == SteamContentKeychainSessionStore.legacyService
        }.count
        try check(legacyLoadsAfter == legacyLoadsBefore,
                  "suppressed startup does not even read the old credential")

        let replacement = SteamContentSavedSession(
            username: "fixture-user", refreshToken: "fresh-token", guardData: nil)
        try await afterDelete.save(replacement)
        let restoredSession = try await afterDelete.load()
        try check(restoredSession == replacement,
                  "an explicit successful save clears only its own suppression bit")
        try check(keychain.items[SteamContentKeychainSessionStore.legacyService] == legacyData,
                  "explicit re-save still leaves the legacy item untouched")
    }

    private static func testLegacyReadRejectionPreservesOldData() async throws {
        let defaults = FakeSessionDefaults()
        let keychain = MockKeychain()
        let legacy = SteamContentSavedSession(
            username: "denied-fixture", refreshToken: "denied-token", guardData: nil)
        let legacyData = try JSONEncoder().encode(legacy)
        keychain.items[SteamContentKeychainSessionStore.legacyService] = legacyData
        keychain.rejectLoadServices = [SteamContentKeychainSessionStore.legacyService]

        let store = SteamContentKeychainSessionStore(api: keychain, defaults: defaults)
        do {
            _ = try await store.load()
            throw KeychainTestFailure(description: "denied legacy read must surface readFailed")
        } catch SteamContentSessionStoreError.readFailed {
            checks += 1
            print("PASS denied legacy read reports readFailed")
        }
        try check(keychain.items[SteamContentKeychainSessionStore.legacyService] == legacyData,
                  "denied legacy read preserves the old credential bytes")
        try check(keychain.items[SteamContentKeychainSessionStore.service] == nil,
                  "denied legacy read creates no Glimmer credential")
        try check(!keychain.deleteServices.contains(SteamContentKeychainSessionStore.legacyService),
                  "denied legacy read performs no destructive delete")
        let legacyLoadsAfterDenial = keychain.loadServices.filter {
            $0 == SteamContentKeychainSessionStore.legacyService
        }.count
        let reopened = SteamContentKeychainSessionStore(api: keychain, defaults: defaults)
        let secondAttempt = try await reopened.load()
        try check(secondAttempt == nil,
                  "denied legacy read becomes a one-time best effort instead of an automatic retry loop")
        try check(keychain.loadServices.filter {
            $0 == SteamContentKeychainSessionStore.legacyService
        }.count == legacyLoadsAfterDenial,
                  "later automatic loads do not prompt for the denied legacy item again")
    }

    private static func testDeleteRequiresDurableTombstone() async throws {
        let defaults = FakeSessionDefaults()
        let keychain = MockKeychain()
        let session = SteamContentSavedSession(
            username: "durable-tombstone", refreshToken: "current-token", guardData: nil)
        let store = SteamContentKeychainSessionStore(api: keychain, defaults: defaults)
        try await store.save(session)
        let currentData = keychain.items[SteamContentKeychainSessionStore.service]
        defaults.synchronizeResult = false
        do {
            try await store.delete()
            throw KeychainTestFailure(description: "delete must fail when its tombstone cannot be committed")
        } catch SteamContentSessionStoreError.deleteFailed {
            checks += 1
            print("PASS delete reports failure when its suppression tombstone cannot be committed")
        }
        try check(keychain.items[SteamContentKeychainSessionStore.service] == currentData,
                  "uncommitted delete tombstone leaves the current credential intact")
        try check(!keychain.deleteServices.contains(SteamContentKeychainSessionStore.service),
                  "uncommitted delete tombstone never invokes Keychain deletion")
        defaults.synchronizeResult = true
        try await store.delete()
        try check(keychain.items[SteamContentKeychainSessionStore.service] == nil,
                  "delete retries successfully after the tombstone store recovers")
    }
}
