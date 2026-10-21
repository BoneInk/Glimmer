import Foundation

/// A wallpaper's own translations, project.json's `general.localization` (the docs' Localization
/// pages for web and scene wallpapers): one table per WE language code (`en-us`, `de-de`,
/// `zh-chs`…), each mapping the `ui_` keys its property titles and combo labels use to text.
///
/// Read as WE's browse UI reads it (`localeLoaderSupport.insertTranslations` in
/// `ui/dist/scripts/scripts.js`): only keys starting with `ui_` are kept (the docs: other labels
/// aren't recognised as tokens), keys and language codes match exactly, and a value that isn't
/// text is dropped. `WallpaperEngineLabels.addingAuthorTranslations` resolves them.
struct WallpaperAuthorLocalization: Equatable {
    /// The prefix of a translatable key (`0===t.indexOf("ui_")`).
    static let keyPrefix = "ui_"
    /// WE's fallback language (`$translateProvider.fallbackLanguage("en-us")`).
    static let fallbackLanguage = "en-us"

    /// Language code → key → text.
    let tables: [String: [String: String]]

    init(tables: [String: [String: String]] = [:]) {
        self.tables = tables.mapValues { $0.filter { $0.key.hasPrefix(Self.keyPrefix) } }.filter { !$0.value.isEmpty }
    }

    /// From a whole project.json; empty without `general.localization`. Each language is read on
    /// its own, so one malformed table doesn't drop the others.
    init(projectJSON root: [String: Any]) {
        guard let localization = (root["general"] as? [String: Any])?["localization"] else {
            self.init()
            return
        }
        guard let languages = localization as? [String: Any] else {
            OWELog.error(.library, "project.json general.localization isn't an object; its translations are ignored")
            self.init()
            return
        }
        var tables: [String: [String: String]] = [:]
        for (language, table) in languages {
            guard let entries = table as? [String: Any] else {
                OWELog.error(.library, "project.json general.localization.\(language) isn't an object; ignored")
                continue
            }
            tables[language] = entries.compactMapValues { $0 as? String }
        }
        self.init(tables: tables)
    }

    /// The table of a WE language code; empty when the wallpaper has none.
    func table(for language: String) -> [String: String] {
        tables[language] ?? [:]
    }
}
