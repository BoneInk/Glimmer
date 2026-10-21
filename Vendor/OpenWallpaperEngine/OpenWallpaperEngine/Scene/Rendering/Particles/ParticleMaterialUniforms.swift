import Foundation
import simd

/// The particle-specific uniforms of WE's particle shaders for one system and frame: matrices,
/// the orthographic view, `g_Orientation*` and `g_RenderVar0/1`.
struct ParticleMaterialUniforms {
    /// Scene units (y up) to clip space. The translated vertex stage flips y (GL rows), so the
    /// top of the scene maps to GL's bottom.
    let modelViewProjection: simd_float4x4
    /// `g_ModelMatrix`, `g_ViewMatrix` and `g_ViewProjectionMatrix`. WE sets them for a particle
    /// draw from its matrix stacks as for any object (the per-draw setter 0x1400d83b0: id 9 the
    /// model top, 0xb view × projection): the model top is the system's model matrix
    /// (0x140236600…0x1402366c1), the camera the scene's or the temporary one of a `perspective`
    /// system. Its shaders light and fog a particle at `mul(position, g_ModelMatrix)` against the
    /// lights in the world (`genericparticle`, `genericropeparticle`). Through a 3D camera that is
    /// `Placement.model`; the 2D view draws the particles where they are, so identity.
    let modelMatrix: simd_float4x4
    let viewMatrix: simd_float4x4
    let viewProjection: simd_float4x4
    let renderVars: [Int: SIMD4<Float>]
    /// `g_EyePosition`: the frame camera's eye in the world (0x1400d9699 copies it from the
    /// renderer, which the particle draw never moves); trails and ropes take it into the system's
    /// space through `g_ModelMatrixInverse` (`common_particles.h`).
    let eyePosition: SIMD3<Float>
    /// `g_OrientationRight` and `g_OrientationUp`: the renderer's orientation (`ParticleOrientation`;
    /// by default the scene camera's axes, 2D scenes look down −z with y up) through the emitter's
    /// scale and rotation (`ParticleSystemRuntime.drawLinear`). WE expands a sprite along them in the
    /// system's own space and draws it through the system's model matrix; the particles here are in
    /// scene space, so the axes carry it.
    let orientationRight: SIMD3<Float>
    let orientationUp: SIMD3<Float>
    /// `g_OrientationForward`: the renderer's (`ParticleOrientation`); (0, 0, 1) facing the camera.
    let orientationForward: SIMD3<Float>

    /// `g_ViewUp`, `g_ViewRight` and `g_ViewForward` in the system's space (`frame(from:)`).
    let viewUp: SIMD3<Float>
    let viewRight: SIMD3<Float>
    let viewForward: SIMD3<Float>

    /// A system drawn through a 3D camera (docs/models-plan.md §2.12): a perspective scene's
    /// camera, or the temporary one of a `perspective` system in an orthographic scene. WE draws a
    /// system's vertices through its model matrix and the camera; here the particles are simulated
    /// in the scene's plane, placed by the object's 2D transform, so `model` carries them from
    /// there to where the object's 3D world matrix puts them (identity when the two agree).
    struct Placement: Equatable {
        var camera: SceneFrameCamera
        var model = matrix_identity_float4x4

        /// A camera direction in the particles' own space, normalised.
        func direction(_ vector: SIMD3<Float>) -> SIMD3<Float> {
            let linear = simd_float3x3(SIMD3(model.columns.0.x, model.columns.0.y, model.columns.0.z),
                                       SIMD3(model.columns.1.x, model.columns.1.y, model.columns.1.z),
                                       SIMD3(model.columns.2.x, model.columns.2.y, model.columns.2.z))
            guard abs(linear.determinant) > 1e-12 else { return vector }
            let local = linear.inverse * vector
            let length = simd_length(local)
            return length > 1e-12 ? local / length : vector
        }
    }

    /// The scene camera's axes, as WE binds them to particles.
    static let orientationRight = SIMD3<Float>(1, 0, 0)
    /// How far in front of the scene the eye sits. The view is orthographic, so view rays are
    /// parallel; a distant eye keeps the shaders' eye-to-particle directions (trail and rope
    /// facing) parallel to them too.
    static let eyeDistance: Float = 100_000

