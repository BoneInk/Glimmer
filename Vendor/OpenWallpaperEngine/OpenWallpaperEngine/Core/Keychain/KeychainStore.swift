import Foundation
import Security

/// Generic-password items of one keychain service, one item per account.
///
/// Items are this-device-only and never synced through iCloud. The data protection keychain is
/// tried first; a build without a keychain entitlement (ad-hoc or unsigned, as in CI) gets
/// `errSecMissingEntitlement` there and falls back to the login keychain.
///
/// An isolated copy (the test host, a copy started with `OWE_ISOLATED_STATE`) keeps its items in
/// memory instead (`Backend.processDefault`) and never calls the Security framework: a keychain
/// prompt there blocked whole test runs, and its items would otherwise sit in the login keychain.
struct KeychainStore: KeychainStoring {
    /// Where the items live.
    enum Backend: Sendable {
        /// The keychain.
        case system
        /// This process's memory.
        case memory(InMemoryKeychain)

        /// The keychain for the user's real state, memory for an isolated copy.
        static func `for`(_ location: AppStorageLocation) -> Backend {
            location.isIsolated ? .memory(.shared) : .system
        }

        /// This process's backend, chosen once from its store.
        static let processDefault = Backend.for(.current)
    }

    let service: String
    let backend: Backend

    init(service: String, backend: Backend = .processDefault) {
        self.service = service
        self.backend = backend
    }

    struct Failure: Error, CustomStringConvertible {
        let operation: String
        let status: OSStatus

        var description: String {
            let reason = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
            return "keychain \(operation) failed: \(reason) (\(status))"
        }
    }

    /// The value stored for `account`, or `nil` when there is none.
    func string(forAccount account: String) throws -> String? {
        if case .memory(let memory) = backend { return memory.string(service: service, account: account) }
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        var status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecMissingEntitlement || status == errSecItemNotFound {
            // An item written while the build lacked the entitlement lives in the login keychain.
            query[kSecUseDataProtectionKeychain as String] = false
            status = SecItemCopyMatching(query as CFDictionary, &result)
        }
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
                throw Failure(operation: "read", status: errSecDecode)
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw Failure(operation: "read", status: status)
        }
    }

    /// Stores `value` for `account`, replacing any existing value.
    func set(_ value: String, forAccount account: String) throws {
        if case .memory(let memory) = backend { return memory.set(value, service: service, account: account) }
        let data = Data(value.utf8)
        var status = write(data, query: baseQuery(account: account))
        if status == errSecMissingEntitlement {
            var legacy = baseQuery(account: account)
            legacy[kSecUseDataProtectionKeychain as String] = false
            status = write(data, query: legacy)
        }
        guard status == errSecSuccess else { throw Failure(operation: "write", status: status) }
    }

    /// Deletes the value for `account` from both keychains. Deleting a missing value succeeds.
    func removeValue(forAccount account: String) throws {
        if case .memory(let memory) = backend { return memory.removeValue(service: service, account: account) }
        var query = baseQuery(account: account)
        for usesDataProtection in [true, false] {
            query[kSecUseDataProtectionKeychain as String] = usesDataProtection
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound || status == errSecMissingEntitlement else {
                throw Failure(operation: "delete", status: status)
            }
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    private func write(_ data: Data, query: [String: Any]) -> OSStatus {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard status == errSecItemNotFound else { return status }
        return SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
    }
}
