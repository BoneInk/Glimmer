import Foundation
import simd

/// Per-frame inputs to WE's built-in uniforms (plan §2). Computed once per rendered frame.
struct BuiltinFrameContext {
    /// The frame's number, counted by its renderer from 1: what a draw may cache for the rest of
    /// the frame is keyed on it. 0 is a context made outside a frame, which nothing caches.
    var serial: UInt64 = 0
    /// Seconds since the scene started, no wrap.
    ///
    /// `g_Time` is this value as a 32-bit float, like WE's ("time the program has been running in
    /// seconds"). WE never wraps it: its shaders scale it by arbitrary speeds (`g_Time * speed`,
    /// `sin(g_Time * f)`, scrolling offsets), so no wrap period is seamless for all of them and any
    /// wrap is a visible jump. Shaders that need precision after long runs reduce it themselves
    /// (`frac(g_Time * g_FlowSpeed)`, WE's fix for `shake`). Float resolution is ~8 ms after a day
    /// and ~60 ms after a week of one scene; the clock restarts whenever a scene loads.
    var time: Double = 0
    var frameTime: Double = 1.0 / 60.0
    /// `(h·60 + m) / 1440`; see `BuiltinFrameContext.daytime(at:calendar:)`.
    var daytime: Float = 0
    /// 0...1, y = 0 at the bottom. The caller maps it into the layer's UV space.
    var pointer: SIMD2<Float> = SIMD2(0.5, 0.5)
    var pointerLast: SIMD2<Float> = SIMD2(0.5, 0.5)
    /// `g_PointerState`, a `vec4` in WE's shaders. WE's shipped effects (cursorripple,
    /// fluidsimulation) read only `.z`, as the press strength of the primary button; build it
    /// with `BuiltinFrameContext.pointerState(primaryDown:)`.
    var pointerState: SIMD4<Float> = .zero
    /// `0.5 + (mouse − 0.5)·influence`, computed by the caller.
    var parallax: SIMD2<Float> = SIMD2(0.5, 0.5)
    var screenSize: SIMD2<Float> = SIMD2(1920, 1080)
    var eyePosition: SIMD3<Float> = .zero
    var viewUp: SIMD3<Float> = SIMD3(0, 1, 0)
    var viewRight: SIMD3<Float> = SIMD3(1, 0, 0)
    var viewForward: SIMD3<Float> = SIMD3(0, 0, -1)
    /// This frame's scene camera (`SceneFrameCamera`); `eyePosition` and `viewForward` are its.
    var camera: SceneFrameCamera = SceneFrameCamera()
    var audio: AudioSpectrumSnapshot = .silent
    /// `g_TextureReductionScale`: WE's texture reduction, 1 or 2 (`TextureReduction`).
    var textureReductionScale: Float = 1
    /// This frame's scene colours and lights (`SceneFrameLighting`): `g_LightAmbientColor`,
    /// `g_LightSkylightColor`, the `LightingV1` arrays and the legacy `g_Lights*`.
    var lighting = SceneFrameLighting()
    /// `g_HDRParams`: the device's HDR pair in SDR-white units, (SDR white, max luminance − SDR
    /// white), which `combine_video_hdr` reads (`SceneHDRChain.videoHDRParams`); (1, 0) on an SDR
    /// display, as WE's device pair.
    var hdrParams = SIMD2<Float>(1, 0)

    /// `g_PointerState` for the current button state. `.x` mirrors `.z` so a shader that
    /// declares the uniform as a scalar `float` still sees the press.
    static func pointerState(primaryDown: Bool) -> SIMD4<Float> {
        let down: Float = primaryDown ? 1 : 0
        return SIMD4(down, 0, down, 0)
    }

    static func daytime(at date: Date, calendar: Calendar = .current) -> Float {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return Float((parts.hour ?? 0) * 60 + (parts.minute ?? 0)) / 1440
    }
}

/// A sprite-sheet frame's rect in its texture's UV space, for `g_Texture<n>Rotation` and
/// `g_Texture<n>Translation` (docs/timeline-plan.md §2.7): the frame's axes and its origin.
struct BuiltinSpriteFrame: Equatable {
    /// `(axisX.x, axisX.y, axisY.x, axisY.y)`, as `BuiltinTextureInfo.spriteRotation`.
    var rotation: SIMD4<Float>
    var translation: SIMD2<Float>
}

