import Foundation

/// `_alias_lightCookie`: the scene's one light cookie, which lit materials read under
/// `LIGHTS_COOKIE` (`generic4`'s `g_Texture7`). The light packer (`wallpaper64.exe` 0x140192ee5…
/// 0x1401935d8) sets it each frame to the cookie texture (+0x330) of the **last** spot it packs
/// with `usecookie`, in its sort order and within the spot budget (`SceneLightPacker.cookieLight`),
/// and leaves it empty when it packs none.
struct SceneLightCookie: Equatable {
    static let name = "_alias_lightCookie"

    /// The texture's cache key and source (`SceneModelDraw.assetTexture`).
    let key: String
    let source: SceneMetalTextureSource

    static func == (lhs: SceneLightCookie, rhs: SceneLightCookie) -> Bool { lhs.key == rhs.key }

    /// The cookie texture of each `usecookie` light, by light object id: its `cookie`, else WE's
    /// default when that doesn't load (0x14025d19f…0x14025d1cd), with the volumetrics' key
    /// (`SceneVolumetricsPlan.cookie`) so both read one texture. A light whose cookie and the
    /// default are both missing has none (logged).
    static func load(_ lights: [SceneLightObject],
                     loadTexture: (_ name: String, _ materialPath: String) -> SceneMetalTextureSource?) -> [String: SceneLightCookie] {
        var cookies: [String: SceneLightCookie] = [:]
        for object in lights {
            guard let name = object.light.cookie else { continue }
            let material = SceneVolumetricsPlan.frontMaterial
            var found: SceneLightCookie?
            for candidate in [name, SceneLightDefaults.cookie] {
                guard let source = loadTexture(candidate, material) else { continue }
                found = SceneLightCookie(key: "\(material)|\(candidate)", source: source)
                break
            }
            guard let found else {
                OWELog.error(.scene, "Light \(object.id): its cookie \(name) and WE's default \(SceneLightDefaults.cookie) are missing")
                continue
            }
            cookies[object.id] = found
        }
        return cookies
    }
}
