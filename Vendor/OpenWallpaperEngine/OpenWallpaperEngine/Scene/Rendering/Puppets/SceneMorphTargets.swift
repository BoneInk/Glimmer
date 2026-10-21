import Metal
import simd

/// WE's blend shapes (morph targets; docs/models-plan.md §1.5, §2.9): the "morph" texture the
/// vertex stage reads the targets' deltas from, the weights animation layers and scripts give the
/// targets, and the uniforms that pick at most 11 of them for a draw.
///
/// The texture is RGBA16 SNORM (WE's format 0x13 → DXGI 13, R16G16B16A16_SNORM, for both
/// "morph" and "morph_<n>"; 0x1400d2a4d) and square, because the shaders take a texel's row as
/// `index / Resolution.y` and its column as `index % Resolution.x`. The `MDMP` values go in as
/// the file holds them, normalised: the shaders scale them by `g_MorphWeights[0]`. Two layouts:
/// - **Models** (`generic4`, `shadowcaster`…; the mesh upload 0x1401d7760, texture "morph"): the
///   values of every target one after another, target `k`'s vertex `v` at value `3·(k·V + v)`
///   (positions only) or `6·(k·V + v)` (a position and a normal, mesh flag 0x400), four a texel. `V` is the mesh's vertex count. The shader finds a vertex by `gl_VertexID + offset`.
/// - **Puppets** (`genericimage2/3/4`; the puppet load 0x1401fbf44…0x1401fc0f3, texture
///   "morph_<n>"): one texel per morph vertex and target, (Δx, Δy, Δz, alpha), target `k`'s morph
///   vertex `j` at texel `1 + k·V + j` with `V` the `MDMP` vertex count; texel 0 is (0, 0, 0, 1)
///   (0x7fff, 0x1401fc044).
///   The shader finds it by `a_PositionVec4.w + offset`, so `w` counts morph vertices from 1.
enum SceneMorphTexture {
    /// A packed texture: `side × side` texels of four 16-bit signed normalised values each.
    struct Packed: Equatable {
        var side: Int
        var values: [UInt16]
    }

    /// WE's side for `texels` texels: `floor(sqrtf(n))`, one more when its square is short.
    static func side(texels: Int) -> Int {
        guard texels > 0 else { return 0 }
        var side = Int(Float(texels).squareRoot().rounded(.down))
        if side * side < texels { side += 1 }
        return side
    }

    /// A model mesh's texture (0x1401d78b5…0x1401d7a91), `vertexCount` the mesh's vertices. Its size
    /// counts a position for every target and vertex, again for normals (flag 0x400) and again for
    /// tangents (flag 0x800); WE fills it with the positions alone, or with a position and a normal
    /// per vertex under flag 0x400, and writes nothing at all under flag 0x800 (its copy loop skips
    /// every target). Positions a target lacks (a blob shorter than the mesh) stay 0, where WE reads
    /// past the blob. nil for a mesh without targets.
    static func model(_ morphs: MDLMorphTargets, meshFlags: UInt32, vertexCount: Int) -> Packed? {
        guard !morphs.targets.isEmpty, vertexCount > 0 else { return nil }
        let count = morphs.targets.count * vertexCount
        var elements = meshFlags & 0x400 != 0 ? 2 * count : count
        if meshFlags & 0x800 != 0 { elements += count }
        let valuesUsed = 3 * elements
        let texels = valuesUsed / 4 + (valuesUsed % 4 != 0 ? 1 : 0)
        let side = side(texels: texels)
        var values = [UInt16](repeating: 0, count: side * side * 4)
        guard meshFlags & 0x800 == 0 else { return Packed(side: side, values: values) }
        let hasNormals = meshFlags & 0x400 != 0
        let perVertex = hasNormals ? 6 : 3
        for (k, target) in morphs.targets.enumerated() {
            let base = k * vertexCount * perVertex
            for vertex in 0..<vertexCount {
                for axis in 0..<3 {
                    let at = 3 * vertex + axis
                    if at < target.positions.count {
                        values[base + perVertex * vertex + axis] = MDLMorphTargets.snormBits(target.positions[at])
                    }
                    if hasNormals, let normals = target.normals, at < normals.count {
                        values[base + perVertex * vertex + 3 + axis] = MDLMorphTargets.snormBits(normals[at])
                    }
                }
            }
        }
        return Packed(side: side, values: values)
    }

