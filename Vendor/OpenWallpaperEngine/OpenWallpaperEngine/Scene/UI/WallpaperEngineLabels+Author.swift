import Foundation

extension WallpaperEngineLabels {
    /// WE's labels with the wallpaper's own translations (`WallpaperAuthorLocalization`) in the
    /// app's language, the code `applyGeneralSettings` sends scripts
    /// (`SceneScriptGeneralSettings`), falling back to its English.
    static func load(projectJSON root: [String: Any]?, assets: URL? = WallpaperEngineAssets.directory,
                     languages: [String] = Locale.preferredLanguages) -> WallpaperEngineLabels {
        let labels = load(assets: assets, languages: languages)
        guard let root else { return labels }
        return labels.addingAuthorTranslations(projectJSON: root, languages: languages)
    }

    /// `load(projectJSON:)` from the wallpaper folder's project.json; WE's labels alone when it
    /// can't be read (logged).
    static func load(wallpaperDirectory: URL, assets: URL? = WallpaperEngineAssets.directory,
                     languages: [String] = Locale.preferredLanguages) -> WallpaperEngineLabels {
        let url = WEProject.url(in: wallpaperDirectory)
        var root: [String: Any]?
        do {
            root = try WEProject.json(in: wallpaperDirectory)
        } catch {
            OWELog.error(.library, "\(url.path) can't be read, so its translations aren't used: \(error)")
        }
        return load(projectJSON: root, assets: assets, languages: languages)
    }

    /// These labels with the translations of the project.json `root`.
    func addingAuthorTranslations(projectJSON root: [String: Any],
                                  languages: [String] = Locale.preferredLanguages) -> WallpaperEngineLabels {
        let localization = WallpaperAuthorLocalization(projectJSON: root)
        guard !localization.tables.isEmpty else { return self }
        let language = SceneScriptGeneralSettings.language(for: languages)
        let english = localization.table(for: WallpaperAuthorLocalization.fallbackLanguage)
        // In English the author's table is English's, which WE's own English beats.
        let localized = language == WallpaperAuthorLocalization.fallbackLanguage ? [:] : localization.table(for: language)
        return addingAuthorTranslations(localized: localized, english: english)
    }
}