    /// `orthographicDepth`: the system is drawn in an orthographic scene whose pass has depth (it
    /// has models), through WE's orthographic projection (`SceneCamera.orthographic`, z −2000…2000),
    /// whose depth the models share; the x and y are the 2D view's.
    init(plan: ParticleMaterialPlan, system: ParticleSystemRuntime, sceneSize: SIMD2<Float>,
         texture0: BuiltinTextureInfo?, placement: Placement? = nil, orthographicDepth: Bool = false) {
        let size = simd_max(sceneSize, SIMD2(1, 1))
        let axes: (right: SIMD3<Float>, up: SIMD3<Float>, forward: SIMD3<Float>)
        if let placement {
            let camera = placement.camera
            modelMatrix = placement.model
            viewMatrix = camera.view
            viewProjection = PassMatrices.shaderViewProjection(camera.viewProjection)
            modelViewProjection = viewProjection * placement.model
            eyePosition = camera.eye
            let forward = placement.direction(camera.forward), up = placement.direction(camera.up)
            axes = system.configuration.orientation.axes(linear: system.drawLinear, cameraForward: forward, cameraUp: up)
            // The view-projection flips y as the 2D one does (see `viewUp2D`).
            viewUp = -up
            viewRight = placement.direction(simd_cross(camera.forward, camera.up))
            viewForward = forward
        } else {
            // Particles have depth (`Particle.z`), which an orthographic view doesn't show; without
            // a depth test the wide range keeps it from clipping them.
            modelViewProjection = orthographicDepth
                ? PassMatrices.shaderViewProjection(SceneCamera.orthographic(size: size))
                : PassMatrices.ortho(left: 0, right: size.x, bottom: size.y, top: 0,
                                     near: -Self.eyeDistance, far: Self.eyeDistance)
            modelMatrix = matrix_identity_float4x4
            viewMatrix = matrix_identity_float4x4
            viewProjection = modelViewProjection
            eyePosition = SIMD3(size.x / 2, size.y / 2, Self.eyeDistance)
            axes = system.configuration.orientation.axes(linear: system.drawLinear)
            viewUp = Self.viewUp2D
            viewRight = Self.orientationRight
            viewForward = SIMD3(0, 0, -1)
        }
        orientationRight = axes.right
        orientationUp = axes.up
        orientationForward = axes.forward
        var renderVars: [Int: SIMD4<Float>] = [:]
        switch plan.format {
        case .sprite: renderVars[0] = Self.trailRenderVar(plan.trailLengths, drawSizeScale: system.drawSizeScale)
        case .rope: renderVars[0] = Self.ropeRenderVar(system)
        }
        renderVars[1] = Self.spriteSheetRenderVar(plan.spriteSheet, texture: texture0)
        self.renderVars = renderVars
    }

    /// `g_RenderVar0` for a rope: `(points, 0, 1, points)`, which only the GPU step knows this
    /// frame and patches into the draw's block (`ParticleMaterialRenderer.Simulated.renderVar`);
    /// zero points here. A `ropetrail` takes WE's
    /// `(slots − 1, 0, offset, slots − 0.5)`, or `(slots − 1, 0, offset, (slots − 1) / uvscale)`
    /// when it scrolls (`TRAILSCROLLALPHA`), where the offset is how far the system's trail
    /// countdown has run, 0 at a sample and 1 at the next (0x14023695b…0x1402369d0). The shader
    /// maps the texture by it: the newest segment, from the particle to its last sample, takes that
    /// much of a segment's span, and every older one is pushed along by it, so the texture stays
    /// on the samples as they age instead of jumping a segment at each sample.
    static func ropeRenderVar(_ system: ParticleSystemRuntime) -> SIMD4<Float> {
        let configuration = system.configuration
        guard configuration.rendererName == "ropetrail" else { return SIMD4(0, 0, 1, 0) }
        let history = configuration.trailHistory
        let slots = Float(history.limit)
        let offset = 1 - min(max(system.trailTimer, 0) / history.interval, 1)
        let scale = configuration.ropeUV.scrolling ? (slots - 1) * configuration.ropeUV.inverseScale : slots - 0.5
        return SIMD4(slots - 1, 0, offset, scale)
    }

