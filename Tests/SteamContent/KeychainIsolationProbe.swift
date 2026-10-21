import Foundation
import Security
import CryptoKit

private struct ProbeFailure: Error { let operation: String; let status: OSStatus }
private func requireSuccess(_ status: OSStatus, _ operation: String) throws {
    guard status == errSecSuccess else { throw ProbeFailure(operation: operation, status: status) }
}

// The production query is unchanged except for an explicit private-keychain boundary.
// There is no fallback to login/default/global search when any operation fails.
private final class IsolatedSecurityAPI: SteamContentKeychainAccessing, @unchecked Sendable {
    let keychain: SecKeychain
    private let lock = NSLock()
    private var recorded: [String] = []
    init(_ keychain: SecKeychain) { self.keychain = keychain }
    func operations() -> [String] { lock.lock(); defer { lock.unlock() }; return recorded }
    private func scoped(_ query: [String: Any], add: Bool, operation: String) -> [String: Any] {
        precondition((query[kSecClass as String] as? String) == (kSecClassGenericPassword as String))
        precondition((query[kSecAttrSynchronizable as String] as? Bool) == false)
        for key in [kSecUseDataProtectionKeychain, kSecAttrAccessGroup, kSecAttrAccessible, kSecAttrAccess, kSecAttrAccessControl] {
            precondition(query[key as String] == nil, "production query unexpectedly changed its classic/default-ACL shape")
        }
        precondition(query[kSecMatchSearchList as String] == nil && query[kSecUseKeychain as String] == nil)
        var request = query
        request[(add ? kSecUseKeychain : kSecMatchSearchList) as String] = add ? keychain : [keychain]
        lock.lock(); recorded.append(operation); lock.unlock()
        return request
    }
    func load(_ query: [String: Any]) -> (OSStatus, Data?) {
        var value: CFTypeRef?
        let result = SecItemCopyMatching(scoped(query, add: false, operation: "load") as CFDictionary, &value)
        return (result, value as? Data)
    }
    func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(scoped(attributes, add: true, operation: "add") as CFDictionary, nil)
    }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        precondition(Set(attributes.keys) == [kSecValueData as String], "update must not widen ACL")
        return SecItemUpdate(scoped(query, add: false, operation: "update") as CFDictionary, attributes as CFDictionary)
    }
    func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(scoped(query, add: false, operation: "delete") as CFDictionary)
    }
    func itemQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: SteamContentKeychainSessionStore.service,
         kSecAttrAccount as String: SteamContentKeychainSessionStore.account,
         kSecAttrSynchronizable as String: false,
         kSecMatchSearchList as String: [keychain], kSecMatchLimit as String: kSecMatchLimitOne]
    }
    func defaultACLSignature() throws -> [String] {
        var query = itemQuery(); query[kSecReturnRef as String] = true
        var item: CFTypeRef?
        try requireSuccess(SecItemCopyMatching(query as CFDictionary, &item), "read-own-item-reference")
        guard let item, CFGetTypeID(item) == SecKeychainItemGetTypeID() else { throw ProbeFailure(operation: "item-reference-type", status: errSecInternalError) }
        var access: SecAccess?
        try requireSuccess(SecKeychainItemCopyAccess(unsafeBitCast(item, to: SecKeychainItem.self), &access), "read-own-default-access")
        guard let access else { throw ProbeFailure(operation: "missing-own-access", status: errSecInternalError) }
        let decryptACLs = SecAccessCopyMatchingACLList(access, kSecACLAuthorizationDecrypt) as? [SecACL] ?? []
        guard !decryptACLs.isEmpty else { throw ProbeFailure(operation: "missing-default-decrypt-acl", status: errSecInternalError) }
        var signatures: [String] = []
        for acl in decryptACLs {
            var apps: CFArray?; var description: CFString?; var selector = SecKeychainPromptSelector()
            try requireSuccess(SecACLCopyContents(acl, &apps, &description, &selector), "read-own-acl-contents")
            // NULL trusted-app list means allow any application. Do not accept that as default protection.
            guard let apps, CFArrayGetCount(apps) > 0 else { throw ProbeFailure(operation: "unrestricted-default-acl", status: errSecInternalError) }
            var identities: [String] = []
            for app in apps as! [SecTrustedApplication] {
                var data: CFData?
                try requireSuccess(SecTrustedApplicationCopyData(app, &data), "read-own-trusted-app")
                guard let data else { throw ProbeFailure(operation: "missing-trusted-app", status: errSecInternalError) }
                identities.append(SHA256.hash(data: data as Data).map { String(format: "%02x", $0) }.joined())
            }
            signatures.append("\(selector):" + identities.sorted().joined(separator: ","))
        }
        return signatures.sorted()
    }
}

