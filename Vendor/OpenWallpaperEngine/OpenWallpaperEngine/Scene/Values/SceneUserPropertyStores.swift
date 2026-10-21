import Foundation

/// User properties of every running wallpaper instance, keyed by its store
/// (`WallpaperPropertyScope.runtimeKey`: the wallpaper's directory path, with a display's id when
/// the display has its own properties).
///
/// Two displays showing different scenes, or one scene with different properties, each have their
/// own entry, so neither overwrites the other's properties, and switching a display to another
/// wallpaper can't leak the previous wallpaper's keys into the new one. Not thread-safe: the owner (`SceneUserPropertyService`)
/// guards it with its lock.
struct SceneUserPropertyStores {
    struct Entry: Equatable {
        /// Property values as WE stores them ("1", "0.5 0.2 1", "true", a combo value).
        var strings: [String: String] = [:]
        /// Numeric view of `strings`, plus values scripts publish with `setGlobal`.
        var numbers: [String: Double] = [:]
    }

    private(set) var entries: [String: Entry] = [:]
    /// The wallpaper un-keyed reads and writes go to: the one being rendered, or else the one
    /// most recently written.
    var activeKey = ""

    var active: Entry {
        get { entries[activeKey] ?? Entry() }
        set { entries[activeKey] = newValue }
    }

    func entry(for key: String) -> Entry { entries[key] ?? Entry() }

    /// Sets `values` on `key`'s entry. With `replacing`, keys missing from `values` are removed
    /// (numbers published by scripts are kept). Returns the keys whose value changed.
    @discardableResult
    mutating func set(_ values: [String: String], for key: String, replacing: Bool) -> [String] {
        var entry = entries[key] ?? Entry()
        var changed: [String] = []
        if replacing {
            for stale in entry.strings.keys where values[stale] == nil {
                entry.strings[stale] = nil
                entry.numbers[stale] = nil
                changed.append(stale)
            }
        }
        for (name, value) in values {
            if entry.strings[name] != value { changed.append(name) }
            entry.strings[name] = value
            entry.numbers[name] = Self.number(value)
        }
        entries[key] = entry
        return changed
    }

    /// Drops a wallpaper instance's properties.
    mutating func remove(_ key: String) {
        entries[key] = nil
    }

    /// WE's numeric reading of a property string; booleans are 1/0, anything else non-numeric is 0.
    static func number(_ value: String) -> Double {
        Double(value) ?? (value.lowercased() == "true" ? 1 : 0)
    }
}