/// Metadata of the texture bound to slot N of a pass.
struct BuiltinTextureInfo {
    /// Size of the GPU texture (power-of-two padded for WE `.tex`).
    var allocatedSize: SIMD2<Float>
    /// Size of the image inside it. Render targets use the allocated size.
    var contentSize: SIMD2<Float>
    /// Sprite-sheet frame, as LWE computes it: `(width1/W, width2/W, height2/H, height1/H)`.
    var spriteRotation: SIMD4<Float>? = nil
    /// Sprite-sheet frame origin `(x/W, y/H)`.
    var spriteTranslation: SIMD2<Float>? = nil
    var mipCount: Int = 1
}

/// Per-pass inputs to WE's built-in uniforms.
struct BuiltinPassContext {
    var targetSize: SIMD2<Float>
    var modelViewProjection: simd_float4x4 = matrix_identity_float4x4
    var modelMatrix: simd_float4x4 = matrix_identity_float4x4
    var viewMatrix: simd_float4x4 = matrix_identity_float4x4
    var viewProjection: simd_float4x4 = matrix_identity_float4x4
    /// `g_AltModelMatrix` and `g_AltViewProjectionMatrix`: the layer's own placement in the scene
    /// while a pass draws it elsewhere (WE's prelighting draw into the layer's effect buffer,
    /// docs/lighting-plan.md §2.3). nil: `modelMatrix` and `viewProjection`.
    var altModelMatrix: simd_float4x4? = nil
    var altViewProjection: simd_float4x4? = nil
    /// `EffectGraphRenderer.effectTextureProjection(quad:sceneSize:)` for a layer's effects.
    var effectTextureProjection: simd_float4x4 = matrix_identity_float4x4
    /// `g_LayerModelMatrix`: the layer's own object matrix (`layerModelMatrix(_:)`) while an effect
    /// pass draws into the layer's buffers, where `modelMatrix` is the buffer's quad. nil:
    /// `modelMatrix`.
    var layerModelMatrix: simd_float4x4? = nil
    var textures: [Int: BuiltinTextureInfo] = [:]
    var color: SIMD3<Float> = SIMD3(repeating: 1)
    var alpha: Float = 1
    var userAlpha: Float = 1
    var brightness: Float = 1
    /// `g_RenderVar0...4`; zeros unless the renderer (e.g. particles) provides them.
    var renderVars: [Int: SIMD4<Float>] = [:]

    /// WE's `g_LayerModelMatrix` for a layer whose object transform (its parents' included) is
    /// `world`: "a copy of the matrix applied to the layer object", which transforms between the
    /// layer's local space (scene units of its `size`, origin at its `origin`) and world space
    /// (docs.wallpaperengine.io, shader variables). Its axes carry the layer's scale, which
    /// Workshop effects read back (`length(g_LayerModelMatrix[0].xy)`).
    static func layerModelMatrix(_ world: SceneAffineTransform) -> simd_float4x4 {
        let x = world.linear.columns.0, y = world.linear.columns.1
        return simd_float4x4(columns: (SIMD4(x.x, x.y, 0, 0), SIMD4(y.x, y.y, 0, 0), SIMD4(0, 0, 1, 0),
                                       SIMD4(world.translation.x, world.translation.y, 0, 1)))
    }
}

/// Values of WE's built-in uniforms, as flat float arrays. Matrices are column-major (16 floats,
/// `g_NormalModelMatrix` 9); the uniform layout writer is responsible for std140 padding.
enum BuiltinUniforms {
    private static let fixedNames: Set<String> = [
        "g_Time", "g_Daytime", "g_DayTime", "g_Frametime", "g_PointerPosition", "g_PointerPositionLast",
        "g_PointerState", "g_ParallaxPosition", "g_TexelSize", "g_TexelSizeHalf", "g_Screen",
        "g_ModelViewProjectionMatrix", "g_ModelViewProjectionMatrixInverse",
        "g_EffectModelViewProjectionMatrix", "g_EffectModelViewProjectionMatrixInverse",
        "g_ModelMatrix", "g_ModelMatrixInverse", "g_EffectModelMatrix", "g_AltModelMatrix", "g_AltNormalModelMatrix",
        "g_ModelViewMatrix", "g_ModelViewMatrixInverse", "g_ViewProjectionMatrix",
        "g_ViewProjectionMatrixInverse", "g_AltViewProjectionMatrix", "g_ViewMatrix",
        "g_EffectTextureProjectionMatrix", "g_EffectTextureProjectionMatrixInverse", "g_NormalModelMatrix",
        "g_LayerModelMatrix", "g_Color4", "g_Color", "g_Alpha", "g_UserAlpha", "g_Brightness",
        "g_EyePosition", "g_ViewUp", "g_ViewRight",
        "g_ViewForward", "g_TextureReductionScale",
        "g_FogDistanceColor", "g_FogDistanceParams", "g_FogHeightColor", "g_FogHeightParams",
        "g_HDRParams",
    ]

