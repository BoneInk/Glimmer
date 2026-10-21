import AppKit

/// What reading stored settings needs to carry an earlier Render Resolution over, handed to the
/// decoder in `userInfo[.settingsMigration]`, and whether it did. Without it the migration
/// assumes a 1× display.
final class GlobalSettingsMigration {
    /// The main display's backing scale when the settings are read (2 on Retina).
    let mainBackingScale: Double
    /// The settings read held the points-based Render Resolution ("display", "desktop") and were
    /// carried over (`GlobalSettings.migrateFromPoints`), or the removed MetalFX Upscaling
    /// (`GlobalSettings.migrateMetalFX`): save them, so it happens once.
    var migrated = false

    init(mainBackingScale: Double) {
        self.mainBackingScale = mainBackingScale
    }

    /// For the main display now: the one with the menu bar.
    @MainActor static func current() -> GlobalSettingsMigration {
        GlobalSettingsMigration(mainBackingScale: Double(NSScreen.screens.first?.backingScaleFactor ?? 1))
    }

    /// A decoder that carries `self` over.
    func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.userInfo[.settingsMigration] = self
        return decoder
    }
}

extension CodingUserInfoKey {
    /// `GlobalSettingsMigration` for `GlobalSettings.init(from:)`.
    static let settingsMigration = CodingUserInfoKey(rawValue: "app.openwallpaperengine.settingsMigration")!
}

extension GlobalSettings {
    /// Carries over the earlier points-based Render Resolution ("Display": one target pixel per
    /// point, scaled up), which now reads as Your Display, drawn natively (Upscaling is left as it
    /// was). On a display of `backingScale`
    /// above 1 web wallpapers keep drawing at standard resolution, as Display drew them. Logged.
    mutating func migrateFromPoints(backingScale: Double) {
        renderResolution = .yourDisplay
        guard backingScale > 1 else {
            OWELog.info(.settings, "Render Resolution: Display (points) is now Your Display; on a 1× display that is the same size")
            return
        }
        let web = webStandardResolution ? "web wallpapers were already at standard resolution"
            : "web wallpapers kept at standard resolution"
        webStandardResolution = true
        OWELog.info(.settings, "Render Resolution: Display (points) is now Your Display on a \(backingScale)× display; \(web)")
    }

    /// Carries over the removed MetalFX Upscaling, already read as `bilinear` (`GSUpscaling`): the
    /// scene keeps drawing at the same render scale, scaled up bilinearly. Logged; the caller saves
    /// the settings so it is logged once.
    mutating func migrateMetalFX() {
        upscaling = .bilinear
        OWELog.info(.settings, "Upscaling: MetalFX was removed; scenes keep drawing at \(Int((renderScale.factor * 100).rounded())) % and are scaled up bilinearly")
    }
}