@main struct KeychainIsolationProbe {
    static func main() async {
        do { try await run() }
        catch let error as ProbeFailure {
            print("{\"passed\":0,\"operation\":\"\(error.operation)\",\"status\":\(error.status)}")
            exit(1)
        } catch { print("{\"passed\":0,\"errorType\":\"\(String(describing: type(of: error)))\"}"); exit(1) }
    }
    static func run() async throws {
        guard CommandLine.arguments.count == 2 else { throw ProbeFailure(operation: "fixture-root-required", status: errSecParam) }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let path = root.appendingPathComponent("isolated-session.keychain").path
        let suite = "com.boneink.glimmer.keychain-probe.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); _ = defaults.synchronize() }
        // This flag is local to this probe process. Never enable SecurityAgent UI or alter any system setting.
        var interaction = DarwinBoolean(false)
        try requireSuccess(SecKeychainGetUserInteractionAllowed(&interaction), "read-process-ui-policy")
        try requireSuccess(SecKeychainSetUserInteractionAllowed(false), "disable-process-ui")
        defer { _ = SecKeychainSetUserInteractionAllowed(interaction.boolValue) }
        var password = Array((UUID().uuidString + UUID().uuidString).utf8)
        defer { password.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        var keychain: SecKeychain?
        let create = password.withUnsafeBytes { bytes in
            SecKeychainCreate(path, UInt32(bytes.count), bytes.baseAddress, false, nil, &keychain)
        }
        try requireSuccess(create, "create-private-keychain")
        guard let keychain else { throw ProbeFailure(operation: "missing-private-keychain", status: errSecInternalError) }
        var deleted = false
        defer { if !deleted { _ = SecKeychainDelete(keychain) } }
        try requireSuccess(password.withUnsafeBytes { SecKeychainUnlock(keychain, UInt32($0.count), $0.baseAddress, true) }, "unlock-own-keychain")
        let api = IsolatedSecurityAPI(keychain)
        let store = SteamContentKeychainSessionStore(defaultsSuiteName: suite, api: api)
        var checks: [String] = []
        func check(_ ok: Bool, _ name: String) throws {
            guard ok else { throw ProbeFailure(operation: name, status: errSecInternalError) }; checks.append(name)
        }
        try check(try await store.load() == nil, "missing-private-item-returns-nil")
        let initial = SteamContentSavedSession(username: "isolated-fixture", refreshToken: UUID().uuidString, guardData: "fixture-guard")
        try await store.save(initial)
        try check(try await store.load() == initial, "production-query-real-classic-add-read")
        let acl = try api.defaultACLSignature()
        try check(!acl.isEmpty, "default-decrypt-acl-restricts-trusted-applications")
        let rotated = SteamContentSavedSession(username: "isolated-fixture", refreshToken: UUID().uuidString, guardData: "rotated-fixture")
        try await store.save(rotated)
        try check(api.operations().contains("update"), "duplicate-add-uses-real-secitemupdate")
        try check(try await store.load() == rotated, "updated-fixture-secret-is-readable")
        try check(try api.defaultACLSignature() == acl, "secret-update-preserves-default-decrypt-acl")
        let reopened = SteamContentKeychainSessionStore(defaultsSuiteName: suite, api: api)
        try check(try await reopened.load() == rotated, "new-store-instance-recovers-persisted-fixture")
        try requireSuccess(SecKeychainLock(keychain), "lock-own-keychain")
        do { _ = try await reopened.load(); throw ProbeFailure(operation: "locked-own-item-must-fail", status: errSecInternalError) }
        catch is SteamContentSessionStoreError { checks.append("locked-private-keychain-fails-without-interaction") }
        try requireSuccess(password.withUnsafeBytes { SecKeychainUnlock(keychain, UInt32($0.count), $0.baseAddress, true) }, "reunlock-own-keychain")
        try check(try await reopened.load() == rotated, "own-keychain-reunlock-restores-read")
        try await reopened.delete()
        try check(try await store.load() == nil, "delete-tombstone-suppresses-restoration")
        let rawStatus = SecItemCopyMatching(api.itemQuery() as CFDictionary, nil)
        try check(rawStatus == errSecItemNotFound, "delete-removes-actual-private-keychain-item")
        try await reopened.delete()
        checks.append("real-private-delete-is-idempotent")
        try await reopened.save(initial)
        try check(try await reopened.load() == initial, "explicit-resave-clears-only-fixture-suppression")
        try await reopened.delete()
        try requireSuccess(SecKeychainDelete(keychain), "delete-own-keychain-file-and-cache")
        deleted = true
        try check(!FileManager.default.fileExists(atPath: path) && !FileManager.default.fileExists(atPath: path + "-db"), "owned-keychain-file-deleted")
        try check(!api.operations().isEmpty, "all-production-secitem-calls-explicitly-private-scoped")
        let report: [String: Any] = ["passed": checks.count, "checks": checks,
            "scope": "real macOS Security APIs; production actor; one private fixture keychain; synthetic session values; no Steam/auth/network",
            "loginKeychainAccessed": false, "globalSearchListReadOrSet": false, "defaultKeychainReadOrSet": false,
            "dataProtectionKeychainRequested": false, "fixtureKeychainDeleted": deleted]
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }
}