    static func isBuiltin(_ name: String) -> Bool {
        fixedNames.contains(name) || SceneFrameLighting.uniformNames.contains(name) || textureUniform(name) != nil
            || audioUniform(name) != nil || renderVarIndex(name) != nil
    }

    /// A built-in uniform, resolved from its name once (`Key(_:)`), so a draw reads its value by
    /// case instead of matching the name again.
    enum Key: Hashable {
        case time, daytime, frametime, pointerPosition, pointerPositionLast, pointerState, parallaxPosition
        case texelSize, texelSizeHalf, screen
        case modelViewProjection, modelViewProjectionInverse, modelMatrix, altModelMatrix, modelMatrixInverse
        case modelViewMatrix, modelViewMatrixInverse, viewMatrix, viewProjection, altViewProjection
        case viewProjectionInverse, effectTextureProjection, effectTextureProjectionInverse
        case normalModelMatrix, altNormalModelMatrix, layerModelMatrix
        case color4, color, alpha, userAlpha, brightness
        case lightAmbientColor, lightSkylightColor, eyePosition, viewUp, viewRight, viewForward
        case textureReductionScale, fogDistanceColor, fogDistanceParams, fogHeightColor, fogHeightParams
        case hdrParams
        /// A `LightingV1` array (`SceneFrameLighting.uniformComponents`) and its components per element.
        case lighting(name: String, perElement: Int)
        case texture(slot: Int, suffix: String)
        case audio(bands: Int, right: Bool)
        case renderVar(Int)

        /// Whether the value follows the draw's placement or the camera (the pass's matrices, the
        /// frame's eye and view axes), which can move every frame while the targets stay.
        var followsCamera: Bool {
            switch self {
            case .modelViewProjection, .modelViewProjectionInverse, .modelMatrix, .altModelMatrix, .modelMatrixInverse,
                 .modelViewMatrix, .modelViewMatrixInverse, .viewMatrix, .viewProjection, .altViewProjection,
                 .viewProjectionInverse, .effectTextureProjection, .effectTextureProjectionInverse,
                 .normalModelMatrix, .altNormalModelMatrix, .layerModelMatrix, .eyePosition, .viewUp, .viewRight,
                 .viewForward:
                return true
            default:
                return false
            }
        }

        /// Nil when `name` is not a built-in.
        init?(_ name: String) {
            if let fixed = Self.fixed[name] {
                self = fixed
            } else if let perElement = SceneFrameLighting.uniformComponents[name] {
                self = .lighting(name: name, perElement: perElement)
            } else if let (slot, suffix) = BuiltinUniforms.textureUniform(name) {
                self = .texture(slot: slot, suffix: suffix)
            } else if let (bands, right) = BuiltinUniforms.audioUniform(name) {
                self = .audio(bands: bands, right: right)
            } else if let index = BuiltinUniforms.renderVarIndex(name) {
                self = .renderVar(index)
            } else {
                return nil
            }
        }

