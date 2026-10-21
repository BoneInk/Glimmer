import Foundation

/// Research build only: never calls CFPreferences setters or reads a user's domains.
final class ResearchMemoryDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]
    private let memoryLock = NSRecursiveLock()
    override func object(forKey key: String) -> Any? {
        memoryLock.lock(); defer { memoryLock.unlock() }; return values[key]
    }
    override func set(_ value: Any?, forKey key: String) {
        memoryLock.lock(); defer { memoryLock.unlock() }; values[key] = value
    }
    override func removeObject(forKey key: String) { set(nil, forKey: key) }
    override func dictionaryRepresentation() -> [String: Any] {
        memoryLock.lock(); defer { memoryLock.unlock() }; return values
    }
    override func register(defaults: [String: Any]) {
        memoryLock.lock(); defer { memoryLock.unlock() }; values.merge(defaults) { old, _ in old }
    }
    override func persistentDomain(forName name: String) -> [String: Any]? { dictionaryRepresentation() }
    override func setPersistentDomain(_ domain: [String: Any], forName name: String) {
        memoryLock.lock(); defer { memoryLock.unlock() }; values = domain
    }
    override func removePersistentDomain(forName name: String) {
        memoryLock.lock(); defer { memoryLock.unlock() }; values.removeAll()
    }
    override func set(_ value: Bool, forKey key: String) { set(value as Any?, forKey: key) }
    override func set(_ value: Int, forKey key: String) { set(value as Any?, forKey: key) }
    override func set(_ value: Float, forKey key: String) { set(value as Any?, forKey: key) }
    override func set(_ value: Double, forKey key: String) { set(value as Any?, forKey: key) }
    override func set(_ value: URL?, forKey key: String) { set(value as Any?, forKey: key) }
    override func bool(forKey key: String) -> Bool { (object(forKey: key) as? NSNumber)?.boolValue ?? false }
    override func integer(forKey key: String) -> Int { (object(forKey: key) as? NSNumber)?.intValue ?? 0 }
    override func float(forKey key: String) -> Float { (object(forKey: key) as? NSNumber)?.floatValue ?? 0 }
    override func double(forKey key: String) -> Double { (object(forKey: key) as? NSNumber)?.doubleValue ?? 0 }
    override func string(forKey key: String) -> String? { object(forKey: key) as? String }
    override func array(forKey key: String) -> [Any]? { object(forKey: key) as? [Any] }
    override func dictionary(forKey key: String) -> [String: Any]? { object(forKey: key) as? [String: Any] }
    override func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    override func stringArray(forKey key: String) -> [String]? { object(forKey: key) as? [String] }
    override func url(forKey key: String) -> URL? { object(forKey: key) as? URL }
    override func synchronize() -> Bool { true }
}