    /// A sprite trail's `g_RenderVar0` for records in the scene: WE's shader stretches a trail by
    /// `clamp(|v|·length, minlength, maxlength)` with `v` in the system's space (the vertex's
    /// `localVelocity`, `common_particles.h`), and its model matrix scales the result. The records
    /// hold the scene's velocity, the emitter's scale times WE's, and the size already scaled
    /// (`drawSizeScale`), so `length` is divided by that scale to stretch as WE does.
    static func trailRenderVar(_ lengths: SIMD4<Float>, drawSizeScale: Float) -> SIMD4<Float> {
        guard drawSizeScale > 1e-6 else { return lengths }
        return SIMD4(lengths.x / drawSizeScale, lengths.y, lengths.z, lengths.w)
    }

    /// `g_RenderVar1`: `(frame width, frame height, frame count, frame height / width)`, frame
    /// sizes in texture coordinates of the allocated texture; without a sheet only the texture's
    /// aspect ratio.
    static func spriteSheetRenderVar(_ sheet: SpriteSheet?, texture: BuiltinTextureInfo?) -> SIMD4<Float> {
        let allocated = simd_max(texture?.allocatedSize ?? SIMD2(1, 1), SIMD2(1, 1))
        let content = simd_max(texture?.contentSize ?? allocated, SIMD2(1, 1))
        guard let sheet, sheet.columns > 0, sheet.rows > 0, sheet.frames > 0 else {
            return SIMD4(0, 0, 0, content.y / content.x)
        }
        let columns = Float(sheet.columns), rows = Float(sheet.rows)
        let frame = SIMD2(content.x / columns, content.y / rows)
        return SIMD4(frame.x / allocated.x, frame.y / allocated.y, Float(sheet.frames), frame.y / frame.x)
    }

    /// `g_ViewUp`: the scene direction that points up in the clip space the shaders see.
    /// `modelViewProjection` puts the top of the scene at GL's bottom (the translated stage flips
    /// it back), so that is scene −y. Screen coordinates derived from the clip position
    /// (`v_ScreenCoord`) then run top-down like Metal's texture rows, and the refraction offsets
    /// that `ComputeScreenRefractionTangents` builds from this axis follow them.
    static let viewUp2D = SIMD3<Float>(0, -1, 0)

    /// The frame's built-ins with this system's view.
    func frame(from frame: BuiltinFrameContext) -> BuiltinFrameContext {
        var result = frame
        result.eyePosition = eyePosition
        result.viewUp = viewUp
        result.viewRight = viewRight
        result.viewForward = viewForward
        return result
    }

    /// The block members `patch` writes, looked up once per layout.
    struct Members {
        let right, up, forward, eye, renderVar0, renderVar1: UniformMember?

        init(_ layout: UniformLayout) {
            right = layout.members["g_OrientationRight"]
            up = layout.members["g_OrientationUp"]
            forward = layout.members["g_OrientationForward"]
            eye = layout.members["g_EyePosition"]
            renderVar0 = layout.members["g_RenderVar0"]
            renderVar1 = layout.members["g_RenderVar1"]
        }
    }

    /// Writes the values `UniformProgram` doesn't: WE's particle-only uniforms, and the ones that
    /// change with the system every frame.
    func patch(_ bytes: inout [UInt8], members: Members) {
        let values: [(UniformMember?, [Float])] = [
            (members.right, Self.flat(orientationRight)),
            (members.up, Self.flat(orientationUp)),
            (members.forward, Self.flat(orientationForward)),
            (members.eye, Self.flat(eyePosition)),
            (members.renderVar0, Self.flat(renderVars[0] ?? .zero)),
            (members.renderVar1, Self.flat(renderVars[1] ?? .zero)),
        ]
        for (member, components) in values {
            guard let member else { continue }
            UniformWriter.write(components, member: member, into: &bytes)
        }
    }

    private static func flat(_ v: SIMD3<Float>) -> [Float] { [v.x, v.y, v.z] }
    private static func flat(_ v: SIMD4<Float>) -> [Float] { [v.x, v.y, v.z, v.w] }
}