        private static let fixed: [String: Key] = [
            "g_Time": .time, "g_Daytime": .daytime, "g_DayTime": .daytime, "g_Frametime": .frametime,
            "g_PointerPosition": .pointerPosition, "g_PointerPositionLast": .pointerPositionLast,
            "g_PointerState": .pointerState, "g_ParallaxPosition": .parallaxPosition,
            "g_TexelSize": .texelSize, "g_TexelSizeHalf": .texelSizeHalf, "g_Screen": .screen,
            "g_ModelViewProjectionMatrix": .modelViewProjection, "g_EffectModelViewProjectionMatrix": .modelViewProjection,
            "g_ModelViewProjectionMatrixInverse": .modelViewProjectionInverse,
            "g_EffectModelViewProjectionMatrixInverse": .modelViewProjectionInverse,
            "g_ModelMatrix": .modelMatrix, "g_EffectModelMatrix": .modelMatrix, "g_AltModelMatrix": .altModelMatrix,
            "g_ModelMatrixInverse": .modelMatrixInverse, "g_ModelViewMatrix": .modelViewMatrix,
            "g_ModelViewMatrixInverse": .modelViewMatrixInverse, "g_ViewMatrix": .viewMatrix,
            "g_ViewProjectionMatrix": .viewProjection, "g_AltViewProjectionMatrix": .altViewProjection,
            "g_ViewProjectionMatrixInverse": .viewProjectionInverse,
            "g_EffectTextureProjectionMatrix": .effectTextureProjection,
            "g_EffectTextureProjectionMatrixInverse": .effectTextureProjectionInverse,
            "g_NormalModelMatrix": .normalModelMatrix, "g_AltNormalModelMatrix": .altNormalModelMatrix,
            "g_LayerModelMatrix": .layerModelMatrix,
            "g_Color4": .color4, "g_Color": .color, "g_Alpha": .alpha, "g_UserAlpha": .userAlpha,
            "g_Brightness": .brightness, "g_LightAmbientColor": .lightAmbientColor,
            "g_LightSkylightColor": .lightSkylightColor, "g_EyePosition": .eyePosition, "g_ViewUp": .viewUp,
            "g_ViewRight": .viewRight, "g_ViewForward": .viewForward, "g_TextureReductionScale": .textureReductionScale,
            "g_FogDistanceColor": .fogDistanceColor, "g_FogDistanceParams": .fogDistanceParams,
            "g_FogHeightColor": .fogHeightColor, "g_FogHeightParams": .fogHeightParams,
            "g_HDRParams": .hdrParams,
        ]
    }

    /// The value of built-in `name`, or nil when `name` is not a built-in. `arrayCount` limits
    /// (or zero-pads) array uniforms such as the audio spectra to the shader's declared length.
    static func value(named name: String, frame: BuiltinFrameContext, pass: BuiltinPassContext,
                      arrayCount: Int? = nil) -> [Float]? {
        Key(name).map { value($0, frame: frame, pass: pass, arrayCount: arrayCount) }
    }

    /// The value of a resolved built-in (`value(named:…)`).
    static func value(_ key: Key, frame: BuiltinFrameContext, pass: BuiltinPassContext, arrayCount: Int? = nil) -> [Float] {
        let size = pass.targetSize
        switch key {
        case .time: return [Float(frame.time)]
        case .daytime: return [frame.daytime]
        case .frametime: return [Float(frame.frameTime)]
        // WE's pointer is y-down, as the Windows cursor: its shaders flip it "to match texture
        // space Y" (cursor ripple, x-ray, fluid simulation), as its camera parallax does (§3 of
        // we-values-audit notes). Ours is y-up.
        case .pointerPosition: return [frame.pointer.x, 1 - frame.pointer.y]
        case .pointerPositionLast: return [frame.pointerLast.x, 1 - frame.pointerLast.y]
        case .pointerState: return flat(frame.pointerState)
        case .parallaxPosition: return flat(frame.parallax)
        case .texelSize: return flat(1 / size)
        case .texelSizeHalf: return flat(0.5 / size)
        case .screen:
            let screen = frame.screenSize
            return [screen.x, screen.y, screen.x / screen.y]
        case .modelViewProjection: return flat(pass.modelViewProjection)
        case .modelViewProjectionInverse: return flat(pass.modelViewProjection.inverse)
        case .modelMatrix: return flat(pass.modelMatrix)
        case .altModelMatrix: return flat(pass.altModelMatrix ?? pass.modelMatrix)
        case .modelMatrixInverse: return flat(pass.modelMatrix.inverse)
        case .modelViewMatrix: return flat(pass.viewMatrix * pass.modelMatrix)
        case .modelViewMatrixInverse: return flat((pass.viewMatrix * pass.modelMatrix).inverse)
        case .viewMatrix: return flat(pass.viewMatrix)
        case .viewProjection: return flat(pass.viewProjection)
        case .altViewProjection: return flat(pass.altViewProjection ?? pass.viewProjection)
        case .viewProjectionInverse: return flat(pass.viewProjection.inverse)
        case .effectTextureProjection: return flat(pass.effectTextureProjection)
        case .effectTextureProjectionInverse: return flat(pass.effectTextureProjection.inverse)
        case .normalModelMatrix: return normalMatrix(pass.modelMatrix)
        case .altNormalModelMatrix: return normalMatrix(pass.altModelMatrix ?? pass.modelMatrix)
        case .layerModelMatrix: return flat(pass.layerModelMatrix ?? pass.modelMatrix)
        case .color4: return [pass.color.x, pass.color.y, pass.color.z, pass.alpha]
        case .color: return flat(pass.color)
        case .alpha: return [pass.alpha]
        case .userAlpha: return [pass.userAlpha]
        case .brightness: return [pass.brightness]
        case .lightAmbientColor: return flat(frame.lighting.ambient)
        case .lightSkylightColor: return flat(frame.lighting.skylight)
        case .eyePosition: return flat(frame.eyePosition)
        case .viewUp: return flat(frame.viewUp)
        case .viewRight: return flat(frame.viewRight)
        case .viewForward: return flat(frame.viewForward)
        case .textureReductionScale: return [frame.textureReductionScale]
        case .hdrParams: return flat(frame.hdrParams)
        case .fogDistanceColor: return flat(frame.lighting.fog.distanceColor)
        case .fogDistanceParams: return flat(frame.lighting.fog.distanceParams)
        case .fogHeightColor: return flat(frame.lighting.fog.heightColor)
        case .fogHeightParams: return flat(frame.lighting.fog.heightParams)
        case .lighting(let name, let perElement):
            // Zero-padded or cut to the shader's array, whose length is the budget's too.
            return fitted(frame.lighting.arrays[name] ?? [], count: (arrayCount ?? 1) * perElement)
        case .texture(let slot, let suffix): return textureValue(suffix, info: pass.textures[slot])
        case .audio(let bands, let right):
            let values = frame.audio.values(bands: bands, right: right) ?? []
            guard let arrayCount else { return values }
            return fitted(values, count: arrayCount)
        case .renderVar(let index): return flat(pass.renderVars[index] ?? .zero)
        }
    }

