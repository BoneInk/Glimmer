import Foundation

/// What this launch of the app's executable is, read from its bundle and arguments before any app
/// lifecycle starts (`AppMain`). The helper runs (`HelperRunCommand`, `CrashWatcher`) exit
/// before this is asked.
enum AppLaunchMode: Equatable {
    /// Open Wallpaper Engine: the desktop wallpapers, the menu bar item, the library.
    case main
    /// The Wallpaper Editor alone, as its own app (`<app>/Contents/Helpers/Wallpaper Editor.app`,
    /// `AppBundleLayout`, launched with `--wallpaper-editor <folder>`): quitting either app leaves the
    /// other running. `folder` is the wallpaper to open first.
    case wallpaperEditor(URL?)

    static let wallpaperEditorArgument = "--wallpaper-editor"

    /// The mode of a process of `bundleIdentifier` launched with `arguments` (executable first):
    /// the editor's app is always the editor; the flag also runs the editor from the app's own
    /// executable (development).
    static func parse(_ arguments: [String], bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> AppLaunchMode {
        let isEditorApp = AppBundleLayout.isEditor(bundleIdentifier: bundleIdentifier)
        guard let index = arguments.firstIndex(of: wallpaperEditorArgument) else {
            return isEditorApp ? .wallpaperEditor(nil) : .main
        }
        let next = index + 1
        // A folder follows unless the next argument is another option (`-OWEIsolatedState …`).
        guard arguments.indices.contains(next), !arguments[next].isEmpty, !arguments[next].hasPrefix("-") else {
            return .wallpaperEditor(nil)
        }
        return .wallpaperEditor(URL(filePath: arguments[next], directoryHint: .isDirectory).standardizedFileURL)
    }

    /// The arguments that launch the editor on `folder`, keeping this process's isolation
    /// (`AppStorageLocation`: an isolated app opens an isolated editor) and the language the app
    /// was set to (`languages`, the app's `AppleLanguages`, which the editor's own domain lacks).
    static func wallpaperEditorArguments(folder: URL?, isolationTag: String?, languages: [String]? = nil) -> [String] {
        var arguments = [wallpaperEditorArgument]
        if let folder { arguments.append(folder.standardizedFileURL.path) }
        if let isolationTag { arguments += [AppStorageLocation.argumentKey, isolationTag] }
        if let languages, !languages.isEmpty {
            // A property-list array, as the arguments domain reads `-AppleLanguages (de)`.
            arguments += ["-AppleLanguages", "(" + languages.map { "\"\($0)\"" }.joined(separator: ", ") + ")"]
        }
        return arguments
    }

    var isWallpaperEditor: Bool {
        if case .wallpaperEditor = self { return true }
        return false
    }
}

/// A page of Open Wallpaper Engine's Settings the Wallpaper Editor's process shows: a message to
/// the running app (`AppProcessChannel`), or an argument that launches the app on it.
enum AppSettingsRequest: CaseIterable {
    /// Settings › Assets, where WE's assets the browsers offer are set up.
    case assets
    /// Settings › Plugins › Depth Map Generation, where its model is installed.
    case depthMaps

    var message: AppProcessChannel.Message {
        switch self {
        case .assets: .openAssetsSettings
        case .depthMaps: .openDepthMapSettings
        }
    }

    /// Opens the page once the app has launched: the editor asks for it when the app isn't running.
    var launchArgument: String {
        switch self {
        case .assets: "--open-assets-settings"
        case .depthMaps: "--open-depth-map-settings"
        }
    }

    /// The page an app launched with `arguments` opens, if any.
    static func requested(by arguments: [String]) -> AppSettingsRequest? {
        allCases.first { arguments.contains($0.launchArgument) }
    }
}
