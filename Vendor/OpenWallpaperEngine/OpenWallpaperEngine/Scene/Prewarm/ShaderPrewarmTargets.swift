import AppKit
import simd

/// The wallpapers a shader prewarm compiles for, read (never written) from the app's defaults:
/// the scene on each enabled display (`WallpaperViewModel`'s `ScreenWallpapers` and
/// `EnabledScreens`), then the most recent other scenes (`RecentWallpapers`), each drawn at the
/// size of a display it is or would be shown on.
struct ShaderPrewarmTargets {
    struct Display: Equatable {
        /// Pixels.
        var drawableSize: SIMD2<Float>
        /// Points.
        var pointSize: SIMD2<Float>
    }

    struct Target {
        var wallpaper: WEWallpaper
        var display: Display
    }

    static let screenWallpapersKey = "ScreenWallpapers"
    static let enabledScreensKey = "EnabledScreens"
    static let recentWallpapersKey = "RecentWallpapers"

    /// The connected displays by `WallpaperViewModel.screenId(for:)`, and the main one's id.
    @MainActor
    static func connectedDisplays() -> (displays: [String: Display], main: String?) {
        var displays: [String: Display] = [:]
        for screen in NSScreen.screens {
            let points = SIMD2(Float(screen.frame.width), Float(screen.frame.height))
            displays[WallpaperViewModel.screenId(for: screen)] = Display(
                drawableSize: points * Float(screen.backingScaleFactor), pointSize: points)
        }
        return (displays, NSScreen.main.map { WallpaperViewModel.screenId(for: $0) })
    }

    /// Scene wallpapers only: other types have no shaders of their own to compile.
    static func read(from defaults: UserDefaults, displays: [String: Display], mainDisplay: String?,
                     recentLimit: Int) -> [Target] {
        let fallback: Display = mainDisplay.flatMap { displays[$0] } ?? displays.values.first
            ?? Display(drawableSize: SIMD2(1920, 1080), pointSize: SIMD2(1920, 1080))
        var targets: [Target] = []
        var seen = Set<String>()
        func add(_ wallpaper: WEWallpaper, on display: Display) {
            guard wallpaper.project.type.caseInsensitiveCompare("scene") == .orderedSame,
                  seen.insert(wallpaper.wallpaperDirectory.standardizedFileURL.path).inserted else { return }
            targets.append(Target(wallpaper: wallpaper, display: display))
        }
        let enabled: Set<String>? = (defaults.array(forKey: enabledScreensKey) as? [String]).map(Set.init)
        for (screen, wallpaper) in decode([String: WEWallpaper].self, key: screenWallpapersKey, from: defaults)?
            .sorted(by: { $0.key < $1.key }) ?? []
        where enabled?.contains(screen) ?? true {
            guard let display = displays[screen] else { continue }
            add(wallpaper, on: display)
        }
        var recents = 0
        for wallpaper in decode([WEWallpaper].self, key: recentWallpapersKey, from: defaults) ?? [] where recents < recentLimit {
            let before: Int = targets.count
            add(wallpaper, on: fallback)
            if targets.count > before { recents += 1 }
        }
        return targets
    }

    private static func decode<Value: Decodable>(_ type: Value.Type, key: String, from defaults: UserDefaults) -> Value? {
        guard let data = defaults.data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            OWELog.error(.app, "Shader prewarm: can't read \(key): \(error)")
            return nil
        }
    }
}
