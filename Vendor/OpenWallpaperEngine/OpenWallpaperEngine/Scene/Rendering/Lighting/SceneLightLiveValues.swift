import simd

/// A light's fields and out-of-plane transform in one frame. WE's packer reads the light's live
/// properties every frame (0x140190c80, 0x14025d1f0), so a script bound to `intensity` or
/// `origin`, or a timeline on `color`, changes what the shaders get the frame it runs: what a
/// script wrote wins, then the field's timeline, then the value the content was built with
/// (authored or user-bound). The 2D transform comes from the object's motion, as a layer's.
extension SceneLightObject {
    /// `script` is what scripts left in the light's object this frame, `animation` its
    /// transform and colour timelines, and `timeline(key)` the value a timeline gives any other
    /// field this frame (nil when none drives it).
    func live(script: SceneScriptObjectState?, animation: SceneObjectAnimation?,
              timeline: (String) -> SIMD4<Float>?) -> SceneLightObject {
        guard script != nil || animation != nil || hasTimelines else { return self }
        var live = self
        func scalar(_ field: SceneScriptObjectField, _ value: Float) -> Float {
            script?.scalar(field) ?? (hasTimelines ? timeline(field.rawValue)?.x : nil) ?? value
        }
        live.light.color = script?.vector3(.color) ?? animation?.color ?? light.color
        live.light.intensity = scalar(.intensity, light.intensity)
        live.light.radius = scalar(.radius, light.radius)
        live.light.exponent = scalar(.exponent, light.exponent)
        live.light.innerCone = scalar(.innercone, light.innerCone)
        live.light.outerCone = scalar(.outercone, light.outerCone)
        live.light.controlPoint = script?.vector3(.controlpoint)
            ?? (hasTimelines ? timeline(SceneScriptObjectField.controlpoint.rawValue).map { SIMD3($0.x, $0.y, $0.z) } : nil)
            ?? light.controlPoint
        let origin = script?.vector3(.origin) ?? animation?.origin
        let angles = script?.vector3(.angles) ?? animation?.angles
        let scale = script?.vector3(.scale) ?? animation?.scale
        live.depth = SceneLightDepth(originZ: origin?.z ?? depth.originZ,
                                     anglesXY: angles.map { SIMD2($0.x, $0.y) } ?? depth.anglesXY,
                                     scaleZ: scale?.z ?? depth.scaleZ)
        return live
    }
}
