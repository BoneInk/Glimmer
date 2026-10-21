import Foundation
import Security

/// The only persisted authentication fields. Passwords/OTP are never accepted here.
struct SteamContentSavedSession: Codable, Equatable, Sendable {
    let username: String
    let refreshToken: String
    let guardData: String?
    func validate() throws {
        guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, username.utf16.count <= 128,
              !username.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !refreshToken.isEmpty, refreshToken.utf16.count <= 8192,
              (guardData?.utf16.count ?? 0) <= 8192 else { throw SteamContentSessionStoreError.invalidData }
    }
}
protocol SteamContentSessionStoring: Sendable {
    func load() async throws -> SteamContentSavedSession?
    func save(_ session: SteamContentSavedSession) async throws
    func delete() async throws
}
enum SteamContentSessionStoreError: Error, LocalizedError, Sendable {
    case readFailed, saveFailed, deleteFailed, invalidData
    var errorDescription: String? {
        switch self {
        case .readFailed: return "无法读取 macOS 钥匙串。若旧版凭据访问被拒绝，请重新登录；旧钥匙串项目不会被删除。"
        case .saveFailed: return "当前 Steam 连接可用，但登录状态未能保存到 macOS 钥匙串。"
        case .deleteFailed: return "macOS 钥匙串中的登录状态未能清除，请重试退出登录。"
        case .invalidData: return "保存的 Steam 会话无效，请重新连接。"
        }
    }
}

/// Injectable Security boundary. Tests supply an in-memory peer and never call SecItem.
protocol SteamContentKeychainAccessing: Sendable {
    func load(_ query: [String: Any]) -> (OSStatus, Data?)
    func add(_ attributes: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

/// Minimal defaults boundary for the non-secret restore-intent bits. Tests use
/// an in-memory peer; production keeps the existing isolated-suite behavior.
protocol SteamContentSessionDefaultsStoring: AnyObject {
    func bool(forKey: String) -> Bool
    func set(_ value: Any?, forKey: String)
    func synchronize() -> Bool
}

extension UserDefaults: SteamContentSessionDefaultsStoring {}

struct SteamContentSecurityAPI: SteamContentKeychainAccessing {
    func load(_ query: [String: Any]) -> (OSStatus, Data?) {
        var value: CFTypeRef?; let status = SecItemCopyMatching(query as CFDictionary, &value)
        return (status, value as? Data)
    }
    func add(_ attributes: [String: Any]) -> OSStatus { SecItemAdd(attributes as CFDictionary, nil) }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus { SecItemUpdate(query as CFDictionary, attributes as CFDictionary) }
    func delete(_ query: [String: Any]) -> OSStatus { SecItemDelete(query as CFDictionary) }
}

/// Classic macOS Keychain; stable signing preserves the creator app identity across updates. Non-synchronizing and
/// default creator-app ACL: no custom access group, trusted-app list, ACL widening,
/// Data Protection/ThisDeviceOnly/Secure Enclave claim, or prompt bypass.
/// Constructing this actor does not call Security APIs. Inject only in the real app.
actor SteamContentKeychainSessionStore: SteamContentSessionStoring {
    static let service = GlimmerIdentity.keychainService
    static let legacyService = GlimmerIdentity.legacyKeychainService
    static let account = "primary-session"
    static let suppressionKey = "steamContentSessionRestoreSuppressed"
    static let legacyMigrationAttemptedKey = "glimmer.steamContentLegacyMigrationAttempted.v1"
    private let defaults: any SteamContentSessionDefaultsStoring
    private let api: any SteamContentKeychainAccessing
    init(defaultsSuiteName: String? = nil,
         api: any SteamContentKeychainAccessing = SteamContentSecurityAPI(),
         defaults defaultsStorage: (any SteamContentSessionDefaultsStoring)? = nil) {
        defaults = defaultsStorage
            ?? defaultsSuiteName.flatMap(UserDefaults.init(suiteName:))
            ?? UserDefaults.standard
        self.api = api
    }
    private func query() -> [String: Any] {
        query(service: Self.service)
    }
    private func query(service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: Self.account,
         kSecAttrSynchronizable as String: false]
    }
    func load() async throws -> SteamContentSavedSession? {
        guard !defaults.bool(forKey: Self.suppressionKey) else { return nil }
        if let saved = try load(service: Self.service) { return saved }

        // A creator-ACL prompt for the old item is attempted at most once. The
        // sign-out intent bit above always wins and therefore prevents old
        // credentials from reviving after an explicit delete.
        guard !defaults.bool(forKey: Self.legacyMigrationAttemptedKey) else { return nil }
        defaults.set(true, forKey: Self.legacyMigrationAttemptedKey)
        _ = defaults.synchronize()
        guard let legacy = try load(service: Self.legacyService) else { return nil }
        let data = try JSONEncoder().encode(legacy)
        guard data.count <= 65_536 else { throw SteamContentSessionStoreError.invalidData }
        var copy = query()
        copy[kSecValueData as String] = data
        copy[kSecAttrLabel as String] = "Glimmer Steam 会话"
        let status = api.add(copy)
        if status == errSecDuplicateItem {
            // Another launch won the copy race. Never overwrite its value.
            return try load(service: Self.service)
        }
        guard status == errSecSuccess else { throw SteamContentSessionStoreError.readFailed }
        return legacy
    }
    private func load(service: String) throws -> SteamContentSavedSession? {
        var request = query(service: service)
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        request[kSecReturnData as String] = true
        let (status, result) = api.load(request)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result, data.count <= 65_536 else {
            throw SteamContentSessionStoreError.readFailed
        }
        guard let saved = try? JSONDecoder().decode(SteamContentSavedSession.self, from: data) else {
            throw SteamContentSessionStoreError.invalidData
        }
        try saved.validate()
        return saved
    }
    func save(_ session: SteamContentSavedSession) async throws {
        try session.validate()
        let data = try JSONEncoder().encode(session)
        guard data.count <= 65_536 else { throw SteamContentSessionStoreError.invalidData }
        // A failed replacement must not revive a different account's older item.
        defaults.set(true, forKey: Self.suppressionKey)
        guard defaults.synchronize() else { throw SteamContentSessionStoreError.saveFailed }
        var request = query(); request[kSecValueData as String] = data; request[kSecAttrLabel as String] = "Glimmer Steam 会话"
        let status = api.add(request)
        if status == errSecDuplicateItem {
            // Updating only the secret preserves the existing default app ACL.
            guard api.update(query(), attributes: [kSecValueData as String: data]) == errSecSuccess else { throw SteamContentSessionStoreError.saveFailed }
        } else if status != errSecSuccess { throw SteamContentSessionStoreError.saveFailed }
        defaults.set(false, forKey: Self.suppressionKey)
        guard defaults.synchronize() else { throw SteamContentSessionStoreError.saveFailed }
    }
    func delete() async throws {
        // Only a non-sensitive intent bit goes into preferences. Even if a Keychain
        // prompt is denied or deletion fails, a new app instance cannot revive it.
        defaults.set(true, forKey: Self.suppressionKey)
        // Never remove a live credential until the tombstone is durably committed;
        // a failed preference flush must surface to the user instead of leaving a
        // future launch free to import the old legacy item again.
        guard defaults.synchronize() else { throw SteamContentSessionStoreError.deleteFailed }
        let status = api.delete(query())
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SteamContentSessionStoreError.deleteFailed }
    }
}