    /// A puppet's texture from its first mesh's targets (the only mesh WE reads). Only a mesh with
    /// flag 0x1000 (a value per morph vertex: the alpha) is filled; otherwise every delta is 0, as
    /// WE's loop leaves it.
    static func puppet(_ morphs: MDLMorphTargets, meshFlags: UInt32) -> Packed {
        let vertices = Int(morphs.vertexCount ?? 0)
        let texels = morphs.targets.count * vertices + 1
        let side = side(texels: texels)
        var values = [UInt16](repeating: 0, count: side * side * 4)
        values[3] = 0x7fff
        guard meshFlags & 0x1000 != 0 else { return Packed(side: side, values: values) }
        for (k, target) in morphs.targets.enumerated() {
            let alpha = target.extra.map { [UInt8]($0) } ?? []
            for vertex in 0..<vertices {
                let texel = 4 * (1 + k * vertices + vertex)
                for axis in 0..<3 where 3 * vertex + axis < target.positions.count {
                    values[texel + axis] = MDLMorphTargets.snormBits(target.positions[3 * vertex + axis])
                }
                if 2 * vertex + 1 < alpha.count {
                    values[texel + 3] = UInt16(alpha[2 * vertex]) | UInt16(alpha[2 * vertex + 1]) << 8
                }
            }
        }
        return Packed(side: side, values: values)
    }

    /// The texture, sampled at texel centres by the vertex stage (nearest or linear read the same).
    static func makeTexture(_ packed: Packed, device: MTLDevice, label: String) -> MTLTexture? {
        guard packed.side > 0 else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Snorm, width: packed.side,
                                                                  height: packed.side, mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.label = label
        packed.values.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, packed.side, packed.side), mipmapLevel: 0,
                            withBytes: raw.baseAddress!, bytesPerRow: packed.side * 8)
        }
        return texture
    }
}

/// One mesh's blend-shape weights as WE keeps them: a weight per target and a 64-bit mask of the
/// targets that apply (models: the animation state's per-mesh records, anim+0x60; puppets:
/// puppet+0x398 and +0x3a0). Every evaluation starts them over at 0 (0x14021c5b0, 0x1401fecba);
/// the animation layers' morph tracks and scripts set them.
struct SceneMorphWeights: Equatable {
    /// FLT_EPSILON: a weight whose magnitude is below it turns its target off.
    static let epsilon: Float = 1.1920929e-07
    /// Targets a draw applies at most (the uniforms have 1 + 11 entries).
    static let maximumActive = 11

    var mask: UInt64 = 0
    var weights: [Float]

    init(count: Int) { weights = Array(repeating: 0, count: max(count, 0)) }

    mutating func reset() {
        mask = 0
        for index in weights.indices { weights[index] = 0 }
    }

    /// `bt`/`bts` on a 64-bit mask: the bit of `index mod 64`.
    func isActive(_ index: Int) -> Bool { mask & (UInt64(1) << UInt64(index & 63)) != 0 }

    private mutating func setActive(_ index: Int, _ on: Bool) {
        let bit = UInt64(1) << UInt64(index & 63)
        mask = on ? mask | bit : mask & ~bit
    }

    /// A morph track's value `value` for target `index` laid over the weights by a layer of
    /// weight `layerWeight` (models 0x14021c830…0x14021cbd2, puppets 0x1401ff110…0x1401ffcb1):
    /// - weight 1, not additive: the target takes `value`; a value below epsilon turns the target
    ///   off and leaves its weight;
    /// - any other weight, not additive: the weight moves towards `value` by the layer's weight,
    ///   clamped to 0…1 on models (puppets don't clamp); a value at or above epsilon turns it on;
    /// - additive: a value below epsilon does nothing; otherwise `a = value · weight` turns the
    ///   target on and the weight becomes `x + a` clamped between `x` and `a`.
    ///
    /// A value or layer weight that isn't finite (a broken clip, a script's NaN blend) is dropped,
    /// as `setFromScript` drops one, where WE would store it and draw the mesh's vertices at NaN.
    mutating func apply(track value: Float, to index: Int, layerWeight: Float, additive: Bool, clampsBlend: Bool) {
        guard index >= 0, index < weights.count, value.isFinite, layerWeight.isFinite else { return }
        let significant = !(abs(value - 0) < Self.epsilon)
        if !additive, layerWeight == 1 {
            setActive(index, significant)
            if significant { weights[index] = value }
        } else if !additive {
            if significant { setActive(index, true) }
            let mixed = (1 - layerWeight) * weights[index] + layerWeight * value
            weights[index] = clampsBlend ? (1 > mixed ? (0 > mixed ? 0 : mixed) : 1) : mixed
        } else if significant {
            setActive(index, true)
            let x = weights[index], a = value * layerWeight
            let high = x > a ? x : a, low = a > x ? x : a, sum = x + a
            let upper = high > sum ? sum : high
            weights[index] = low > upper ? low : upper
        }
    }

    /// `setBlendShapeWeight` (0x1402105c0): the weight, and the target on unless it is below
    /// epsilon. WE builds the bit as a 32-bit `1 << index` sign-extended to 64 bits, so index 31
    /// sets bits 31…63 and higher indices wrap; reproduced.
    /// A weight that isn't finite is dropped (the script API drops it too; WE would store it).
    mutating func setFromScript(_ index: Int, _ value: Float) {
        guard index >= 0, index < weights.count, value.isFinite else { return }
        weights[index] = value
        let bit = UInt64(bitPattern: Int64(Int32(truncatingIfNeeded: UInt32(1) << UInt32(index & 31))))
        mask = abs(value - 0) < Self.epsilon ? mask & ~bit : mask | bit
    }