    // MARK: - Private

    /// `values` zero-padded or cut to `count`.
    private static func fitted(_ values: [Float], count: Int) -> [Float] {
        if values.count == count { return values }
        if values.count > count { return Array(values.prefix(count)) }
        return values + [Float](repeating: 0, count: count - values.count)
    }

    /// WE's normal matrix (0x1400d8840, and 0x1400d8aab for the alt one): the model's upper 3×3
    /// with each axis normalised, not the inverse transpose. A zero axis stays zero.
    private static func normalMatrix(_ m: simd_float4x4) -> [Float] {
        func unit(_ axis: SIMD3<Float>) -> SIMD3<Float> {
            let length = simd_length(axis)
            return length > 0 ? axis / length : axis
        }
        let x = unit(m.columns.0.xyz), y = unit(m.columns.1.xyz), z = unit(m.columns.2.xyz)
        return [x.x, x.y, x.z, y.x, y.y, y.z, z.x, z.y, z.z]
    }

    private static let textureSuffixes = ["Resolution", "Rotation", "Translation", "MipMapInfo", "Texel"]

    /// `g_Texture{N}{Suffix}` → (N, Suffix).
    fileprivate static func textureUniform(_ name: String) -> (Int, String)? {
        guard name.hasPrefix("g_Texture") else { return nil }
        let rest = name.dropFirst("g_Texture".count)
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, let slot = Int(digits) else { return nil }
        let suffix = String(rest.dropFirst(digits.count))
        return textureSuffixes.contains(suffix) ? (slot, suffix) : nil
    }

    /// Unbound slots read as zeros, except the sprite frame, which defaults to the whole texture.
    private static func textureValue(_ suffix: String, info: BuiltinTextureInfo?) -> [Float] {
        switch suffix {
        case "Resolution":
            guard let info else { return [0, 0, 0, 0] }
            return [info.allocatedSize.x, info.allocatedSize.y, info.contentSize.x, info.contentSize.y]
        case "Rotation":
            // WE's spritesheet vertex code: uv = translation + u·rotation.xy + v·rotation.zw,
            // so (1, 0, 0, 1) with translation 0 samples the texture unchanged.
            return flat(info?.spriteRotation ?? SIMD4(1, 0, 0, 1))
        case "Translation": return flat(info?.spriteTranslation ?? .zero)
        case "MipMapInfo": return [Float(info?.mipCount ?? 1)]
        case "Texel":
            guard let info, info.allocatedSize.x > 0, info.allocatedSize.y > 0 else { return [0, 0] }
            return flat(1 / info.allocatedSize)
        default: return [0]
        }
    }

