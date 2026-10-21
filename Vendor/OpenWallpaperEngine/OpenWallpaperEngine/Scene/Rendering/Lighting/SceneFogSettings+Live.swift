import simd

extension SceneFogSettings {
    /// This frame's fog: a value a script (or a timeline) set on `thisScene` over the authored one.
    /// WE's scene property table registers every `general.fog*` field with the fog's writer
    /// 0x140186440 as its change handler (0x14019a312…0x14019a980), which recomputes
    /// `g_FogDistance*`/`g_FogHeight*` (0x140186440…0x140186552) and the fog's render flags
    /// (0x14018655a…0x1401865ad) from them.
    ///
    /// `number` gives a scalar field's live value (booleans as 0 or 1) and `color` a colour's; nil
    /// keeps the authored one. The flags choose the materials' `FOG_DIST`/`FOG_HEIGHT` combos,
    /// which the app compiles with the content, so a script can move the fog's colours, ranges
    /// and densities but turning a fog on or off only takes effect for the uniforms (logged by
    /// the caller) [the combos would need the content rebuilt].
    func live(number: (SceneScriptSceneField) -> Float?, color: (SceneScriptSceneField) -> SIMD3<Float>?) -> SceneFogSettings {
        var fog = self
        if let value = number(.fogdistance) { fog.distance = value != 0 }
        if let value = number(.fogheight) { fog.height = value != 0 }
        fog.distanceColor = color(.fogdistancecolor) ?? distanceColor
        fog.heightColor = color(.fogheightcolor) ?? heightColor
        fog.distanceStart = number(.fogdistancestart) ?? distanceStart
        fog.distanceEnd = number(.fogdistanceend) ?? distanceEnd
        fog.distanceStartDensity = number(.fogdistancestartdensity) ?? distanceStartDensity
        fog.distanceEndDensity = number(.fogdistanceenddensity) ?? distanceEndDensity
        fog.heightStart = number(.fogheightstart) ?? heightStart
        fog.heightEnd = number(.fogheightend) ?? heightEnd
        fog.heightStartDensity = number(.fogheightstartdensity) ?? heightStartDensity
        fog.heightEndDensity = number(.fogheightenddensity) ?? heightEndDensity
        return fog
    }
}
