import Foundation

/// Reads and writes the system preferences theming changes. Everything that would change the Mac's
/// settings goes through it, so tests use a fake and an isolated copy of the app a writer that
/// never writes (`ReadOnlyAppearanceWriter`).
public protocol SystemAppearanceWriter: AnyObject {
    /// The stored value; nil when the key is absent (the system default).
    func value(for key: SystemPreferenceKey) -> PreferenceValue?
    /// Stores `value`, or removes the key for nil.
    func setValue(_ value: PreferenceValue?, for key: SystemPreferenceKey)
    /// Tells running apps that `change` happened, after the values are stored.
    func post(_ change: SystemAppearanceChange)
}

/// The current user's global preferences (`NSGlobalDomain`, any host), the store
/// `GlobalPreferencesWriter` reads and writes. A seam, so tests check the path without the Mac's
/// settings.
public protocol GlobalPreferencesStore: AnyObject {
    func copyValue(forKey key: String) -> CFPropertyList?
    /// Stores `value`, or removes the key for nil.
    func setValue(_ value: CFPropertyList?, forKey key: String)
    /// Flushes to cfprefsd, which hands the new values to every process reading the domain.
    func synchronize()
}

/// The real global domain: `kCFPreferencesAnyApplication`, the current user, any host, which is
/// where System Settings keeps these keys (`defaults read -g` shows them). Not a `UserDefaults`
/// suite, which would land in the app's own domain.
public final class CFGlobalPreferencesStore: GlobalPreferencesStore {
    public init() {}

    public func copyValue(forKey key: String) -> CFPropertyList? {
        CFPreferencesCopyValue(key as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser,
                               kCFPreferencesAnyHost)
    }

    public func setValue(_ value: CFPropertyList?, forKey key: String) {
        CFPreferencesSetValue(key as CFString, value, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser,
                              kCFPreferencesAnyHost)
    }

    public func synchronize() {
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }
}

/// Posts a distributed notification to every app at once. A seam for the tests.
public protocol DistributedNotificationPosting: AnyObject {
    func post(_ name: String)
}

/// `DistributedNotificationCenter`, delivered immediately (also to suspended apps), as System
/// Settings does.
public final class SystemDistributedNotifications: DistributedNotificationPosting {
    public init() {}

    public func post(_ name: String) {
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name(name), object: nil, userInfo: nil, deliverImmediately: true)
    }
}

/// The real writer: the global preferences (`CFGlobalPreferencesStore`), then the distributed
/// notifications System Settings posts (`SystemAppearanceChange.notificationNames`).
public final class GlobalPreferencesWriter: SystemAppearanceWriter {
    private let store: GlobalPreferencesStore
    private let notifications: DistributedNotificationPosting

    public init(store: GlobalPreferencesStore = CFGlobalPreferencesStore(),
                notifications: DistributedNotificationPosting = SystemDistributedNotifications()) {
        self.store = store
        self.notifications = notifications
    }

    public func value(for key: SystemPreferenceKey) -> PreferenceValue? {
        Self.decode(store.copyValue(forKey: key.rawValue))
    }

    public func setValue(_ value: PreferenceValue?, for key: SystemPreferenceKey) {
        let stored: CFPropertyList?
        switch value {
        case .integer(let number): stored = number as NSNumber
        case .string(let text): stored = text as NSString
        case nil: stored = nil
        }
        store.setValue(stored, forKey: key.rawValue)
        store.synchronize()
    }

    public func post(_ change: SystemAppearanceChange) {
        change.notificationNames.forEach(notifications.post)
    }

    static func decode(_ stored: CFPropertyList?) -> PreferenceValue? {
        if let text = stored as? String { return .string(text) }
        if let number = stored as? NSNumber { return .integer(number.intValue) }
        return nil
    }
}

/// Reads the real preferences and writes nothing: an isolated copy of the app (tests, screenshots)
/// computes and logs what it would do without changing the Mac.
public final class ReadOnlyAppearanceWriter: SystemAppearanceWriter {
    private let reader = GlobalPreferencesWriter()
    /// What would have been written, last value per key.
    public private(set) var skipped: [SystemPreferenceKey: PreferenceValue?] = [:]

    public init() {}

    public func value(for key: SystemPreferenceKey) -> PreferenceValue? {
        if let skippedValue = skipped[key] { return skippedValue }
        return reader.value(for: key)
    }

    public func setValue(_ value: PreferenceValue?, for key: SystemPreferenceKey) {
        skipped[key] = .some(value)
    }

    public func post(_ change: SystemAppearanceChange) {}
}
