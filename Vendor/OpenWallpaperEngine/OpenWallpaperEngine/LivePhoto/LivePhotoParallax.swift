import Foundation
import simd

/// Where the iPhone & iPad Export's pointer rests (Export Settings' Parallax Position): the
/// pointer its preview and its render both hold fixed (`SceneMetalRenderer.fixedPointer`), so the
/// camera and depth parallax and the cursor uniforms are the same in each. Normalised over the
/// scene with y up, as `g_PointerPosition` is; the centre unless the user moved it. Kept per
/// wallpaper.
enum LivePhotoParallax {
    static let centre = SIMD2<Double>(0.5, 0.5)

    /// Per wallpaper, `<prefix><identity>` (`WallpaperSettingsIdentity`): `[x, y]`.
    static let positionPrefix = "LivePhotoExportParallaxPosition."

    static func positionKey(_ identity: WallpaperSettingsIdentity) -> String { positionPrefix + identity.rawValue }

    /// `position` held inside the scene.
    static func clamped(_ position: SIMD2<Double>) -> SIMD2<Double> {
        guard position.x.isFinite, position.y.isFinite else { return centre }
        return simd_clamp(position, SIMD2(repeating: 0), SIMD2(repeating: 1))
    }

    /// The stored position of the wallpaper `identity` names, the centre when it has none.
    static func position(for identity: WallpaperSettingsIdentity, defaults: UserDefaults = .app) -> SIMD2<Double> {
        guard let stored = defaults.array(forKey: positionKey(identity)) as? [Double], stored.count == 2 else { return centre }
        return clamped(SIMD2(stored[0], stored[1]))
    }

    static func position(for wallpaper: WEWallpaper, defaults: UserDefaults = .app) -> SIMD2<Double> {
        position(for: WallpaperSettingsIdentity.resolve(wallpaper, defaults: defaults), defaults: defaults)
    }

    /// Stores the position of the wallpaper `identity` names; the centre removes it.
    static func setPosition(_ position: SIMD2<Double>, for identity: WallpaperSettingsIdentity,
                            defaults: UserDefaults = .app) {
        let position = clamped(position)
        if position == centre {
            defaults.removeObject(forKey: positionKey(identity))
        } else {
            defaults.set([position.x, position.y], forKey: positionKey(identity))
        }
    }

    /// Whether moving the pointer can change `content`'s picture: its camera parallax is on, or a
    /// layer has a depth parallax effect or a shader that reads the pointer or the parallax
    /// (`g_PointerPosition`, `g_ParallaxPosition`, as `SceneLayerAnalysis` finds them).
    static func followsPointer(_ content: SceneMetalContent) -> Bool {
        if content.camera.parallax { return true }
        return content.layers.contains { layer in
            layer.weEffects.contains { $0.file.lowercased().contains("depthparallax") }
                || !SceneLayerAnalysis.dependencies(of: layer).isDisjoint(with: [.cursor, .parallax])
        }
    }
}
