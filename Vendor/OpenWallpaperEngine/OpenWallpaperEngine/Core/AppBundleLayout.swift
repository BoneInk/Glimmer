import Foundation

/// Where Open Wallpaper Engine's two apps are: the app, and the Wallpaper Editor's own app inside
/// it, `<app>/Contents/Helpers/Wallpaper Editor.app` (target WallpaperEditor). Both are small
/// executables that run the OpenWallpaperEngine framework in the app's `Contents/Frameworks`; the
/// editor's app has its own bundle id, `<app id>.editor`, so macOS gives it its own Dock tile and
/// LaunchServices identity. It shares the app's defaults, folders and keychain
/// (`AppStorageLocation`) and reads the app's update key from it.
enum AppBundleLayout {
    /// The editor app's name: its bundle, executable and `CFBundleName`.
    static let editorName = "Wallpaper Editor"
    /// What the editor's bundle id adds to the app's.
    static let editorIdentifierSuffix = ".editor"

    /// The editor's app inside the app at `app`.
    static func editorURL(inApp app: URL) -> URL {
        app.appending(path: "Contents/Helpers/\(editorName).app", directoryHint: .isDirectory)
    }

    /// The MCP Server plugin's `owe-mcp` as the app ships it (target OWEMCPServer), which the
    /// plugin copies into place when installed (`MCPServerPlugin`).
    static func mcpServerURL(inApp app: URL) -> URL {
        app.appending(path: "Contents/Helpers/owe-mcp", directoryHint: .notDirectory)
    }

    /// The app a helper app sits in (`<app>/Contents/Helpers/<helper>.app`); nil when `helper`
    /// isn't inside one.
    static func appURL(containingHelper helper: URL) -> URL? {
        let helpers = helper.standardizedFileURL.deletingLastPathComponent()
        let contents = helpers.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard helpers.lastPathComponent == "Helpers", contents.lastPathComponent == "Contents",
              app.pathExtension == "app" else { return nil }
        return app
    }

    static func isEditor(bundleIdentifier: String?) -> Bool {
        bundleIdentifier?.hasSuffix(editorIdentifierSuffix) ?? false
    }

    /// The app's bundle id, from the app's or the editor's.
    static func appIdentifier(for bundleIdentifier: String) -> String {
        isEditor(bundleIdentifier: bundleIdentifier)
            ? String(bundleIdentifier.dropLast(editorIdentifierSuffix.count)) : bundleIdentifier
    }

    /// The editor's bundle id, from the app's or the editor's.
    static func editorIdentifier(for bundleIdentifier: String) -> String {
        appIdentifier(for: bundleIdentifier) + editorIdentifierSuffix
    }

    /// The OpenWallpaperEngine framework both apps run. The code's own resources are in it (the
    /// Metal library, SceneScript's JavaScript, the placeholder media, the legal documents); each
    /// app's bundle (`Bundle.main`) has what is per app: its Info.plist, icon, asset catalog and
    /// strings, which SwiftUI and `String(localized:)` look up there.
    static let framework = Bundle(for: FrameworkBundleToken.self)
    private final class FrameworkBundleToken {}

    /// Open Wallpaper Engine's own bundle: this process's, or, in the editor's app, the app it is
    /// inside. Its Info.plist (the update key, `AppUpdateConfiguration`) is read here.
    static let appBundle: Bundle = {
        guard isEditor(bundleIdentifier: Bundle.main.bundleIdentifier),
              let app = appURL(containingHelper: Bundle.main.bundleURL), let bundle = Bundle(url: app) else {
            return .main
        }
        return bundle
    }()

    /// The video shown for a missing wallpaper.
    static var wallpaperNotFoundURL: URL {
        // The framework always ships it (`Resources/WallpaperNotFound.mp4`).
        framework.url(forResource: "WallpaperNotFound", withExtension: "mp4")!
    }
}
