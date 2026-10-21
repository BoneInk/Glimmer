import Foundation

/// The generic-password items of one keychain service, one per account: the keychain itself
/// (`KeychainStore`), or a stand-in in tests.
protocol KeychainStoring {
    var service: String { get }
    /// The value stored for `account`, or `nil` when there is none.
    func string(forAccount account: String) throws -> String?
    /// Stores `value` for `account`, replacing any existing value.
    func set(_ value: String, forAccount account: String) throws
    /// Deletes the value for `account`. Deleting a missing value succeeds.
    func removeValue(forAccount account: String) throws
}