    /// The targets a draw applies (0x140222b20…0x140222e6a, 0x14020d0a0…0x14020d268): the first 11
    /// whose bit is set, in index order, then sorted by weight, largest first, keeping index order
    /// among equal weights (an insertion sort).
    var activeTargets: [(index: Int, weight: Float)] {
        var active: [(index: Int, weight: Float)] = []
        for index in weights.indices where isActive(index) {
            active.append((index, weights[index]))
            if active.count == Self.maximumActive { break }
        }
        for next in active.indices.dropFirst() {
            let entry = active[next]
            var at = next
            while at > 0, entry.weight > active[at - 1].weight {
                active[at] = active[at - 1]
                at -= 1
            }
            active[at] = entry
        }
        return active
    }
}

/// A draw's morph uniforms (0x1400d9fa3…0x1400da0a3): `g_MorphOffsets[12]` (the count, then each
/// active target's index × the offset stride), `g_MorphWeights[12]` (the mesh's `MDMP` weight, then
/// each active target's weight), and for `MORPHING_MODIFIERS` puppets `g_MorphBoneTransform[11]` and
/// `g_MorphBoneRules[11]`.
struct SceneMorphUniforms: Equatable {
    var offsets: [UInt32] = Array(repeating: 0, count: 12)
    var weights: [Float] = Array(repeating: 0, count: 12)
    /// `mat4x3` components per target (as `ScenePuppetPose.boneComponents`), 11 of them.
    var boneTransforms: [Float]?
    /// (mode, start, end) per target, 11 of them.
    var boneRules: [Float]?

    /// No target applies.
    static let none = SceneMorphUniforms()

    /// The uniforms for `weights`: offsets are `index × stride` in 32 bits, as WE's `imul`.
    init(weights morphs: SceneMorphWeights, baseWeight: Float, stride: Int) {
        let active = morphs.activeTargets
        offsets[0] = UInt32(active.count)
        weights[0] = baseWeight
        for (k, target) in active.enumerated() {
            offsets[1 + k] = UInt32(truncatingIfNeeded: target.index &* stride)
            weights[1 + k] = target.weight
        }
    }

    init() {}

    /// A puppet's modifiers (0x14020d279…0x14020d466, 0x14020d520…0x14020d5a8): per active target,
    /// the inverse of its bone's model-space matrix and (mode bit 0x2 as 0 or 1, start distance,
    /// end distance); the unused entries the identity and (0, −1, 0).
    mutating func setModifiers(_ modifiers: [MDLMorphTargets.Target.Modifier?], active: [Int],
                               boneMatrices: [simd_float4x4]) {
        let identity: [Float] = [1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0]
        var transforms: [Float] = []
        var rules: [Float] = []
        for k in 0..<SceneMorphWeights.maximumActive {
            let modifier = k < active.count && active[k] < modifiers.count ? modifiers[active[k]] : nil
            guard let modifier else {
                transforms += identity
                rules += [0, -1, 0]
                continue
            }
            let bone = Int(modifier.bone)
            let inverse = bone < boneMatrices.count ? boneMatrices[bone].inverse : matrix_identity_float4x4
            transforms += [inverse.columns.0, inverse.columns.1, inverse.columns.2, inverse.columns.3]
                .flatMap { (column: SIMD4<Float>) -> [Float] in [column.x, column.y, column.z] }
            rules += [modifier.mode & 0x2 != 0 ? 1 : 0, modifier.startDistance, modifier.endDistance]
        }
        boneTransforms = transforms
        boneRules = rules
    }

    /// Writes the members the layout has: the offsets as raw 32-bit integers, the rest as floats.
    func write(into bytes: inout [UInt8], layout: UniformLayout) {
        if let member = layout.members["g_MorphOffsets"] {
            for (index, value) in offsets.prefix(member.count).enumerated() {
                let at = member.offset + index * max(member.arrayStride, 4)
                guard at >= 0, at + 4 <= bytes.count else { break }
                withUnsafeBytes(of: value.littleEndian) { raw in
                    for (byte, element) in raw.enumerated() { bytes[at + byte] = element }
                }
            }
        }
        if let member = layout.members["g_MorphWeights"] {
            UniformWriter.write(weights, member: member, into: &bytes)
        }
        if let boneTransforms, let member = layout.members["g_MorphBoneTransform"] {
            UniformWriter.write(boneTransforms, member: member, into: &bytes)
        }
        if let boneRules, let member = layout.members["g_MorphBoneRules"] {
            UniformWriter.write(boneRules, member: member, into: &bytes)
        }
    }
}
