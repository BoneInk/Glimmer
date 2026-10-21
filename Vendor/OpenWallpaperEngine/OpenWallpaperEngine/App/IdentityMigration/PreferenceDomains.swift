import Foundation

/// The user's persistent defaults domains by name (`~/Library/Preferences/<name>.plist`), read and
/// written through CFPreferences, so writing this app's own domain stays coherent with
/// `UserDefaults.standard` in the process. A stand-in replaces it in tests.
protocol PreferenceDomains {
    /// The domain's values; empty when it has none.
    func values(in domain: String) -> [String: Any]
    /// Sets each of `values` in `domain`, leaving its other keys as they are, and synchronizes.
    func set(_ values: [String: Any], in domain: String)
    /// Deletes `keys` from `domain` and synchronizes.
    func remove(_ keys: [String], from domain: String)
}

struct SystemPreferenceDomains: PreferenceDomains {
    func values(in domain: String) -> [String: Any] {
        let name = domain as CFString
        CFPreferencesAppSynchronize(name)
        guard let keys = CFPreferencesCopyKeyList(name, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String],
              !keys.isEmpty else { return [:] }
        let values = CFPreferencesCopyMultiple(keys as CFArray, name, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return values as? [String: Any] ?? [:]
    }

    func set(_ values: [String: Any], in domain: String) {
        let name = domain as CFString
        for (key, value) in values {
            CFPreferencesSetAppValue(key as CFString, value as CFPropertyList, name)
        }
        CFPreferencesAppSynchronize(name)
    }

    func remove(_ keys: [String], from domain: String) {
        let name = domain as CFString
        for key in keys {
            CFPreferencesSetAppValue(key as CFString, nil, name)
        }
        CFPreferencesAppSynchronize(name)
    }
}
