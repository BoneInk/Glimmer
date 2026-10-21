import Foundation

/// Moves a wallpaper's saved user properties between two stores, as WE's monitor menu does with
/// `transferWallpaperProperties` for "Copy to" and "Swap with" (its `ui/dist/scripts/scripts.js`):
/// the destination display then runs the wallpaper as the source display did.
///
/// A store's values are what it runs (`WallpaperSettingsIdentity.stored`): its own, else the shared
/// ones. What a store doesn't have is removed from the other, so it falls back the same way.
enum WallpaperPropertyTransfer {
    /// Every family's stored value of `identity` in `scope`.
    typealias Snapshot = [WallpaperSettingsIdentity.Family: Any]

    /// `identity`'s values in `source` become `destination`'s. Returns the user properties
    /// `destination` now has, for its running store.
    @discardableResult
    static func copy(_ identity: WallpaperSettingsIdentity, from source: WallpaperPropertyScope,
                     to destination: WallpaperPropertyScope, defaults: UserDefaults = .app) -> [String: String] {
        guard source != destination else { return userProperties(in: snapshot(identity, source, defaults)) }
        let values = snapshot(identity, source, defaults)
        write(values, of: identity, to: destination, defaults: defaults)
        return userProperties(in: values)
    }

    /// `identity`'s values in `first` and `second` change places. Returns each store's new user
    /// properties.
    @discardableResult
    static func swap(_ identity: WallpaperSettingsIdentity, _ first: WallpaperPropertyScope,
                     _ second: WallpaperPropertyScope,
                     defaults: UserDefaults = .app) -> (first: [String: String], second: [String: String]) {
        let firstValues = snapshot(identity, first, defaults), secondValues = snapshot(identity, second, defaults)
        guard first != second else { return (userProperties(in: firstValues), userProperties(in: secondValues)) }
        write(secondValues, of: identity, to: first, defaults: defaults)
        write(firstValues, of: identity, to: second, defaults: defaults)
        return (userProperties(in: secondValues), userProperties(in: firstValues))
    }

    private static func snapshot(_ identity: WallpaperSettingsIdentity, _ scope: WallpaperPropertyScope,
                                 _ defaults: UserDefaults) -> Snapshot {
        var values: Snapshot = [:]
        for family in WallpaperSettingsIdentity.Family.allCases {
            values[family] = identity.stored(family, scope: scope, defaults: defaults)
        }
        return values
    }

    private static func write(_ values: Snapshot, of identity: WallpaperSettingsIdentity,
                              to scope: WallpaperPropertyScope, defaults: UserDefaults) {
        for family in WallpaperSettingsIdentity.Family.allCases {
            let key = identity.key(family, scope: scope)
            if let value = values[family] { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
    }

    private static func userProperties(in values: Snapshot) -> [String: String] {
        values[.userProperties] as? [String: String] ?? [:]
    }
}
