import Foundation

/// One secret in the keychain. Errors are logged without the value.
struct KeychainSecret {
    let keychain: KeychainStore
    let account: String

    /// A service name under the app's bundle identifier, e.g. `<bundle id>.steam-web-api-key`, or
    /// under the isolated suite for tests and development copies, so they never touch the real item.
    static func service(_ suffix: String, prefix: String = AppStorageLocation.current.keychainServicePrefix) -> String {
        "\(prefix).\(suffix)"
    }

    /// The stored value, or `nil` when there is none or the keychain can't be read.
    func load() -> String? {
        do {
            guard let value = try keychain.string(forAccount: account), !value.isEmpty else { return nil }
            return value
        } catch {
            OWELog.error(.settings, "Can't read \(account) from \(keychain.service): \(error)")
            return nil
        }
    }

    func save(_ value: String) throws {
        try keychain.set(value, forAccount: account)
    }

    func remove() throws {
        try keychain.removeValue(forAccount: account)
    }
}
