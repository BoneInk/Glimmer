import Foundation

/// Generic-password items kept in this process's memory, by service and account. The keychain of
/// an isolated copy (`KeychainStore.Backend.processDefault`): the test host and scripted copies
/// never call the Security framework, so they can't block on a keychain prompt or touch the
/// user's items. Its contents end with the process.
final class InMemoryKeychain: @unchecked Sendable { // `items` is only touched under `lock`.
    /// The one store of this process.
    static let shared = InMemoryKeychain()

    private let lock = NSLock()
    private var items: [String: [String: String]] = [:]

    func string(service: String, account: String) -> String? {
        lock.withLock { items[service]?[account] }
    }

    func set(_ value: String, service: String, account: String) {
        lock.withLock { items[service, default: [:]][account] = value }
    }

    func removeValue(service: String, account: String) {
        lock.withLock { _ = items[service]?.removeValue(forKey: account) }
    }
}
