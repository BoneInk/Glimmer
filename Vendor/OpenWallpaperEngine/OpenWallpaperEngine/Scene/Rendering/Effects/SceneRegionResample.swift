import simd

/// How a scene-input layer (composition, fullscreen, `copybackground`) gets the scene under it as
/// its base image: the scene snapshot resampled through the layer's world-space quad, so each
/// texel of the result is the scene pixel it covers on screen, whatever the quad's rotation,
/// mirroring or shear. Parts of the quad outside the scene clamp to the scene's edge.
enum SceneRegionResample {
    /// The quad is exactly the scene (composition and fullscreen layers): use the snapshot as is.
    static func coversWholeScene(_ quad: SceneQuadGeometry, sceneSize: SIMD2<Float>) -> Bool {
        let mapping = quad.snapshotUV(sceneSize: sceneSize)
        let tolerance: Float = 1e-4
        return simd_length(mapping.origin) < tolerance && simd_length(mapping.axisX - SIMD2(1, 0)) < tolerance
            && simd_length(mapping.axisY - SIMD2(0, 1)) < tolerance
    }

    /// The region image's size: the quad at the scene target's density, but never more than the
    /// layer's own `size` (scene units) at it: WE's buffers for a composition layer are its size
    /// (`wallpaper64.exe` 0x1402092d7), so a layer scaled up draws its effects at that size and
    /// scales them with the quad, rather than at the scaled size. nil when it covers no pixel
    /// (zero, NaN or infinite extent).
    static func targetSize(_ quad: SceneQuadGeometry, layerSize: SIMD2<Float>? = nil, pixelsPerUnit: Float) -> SIMD2<Int>? {
        targetSize(extent: quad.extent, layerSize: layerSize, pixelsPerUnit: pixelsPerUnit)
    }

    /// `targetSize` for a quad `extent` scene units large (a quad drawn through a 3D camera: its
    /// size in object units, `SceneRegionProjection`).
    static func targetSize(extent: SIMD2<Float>, layerSize: SIMD2<Float>? = nil, pixelsPerUnit: Float) -> SIMD2<Int>? {
        var extent = extent
        if let layerSize, layerSize.x > 0, layerSize.y > 0 { extent = simd_min(extent, layerSize) }
        let pixels = (extent * pixelsPerUnit).rounded(.up)
        guard pixels.x.isFinite, pixels.y.isFinite, pixels.x >= 1, pixels.y >= 1 else { return nil }
        let limit = SceneRenderResolution.maximumTextureDimension
        return SIMD2(Int(min(pixels.x, limit)), Int(min(pixels.y, limit)))
    }

    /// `sceneVertex`/`sceneCopyFragment` uniform: a quad covering the whole region target whose
    /// corners read the snapshot at the layer's corners.
    static func uniform(_ quad: SceneQuadGeometry, sceneSize: SIMD2<Float>, targetSize: SIMD2<Int>) -> LayerUniform {
        let target = SIMD2<Float>(Float(targetSize.x), Float(targetSize.y))
        let mapping = quad.snapshotUV(sceneSize: sceneSize)
        return LayerUniform(position: target / 2, size: target, sceneSize: target, opacity: 1, particleShape: 0,
                            rotation: 0, color: SIMD4(repeating: 1), uvOrigin: mapping.origin, uvAxisX: mapping.axisX,
                            uvAxisY: mapping.axisY, effects: SIMD4(1, 1, 1, 0), blur: 0,
                            colorEffects: SIMD4(0, 1, 0, 0.7), transform: SIMD4(0, 0, 0, 1), transformScaleY: 1)
    }
}