    /// `g_AudioSpectrum{16,32,64}{Left,Right}` → (bands, isRight).
    fileprivate static func audioUniform(_ name: String) -> (Int, Bool)? {
        let prefix = "g_AudioSpectrum"
        guard name.hasPrefix(prefix) else { return nil }
        let rest = name.dropFirst(prefix.count)
        for bands in [16, 32, 64] {
            if rest == "\(bands)Left" { return (bands, false) }
            if rest == "\(bands)Right" { return (bands, true) }
        }
        return nil
    }

    fileprivate static func renderVarIndex(_ name: String) -> Int? {
        guard name.hasPrefix("g_RenderVar"), let index = Int(name.dropFirst("g_RenderVar".count)),
              (0...4).contains(index) else { return nil }
        return index
    }

    private static func flat(_ v: SIMD2<Float>) -> [Float] { [v.x, v.y] }
    private static func flat(_ v: SIMD3<Float>) -> [Float] { [v.x, v.y, v.z] }
    private static func flat(_ v: SIMD4<Float>) -> [Float] { [v.x, v.y, v.z, v.w] }
    private static func flat(_ m: simd_float4x4) -> [Float] {
        let (a, b, c, d) = m.columns
        return [a.x, a.y, a.z, a.w, b.x, b.y, b.z, b.w, c.x, c.y, c.z, c.w, d.x, d.y, d.z, d.w]
    }
}

/// The matrices each pass position uses (LWE; plan §2 "Matrices by pass position").
///
/// Clip space: the translator runs SPIRV-Cross with `fixup_clipspace` and `flip_vert_y`, so a
/// translated vertex stage writes y negated and z as (z + w) / 2. Effect quads sit at z = 0,
/// which stays visible, so no remap is needed for 2D passes, and the matrices below carry the y
/// flip. 3D camera matrices (`SceneCamera`) are WE's, reversed-Z with z in 0...w; their depth is
/// stored through the same (z + w) / 2 (`SceneDepthStates`).
enum PassMatrices {
    /// OpenGL `glm::ortho(left, right, bottom, top, near, far)`.
    static func ortho(left: Float, right: Float, bottom: Float, top: Float,
                      near: Float = -1, far: Float = 1) -> simd_float4x4 {
        simd_float4x4(columns: (
            SIMD4(2 / (right - left), 0, 0, 0),
            SIMD4(0, 2 / (top - bottom), 0, 0),
            SIMD4(0, 0, -2 / (far - near), 0),
            SIMD4(-(right + left) / (right - left), -(top + bottom) / (top - bottom),
                  -(far + near) / (far - near), 1)
        ))
    }

    /// Base draw of the layer image into its buffer: `ortho(0, w, 0, h)`.
    static func base(width: Float, height: Float) -> simd_float4x4 {
        ortho(left: 0, right: width, bottom: 0, top: height)
    }

    /// Intermediate passes draw a −1...1 quad.
    static let intermediate = matrix_identity_float4x4

    /// Final pass: the layer quad in scene space. `model` includes parent transforms and parallax.
    static func final(viewProjection: simd_float4x4, model: simd_float4x4) -> simd_float4x4 {
        viewProjection * model
    }

    /// A camera's view-projection as the translated shaders take it (`SceneFrameCamera`, which is
    /// WE's): y negated, since their vertex stage negates it again (`--flip-vert-y`), so what they
    /// write is WE's clip position. The 2D passes' matrices above carry the same flip.
    static func shaderViewProjection(_ viewProjection: simd_float4x4) -> simd_float4x4 {
        flipY * viewProjection
    }

    static let flipY = simd_float4x4(diagonal: SIMD4(1, -1, 1, 1))
}

extension BuiltinPassContext {
    /// The matrices of a draw through a 3D camera (docs/models-plan.md §2.4): `g_ModelMatrix` is
    /// the object's world matrix, `g_ViewMatrix` the camera's view, `g_ViewProjectionMatrix` its
    /// view-projection and `g_ModelViewProjectionMatrix` their product, in the translated shaders'
    /// convention (`PassMatrices.shaderViewProjection`). `g_EyePosition` stays the frame's
    /// (`BuiltinFrameContext.camera`): a perspective layer's temporary camera doesn't move it.
    mutating func place(_ placement: SceneLayerPlacement) {
        modelMatrix = placement.world
        viewMatrix = placement.camera.view
        viewProjection = placement.shaderViewProjection
        modelViewProjection = viewProjection * modelMatrix
    }
}

private extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}
