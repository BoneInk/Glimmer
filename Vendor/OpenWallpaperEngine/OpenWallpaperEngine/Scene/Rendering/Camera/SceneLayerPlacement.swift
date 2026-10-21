import simd

/// Where a layer's quad lands when it is drawn through a 3D camera (docs/models-plan.md §2.4): in
/// a perspective scene every image and text object ("2D layers in a perspective scene"), and in an
/// orthographic scene a `perspective` layer, through its temporary camera. WE draws the quad, the
/// layer's `size` in object units about its origin, through the object's world matrix (origin,
/// radians, scale, parents: M3's `SceneTransformHierarchy3D`) and the camera's view-projection:
/// `g_ModelViewProjectionMatrix` = VP × world. There is no other placement, which is why 3D scenes
/// scale their texts and images down.
struct SceneLayerPlacement: Equatable {
    /// The object's world matrix this frame (`g_ModelMatrix`).
    var world: simd_float4x4
    /// The quad in object units: `size`, and its centre's offset from the origin (`alignment`).
    var size: SIMD2<Float>
    var offset: SIMD2<Float> = .zero
    /// The camera the quad is drawn through.
    var camera: SceneFrameCamera

    var modelViewProjection: simd_float4x4 { camera.viewProjection * world }

    /// The world matrix moved to the quad's centre (`offset`): where a prelit layer lies.
    var centredWorld: simd_float4x4 {
        var matrix = world
        matrix.columns.3 += matrix.columns.0 * offset.x + matrix.columns.1 * offset.y
        return matrix
    }

    /// The view-projection the translated shaders get: y flipped, since their vertex stage flips
    /// it back (`PassMatrices.shaderViewProjection`), so what they write is WE's clip space.
    var shaderViewProjection: simd_float4x4 { PassMatrices.shaderViewProjection(camera.viewProjection) }

    /// A corner of the quad in object space: `uv` in texture space (u right, v down the image).
    func corner(_ uv: SIMD2<Float>) -> SIMD3<Float> {
        SIMD3((uv.x - 0.5) * size.x + offset.x, (0.5 - uv.y) * size.y + offset.y, 0)
    }

    /// The triangle-strip positions (`ImageMaterialRenderer.corners`), in object space.
    var quadPositions: [Float] {
        ImageMaterialRenderer.corners.flatMap { uv -> [Float] in
            let point = corner(uv)
            return [point.x, point.y, point.z]
        }
    }

    /// Where an object-space point lands in a target of `targetSize` pixels (y down), or nil
    /// behind the eye.
    func pixel(_ point: SIMD3<Float>, targetSize: SIMD2<Float>) -> SIMD2<Float>? {
        let clip = modelViewProjection * SIMD4(point, 1)
        guard clip.w > 1e-6 else { return nil }
        let ndc = SIMD2(clip.x, clip.y) / clip.w
        return SIMD2((ndc.x * 0.5 + 0.5) * targetSize.x, (0.5 - ndc.y * 0.5) * targetSize.y)
    }

    /// Target pixels per object unit at the quad's centre, along its larger axis: the density a
    /// text is rasterised at (`SceneTextRasterScale`). Nil when the quad is behind the eye.
    func pixelsPerUnit(targetSize: SIMD2<Float>) -> Float? {
        let centre = SIMD3(offset, 0)
        guard let middle = pixel(centre, targetSize: targetSize),
              let right = pixel(centre + SIMD3(0.5, 0, 0), targetSize: targetSize),
              let up = pixel(centre + SIMD3(0, 0.5, 0), targetSize: targetSize) else { return nil }
        return 2 * max(simd_length(right - middle), simd_length(up - middle))
    }

    /// What the native layer draw's `sceneVertex3D` takes.
    var native: LayerPlacement3D {
        LayerPlacement3D(modelViewProjection: modelViewProjection, size: size, offset: offset)
    }

    /// The temporary camera a `perspective` layer (or particle system) of an orthographic scene is
    /// drawn through (0x1401e5b60): vertical fov `fov` degrees (the scene's effective fov there,
    /// `perspectiveoverridefov` [I]), near 5, far max(15000, d + 1000), at distance
    /// d = (h/2) / tan(fov/2) above the scene's centre, so its z = 0 plane is exactly the
    /// orthographic framing and only depth (a tilt, `origin.z`) shows perspective. Its eye isn't
    /// the scene's: WE leaves `g_EyePosition` as it was, the caller keeps the frame's.
    static func perspectiveLayerCamera(sceneSize: SIMD2<Float>, fov: Float) -> SceneFrameCamera {
        let size = simd_max(sceneSize, SIMD2(1, 1))
        let clamped = SceneCamera.clampedFov(fov)
        let distance = size.y / 2 / tan(clamped * .pi / 360)
        let centre = SIMD3(size.x / 2, size.y / 2, 0)
        let eye = centre + SIMD3(0, 0, distance)
        let up = SIMD3<Float>(0, 1, 0)
        return SceneFrameCamera(view: SceneCamera.lookAt(eye: eye, center: centre, up: up),
                                projection: SceneCamera.perspective(fovDegrees: clamped, aspect: size.x / size.y,
                                                                    near: 5, far: max(15000, distance + 1000)),
                                eye: eye, forward: SIMD3(0, 0, -1), up: up, fieldOfView: clamped)
    }
}

/// `sceneVertex3D`'s placement (SceneShaders.metal): the quad's model-view-projection in WE's
/// clip space, its size and centre offset in object units.
struct LayerPlacement3D {
    var modelViewProjection: simd_float4x4
    var size: SIMD2<Float>
    var offset: SIMD2<Float>
}
