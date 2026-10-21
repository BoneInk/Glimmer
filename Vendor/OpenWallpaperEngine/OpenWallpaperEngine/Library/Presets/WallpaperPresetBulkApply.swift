import Foundation

/// "Apply to All Wallpapers" in Your Presets: a preset's values go to every installed wallpaper
/// that has a property with the same key and type. A wallpaper with no such property is left
/// alone. Which wallpapers change is the user's choice (`Mode`).
struct WallpaperPresetBulkApply {
    enum Mode: Hashable {
        /// Only wallpapers whose properties were never set by the user (no saved edit or preset).
        case uncustomizedOnly
        /// Every wallpaper with a matching property, over what the user set.
        case replaceCustomizations
    }

    struct Result: Equatable {
        var applied = 0
        /// Wallpapers left alone because the user customized them (`uncustomizedOnly`).
        var keptCustomized = 0
        /// Wallpapers without a property the preset sets.
        var withoutMatch = 0
    }

    /// The preset's values and the project.json definitions of the wallpaper it was saved from,
    /// which give each key its type.
    let values: [String: String]
    let sourceDefinitions: [String: UserPropertyDefinition]
    /// The wallpaper the preset belongs to; it is skipped.
    let sourceIdentity: WallpaperSettingsIdentity

    /// Applies to each of `wallpapers` and returns what happened. `publish` hands a changed store
    /// to its running wallpaper (runtime key, the values set).
    func apply(to wallpapers: [WEWallpaper], mode: Mode, defaults: UserDefaults = .app,
               publish: (String, [String: String]) -> Void = Self.publishMerging) -> Result {
        var result = Result()
        for wallpaper in wallpapers {
            let identity = WallpaperSettingsIdentity.resolve(wallpaper, defaults: defaults)
            guard identity != sourceIdentity else { continue }
            let definitions = WallpaperEngineShareJSON.definitions(in: wallpaper.wallpaperDirectory)
            let matching = matchingValues(for: definitions)
            guard !matching.isEmpty else {
                result.withoutMatch += 1
                continue
            }
            let scopes = Self.savedScopes(of: identity, defaults: defaults)
            let customized = scopes.contains { defaults.bool(forKey: identity.key(.explicitUserProperties, scope: $0)) }
            if customized, mode == .uncustomizedOnly {
                result.keptCustomized += 1
                continue
            }
            let projectDefaults = definitions.mapValues(\.defaultValue)
            for scope in scopes {
                var stored = defaults.object(forKey: identity.key(.userProperties, scope: scope)) as? [String: String]
                    ?? projectDefaults
                stored.merge(matching) { _, new in new }
                defaults.set(stored, forKey: identity.key(.userProperties, scope: scope))
                defaults.set(true, forKey: identity.key(.explicitUserProperties, scope: scope))
                publish(scope.runtimeKey(directory: wallpaper.settingsDirectory), matching)
            }
            NotificationCenter.default.post(name: .wallpaperPropertiesDidSave, object: wallpaper.settingsDirectory.path)
            result.applied += 1
        }
        return result
    }

    /// The preset's values whose key the wallpaper defines with the same type (a combo's value
    /// must also be one of its options).
    func matchingValues(for definitions: [String: UserPropertyDefinition]) -> [String: String] {
        var matching: [String: String] = [:]
        for (key, value) in values {
            guard let source = sourceDefinitions[key], let target = definitions[key], source.type == target.type,
                  let converted = WallpaperEngineShareJSON.oweValue(WallpaperEngineShareJSON.weValue(value, type: source.type),
                                                                    for: target) else { continue }
            matching[key] = converted
        }
        return matching
    }

    /// The shared store and every display store saved for `identity`.
    static func savedScopes(of identity: WallpaperSettingsIdentity, defaults: UserDefaults) -> [WallpaperPropertyScope] {
        let prefix = identity.key(.userProperties, scope: .shared) + ".display."
        let displays = defaults.dictionaryRepresentation().keys.compactMap { key -> WallpaperPropertyScope? in
            key.hasPrefix(prefix) ? .display(String(key.dropFirst(prefix.count))) : nil
        }
        return [.shared] + displays.sorted { $0.description < $1.description }
    }

    /// Hands only the changed keys to a running wallpaper; the rest of its store stays.
    static func publishMerging(_ runtimeKey: String, _ values: [String: String]) {
        WallpaperServices.shared.setUserProperties(values, wallpaper: runtimeKey, replacing: false)
    }
}
