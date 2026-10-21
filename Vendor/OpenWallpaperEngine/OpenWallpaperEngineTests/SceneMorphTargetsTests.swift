import XCTest
import Metal
import AppKit
import simd
@testable import OpenWallpaperEngine

/// Morph targets (docs/models-plan.md §1.5, §2.9, §4.3 M7) on a synthetic `.mdl` written with the
/// `MDMP` layout of WE's reader and writer (no library file has the section): the texture packed
/// as the shaders' index maths read it, WE's 11-target selection, weights animated by a clip's
/// morph tracks, and WE's own vertex stages (`generic4`, `genericimage4`) moving vertices by the
/// weighted deltas on the GPU.
final class SceneMorphTargetsTests: XCTestCase {
    // MARK: - A synthetic .mdl

    /// Little-endian bytes in the `.mdl`'s primitives (docs/models-plan.md §1.1).
    struct Writer {
        var bytes: [UInt8] = []

        mutating func u8(_ v: UInt8) { bytes.append(v) }
        mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { bytes += $0 } }
        mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { bytes += $0 } }
        mutating func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
        mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { bytes += $0 } }
        mutating func f32(_ v: Float) { u32(v.bitPattern) }
        mutating func cstr(_ s: String) { bytes += Array(s.utf8) + [0] }
        mutating func blob(_ data: [UInt8]) { u32(UInt32(data.count)); bytes += data }
        mutating func floats(_ values: [Float]) { for value in values { f32(value) } }

        /// A section: its tag, the absolute offset of its end, its body.
        mutating func section(_ tag: String, _ body: (inout Writer) -> Void) {
            cstr(tag)
            var inner = Writer()
            body(&inner)
            u32(UInt32(bytes.count + 4 + inner.bytes.count))
            bytes += inner.bytes
        }

        /// 16-bit signed normalised values, as `MDMP` stores its deltas.
        static func snorms(_ values: [Float]) -> [UInt8] {
            values.flatMap { value -> [UInt8] in
                let bits = MDLMorphTargets.snormBits(value)
                return [UInt8(bits & 0xff), UInt8(bits >> 8)]
            }
        }
    }

    struct Target {
        var name: String
        var positions: [Float]
        var normals: [Float]? = nil
        var alpha: [Float]? = nil
        var modifier: MDLMorphTargets.Target.Modifier? = nil
    }

    struct Clip {
        var name: String
        var frames: UInt32
        var fps: Float
        /// (morph index, one sample per frame 0…frames).
        var tracks: [(UInt16, [Float])]
    }

    /// An `MDLV0013` model: one mesh of `format` with `flags`, a skeleton of `bones` (each one
    /// unit right of its parent, the first at `rootOffset`), clips (`MDLA0004` with morph tracks
    /// on the mesh) and an `MDMP0001` section of `targets` over `morphVertices` vertices.
    static func model(format: MDLVertexFormat, vertexData: [Float], indices: [UInt16], flags: UInt32,
                      targets: [Target], morphVertices: Int, baseWeight: Float = 1, bones: Int = 1,
                      rootOffset: SIMD3<Float> = .zero, clips: [Clip] = []) throws -> MDLModel {
        var w = Writer()
        w.cstr("MDLV0013")
        w.u32(format.rawValue)
        w.u32(1)
        w.u32(1)
        w.cstr("materials/morph.json")
        w.u32(flags)
        w.blob(vertexData.flatMap { value -> [UInt8] in withUnsafeBytes(of: value.bitPattern.littleEndian) { Array($0) } })
        w.blob(indices.flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] })
        w.section("MDLS0001") { s in
            s.u32(UInt32(bones))
            for bone in 0..<bones {
                s.cstr("bone\(bone)")
                s.u32(1)
                s.u32(bone == 0 ? 0xFFFF_FFFF : UInt32(bone - 1))
                s.u32(64)
                let offset = bone == 0 ? rootOffset : SIMD3<Float>(1, 0, 0)
                s.floats([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, offset.x, offset.y, offset.z, 1])
                s.cstr("")
            }
        }
        if !clips.isEmpty {
            w.section("MDLA0004") { s in
                s.i32(Int32(clips.count))
                for (index, clip) in clips.enumerated() {
                    s.u64(UInt64(100 + index))
                    s.cstr(clip.name)
                    s.cstr("loop")
                    s.f32(clip.fps)
                    s.u32(clip.frames)
                    s.u32(0)
                    s.i32(Int32(bones))
                    for _ in 0..<bones {
                        // Every bone track disabled: the bind pose.
                        s.u32(1)
                        s.blob(Array(repeating: 0, count: 36 * Int(clip.frames + 1)))
                    }
                    s.u32(0) // scalar tracks A (MDLA 3)
                    s.u8(0) // no scalar tracks B
                    s.u8(1) // mesh tracks (MDLA 4)
                    s.u32(1)
                    s.f32(1)
                    s.u16(UInt16(clip.tracks.count))
                    for (morph, samples) in clip.tracks {
                        s.u16(morph)
                        s.blob(samples.flatMap { value -> [UInt8] in withUnsafeBytes(of: value.bitPattern.littleEndian) { Array($0) } })
                    }
                    s.i32(0) // events
                }
            }
        }
        w.section("MDMP0001") { s in
            s.u16(UInt16(targets.count))
            guard !targets.isEmpty else { return }
            s.f32(baseWeight)
            s.u32(UInt32(morphVertices))
            for (index, target) in targets.enumerated() {
                s.u64(UInt64(500 + index))
                s.cstr(target.name)
                s.blob(Writer.snorms(target.positions))
                if flags & 0x400 != 0 { s.blob(Writer.snorms(target.normals ?? Array(repeating: 0, count: 3 * morphVertices))) }
                if flags & 0x800 != 0 { s.blob(Array(repeating: 0, count: 6 * morphVertices)) }
                if flags & 0x1000 != 0 { s.blob(Writer.snorms(target.alpha ?? Array(repeating: 1, count: morphVertices))) }
                if flags & 0x2000 != 0 {
                    let modifier = target.modifier ?? .init(bone: 0, mode: 0, startDistance: 0, endDistance: 0)
                    s.u32(modifier.bone)
                    s.u32(modifier.mode)
                    s.f32(modifier.startDistance)
                    s.f32(modifier.endDistance)
                }
            }
        }
        w.cstr("")
        return try MDLModel(data: Data(w.bytes))
    }

    /// A strip of `count` vertices (position, normal, uv: 0xb) at x = 0, 1, 2… and its triangles.
    static func strip(count: Int) -> (format: MDLVertexFormat, vertices: [Float], indices: [UInt16]) {
        var vertices: [Float] = []
        for i in 0..<count {
            let x: Float = Float(i)
            let y: Float = Float(i % 2)
            vertices.append(contentsOf: [x, y, 0, 0, 0, 1, 0, 0] as [Float])
        }
        var indices: [UInt16] = []
        for i in 0..<(count - 2) {
            let first: UInt16 = UInt16(i)
            indices.append(first)
            indices.append(first + 1)
            indices.append(first + 2)
        }
        return (MDLVertexFormat(rawValue: 0xb), vertices, indices)
    }

    /// `x` on the 16-bit signed normalised grid, which the `MDMP` values and the texture hold exactly.
    static func grid(_ x: Float) -> Float { MDLMorphTargets.float(snormBits: MDLMorphTargets.snormBits(x)) }

    /// Target `t`'s delta for vertex `v` (normalised, within ±1): distinct, exact on the grid.
    static func delta(_ t: Int, _ v: Int) -> SIMD3<Float> {
        let x: Float = grid(Float(t + 1) * 0.0625)
        let y: Float = grid(Float(v) * 0.0625 - 0.5)
        let z: Float = grid(Float(t * 7 + v) / 128)
        return SIMD3<Float>(x, y, z)
    }

    /// Target `t`'s normal delta for vertex `v`.
    static func normalDelta(_ t: Int, _ v: Int) -> SIMD3<Float> {
        SIMD3<Float>(grid(Float(v) / 8), grid(-Float(t) / 4), grid(0.5))
    }

    static func targets(_ count: Int, vertices: Int, normals: Bool = false) -> [Target] {
        (0..<count).map { t in
            Target(name: "shape\(t)", positions: (0..<vertices).flatMap { v -> [Float] in
                let d = delta(t, v)
                return [d.x, d.y, d.z]
            }, normals: normals ? (0..<vertices).flatMap { v -> [Float] in
                let n = normalDelta(t, v)
                return [n.x, n.y, n.z]
            } : nil)
        }
    }

    // MARK: - The section

    func testTheSyntheticSectionReadsBack() throws {
        let strip = Self.strip(count: 5)
        let model = try Self.model(format: strip.format, vertexData: strip.vertices, indices: strip.indices, flags: 0x1400,
                                   targets: Self.targets(3, vertices: 5, normals: true), morphVertices: 5, baseWeight: 0.75)
        let morphs = try XCTUnwrap(model.morphTargets?.first)
        XCTAssertEqual(morphs.weight, 0.75)
        XCTAssertEqual(morphs.vertexCount, 5)
        XCTAssertEqual(morphs.targets.map(\.name), ["shape0", "shape1", "shape2"])
        XCTAssertEqual(morphs.targets.map(\.id), [500, 501, 502])
        let d = Self.delta(2, 4)
        XCTAssertEqual(Array(morphs.targets[2].positions[12..<15]), [d.x, d.y, d.z])
        XCTAssertEqual(morphs.targets[1].normals?.count, 15)
        XCTAssertEqual(morphs.targets[0].extra?.count, 10)
    }

    func testSnormBitsRoundTrip() {
        for bits in stride(from: 0, through: 0xffff, by: 1) where bits != 0x8000 {
            let value = MDLMorphTargets.float(snormBits: UInt16(bits))
            XCTAssertEqual(MDLMorphTargets.snormBits(value), UInt16(bits), "snorm 0x\(String(bits, radix: 16))")
        }
        XCTAssertEqual(MDLMorphTargets.float(snormBits: 0x8000), -1, "−32768 reads as −1")
        XCTAssertEqual(MDLMorphTargets.snormBits(2), 0x7fff)
        XCTAssertEqual(MDLMorphTargets.snormBits(-2), 0x8001)
    }

    // MARK: - Packing against the shaders' index maths

    /// A texel of a packed texture: the shaders read `(index % Resolution.x, index / Resolution.y)`.
    private static func texel(_ packed: SceneMorphTexture.Packed, _ index: Int) -> SIMD4<Float> {
        let x = index % packed.side, y = index / packed.side
        guard y < packed.side else { return .zero }
        let at = 4 * (y * packed.side + x)
        return SIMD4((0..<4).map { MDLMorphTargets.float(snormBits: packed.values[at + $0]) })
    }

    /// `generic4.vert`'s lookup (`base/model_vertex_v1.h`) of vertex `vertex` of the target at
    /// `offset`: its position delta and, with `MORPHING_NORMALS`, its normal delta.
    static func shaderLookup(_ packed: SceneMorphTexture.Packed, vertex: Int, offset: Int,
                             normals: Bool) -> (position: SIMD3<Float>, normal: SIMD3<Float>?) {
        let morphMapOffset = vertex + offset
        if normals {
            let index = morphMapOffset * 6 / 4, flip = morphMapOffset * 6 % 4
            let c1 = texel(packed, index), c2 = texel(packed, index + 1)
            let position = flip >= 1 ? SIMD3(c1.z, c1.w, c2.x) : SIMD3(c1.x, c1.y, c1.z)
            let normal = flip >= 1 ? SIMD3(c2.y, c2.z, c2.w) : SIMD3(c1.w, c2.x, c2.y)
            return (position, normal)
        }
        let index = morphMapOffset * 3 / 4, flip = morphMapOffset * 3 % 4
        let c1 = texel(packed, index), c2 = texel(packed, index + 1)
        switch flip {
        case 0: return (SIMD3(c1.x, c1.y, c1.z), nil)
        case 1: return (SIMD3(c1.y, c1.z, c1.w), nil)
        case 2: return (SIMD3(c1.z, c1.w, c2.x), nil)
        default: return (SIMD3(c1.w, c2.x, c2.y), nil)
        }
    }

    func testModelPackingMatchesTheShaderIndexMaths() throws {
        for normals in [false, true] {
            // 7 vertices × 5 targets: every flip of the positions-only layout.
            let strip = Self.strip(count: 7)
            let targets = Self.targets(5, vertices: 7, normals: normals)
            let model = try Self.model(format: strip.format, vertexData: strip.vertices, indices: strip.indices,
                                       flags: normals ? 0x400 : 0, targets: targets, morphVertices: 7)
            let mesh = model.meshes[0]
            let morphs = try XCTUnwrap(model.morphTargets?.first)
            let packed = try XCTUnwrap(SceneMorphTexture.model(morphs, meshFlags: mesh.flags, vertexCount: mesh.vertexCount))
            let values = 5 * 7 * (normals ? 6 : 3)
            XCTAssertEqual(packed.side, SceneMorphTexture.side(texels: (values + 3) / 4))
            XCTAssertEqual(packed.side, normals ? 8 : 6, "square: 27 or 53 texels")
            for t in 0..<5 {
                for v in 0..<7 {
                    let found = Self.shaderLookup(packed, vertex: v, offset: t * mesh.vertexCount, normals: normals)
                    XCTAssertEqual(found.position, Self.delta(t, v), "normals \(normals): target \(t) vertex \(v)")
                    if normals {
                        XCTAssertEqual(found.normal, Self.normalDelta(t, v), "target \(t) vertex \(v) normal")
                    }
                }
            }
        }
    }

    func testModelPackingQuirks() throws {
        XCTAssertEqual(SceneMorphTexture.side(texels: 16), 4)
        XCTAssertEqual(SceneMorphTexture.side(texels: 17), 5)
        XCTAssertEqual(SceneMorphTexture.side(texels: 1), 1)
        let strip = Self.strip(count: 4)
        // Tangent deltas (flag 0x800): counted in the size, nothing written (WE's copy skips them).
        let model = try Self.model(format: strip.format, vertexData: strip.vertices, indices: strip.indices, flags: 0x800,
                                   targets: Self.targets(2, vertices: 4), morphVertices: 4)
        let packed = try XCTUnwrap(SceneMorphTexture.model(try XCTUnwrap(model.morphTargets?.first), meshFlags: 0x800,
                                                           vertexCount: 4))
        XCTAssertEqual(packed.side, SceneMorphTexture.side(texels: (3 * 16 + 3) / 4))
        XCTAssertTrue(packed.values.allSatisfy { $0 == 0 })
    }

    func testPuppetPackingMatchesTheShaderIndexMaths() throws {
        // genericimage4: texel `a_PositionVec4.w + g_MorphOffsets[1 + k]`, (Δx, Δy, Δz, alpha).
        let vertices = 6
        var targets = Self.targets(3, vertices: vertices)
        for t in targets.indices { targets[t].alpha = (0..<vertices).map { Float($0 + t) / 16 } }
        let format = MDLVertexFormat(rawValue: 0x10000 | 0x8)
        let model = try Self.model(format: format, vertexData: Array(repeating: 0, count: 6 * 3),
                                   indices: [0, 1, 2], flags: 0x1000, targets: targets, morphVertices: vertices)
        let morphs = try XCTUnwrap(model.morphTargets?.first)
        let packed = SceneMorphTexture.puppet(morphs, meshFlags: 0x1000)
        XCTAssertEqual(packed.side, SceneMorphTexture.side(texels: 3 * vertices + 1))
        XCTAssertEqual(Array(packed.values[0..<4]), [0, 0, 0, 0x7fff], "texel 0: no delta, alpha 1")
        for t in 0..<3 {
            for j in 0..<vertices {
                let found = Self.texel(packed, (j + 1) + t * vertices)
                XCTAssertEqual(SIMD3(found.x, found.y, found.z), Self.delta(t, j), "target \(t) morph vertex \(j + 1)")
                XCTAssertEqual(found.w, Self.grid(Float(j + t) / 16))
            }
        }
        // Without flag 0x1000 WE fills nothing past texel 0.
        let unfilled = SceneMorphTexture.puppet(morphs, meshFlags: 0)
        XCTAssertTrue(unfilled.values.dropFirst(4).allSatisfy { $0 == 0 })
    }

    // MARK: - Weights and the active targets

    func testOnlyElevenTargetsApplyLargestFirst() {
        var weights = SceneMorphWeights(count: 14)
        let values: [Float] = [0.1, 0, 0.5, 0.2, 0.5, 0.9, 0.3, 0.05, 0.7, 0.2, 0.6, 0.4, 0.8, 1.0]
        for (index, value) in values.enumerated() { weights.setFromScript(index, value) }
        XCTAssertFalse(weights.isActive(1), "a zero weight turns its target off")
        // The first 11 set bits in index order (0, 2…11; target 1 is off), then by weight, ties in index order.
        let active = weights.activeTargets
        XCTAssertEqual(active.map(\.index), [5, 8, 10, 2, 4, 11, 6, 3, 9, 0, 7])
        XCTAssertEqual(active.count, SceneMorphWeights.maximumActive)
        let uniforms = SceneMorphUniforms(weights: weights, baseWeight: 0.5, stride: 1000)
        XCTAssertEqual(uniforms.offsets, [11, 5000, 8000, 10_000, 2000, 4000, 11_000, 6000, 3000, 9000, 0, 7000])
        XCTAssertEqual(uniforms.weights, [0.5, 0.9, 0.7, 0.6, 0.5, 0.5, 0.4, 0.3, 0.2, 0.2, 0.1, 0.05])
    }

    func testScriptMaskQuirkAndThreshold() {
        var weights = SceneMorphWeights(count: 40)
        weights.setFromScript(3, 1e-8)
        XCTAssertFalse(weights.isActive(3), "below FLT_EPSILON")
        XCTAssertEqual(weights.weights[3], 1e-8)
        weights.setFromScript(31, 1)
        XCTAssertEqual(weights.mask, 0xFFFF_FFFF_8000_0000, "WE's sign-extended 32-bit bit")
        weights.setFromScript(33, 0)
        XCTAssertEqual(weights.mask, 0xFFFF_FFFF_8000_0000 & ~0x2, "index 33 wraps to bit 1")
        weights.setFromScript(99, 1)
        XCTAssertEqual(weights.weights.count, 40, "out of range: ignored")
    }

    func testTrackRules() {
        var weights = SceneMorphWeights(count: 2)
        // Replace (weight 1): sets, and a value below epsilon only turns the target off.
        weights.apply(track: 0.6, to: 0, layerWeight: 1, additive: false, clampsBlend: true)
        XCTAssertEqual(weights.weights[0], 0.6)
        weights.apply(track: 0, to: 0, layerWeight: 1, additive: false, clampsBlend: true)
        XCTAssertFalse(weights.isActive(0))
        XCTAssertEqual(weights.weights[0], 0.6, "left as it was")
        // Blend: towards the value by the layer's weight, clamped on models only.
        weights.apply(track: 3, to: 0, layerWeight: 0.5, additive: false, clampsBlend: true)
        XCTAssertTrue(weights.isActive(0))
        XCTAssertEqual(weights.weights[0], 1)
        var puppet = SceneMorphWeights(count: 1)
        puppet.apply(track: 3, to: 0, layerWeight: 0.5, additive: false, clampsBlend: false)
        XCTAssertEqual(puppet.weights[0], 1.5)
        // Additive: x + v·w, clamped between x and v·w.
        weights.weights[1] = 0.3
        weights.apply(track: 0.4, to: 1, layerWeight: 0.5, additive: true, clampsBlend: true)
        XCTAssertEqual(weights.weights[1], 0.3, accuracy: 1e-6, "both positive: the larger")
        weights.weights[1] = -0.3
        weights.apply(track: 0.8, to: 1, layerWeight: 0.5, additive: true, clampsBlend: true)
        XCTAssertEqual(weights.weights[1], 0.1, accuracy: 1e-6, "opposite signs: the sum")
    }

    /// A clip's morph tracks drive the weights: lerped between frames, reset every frame.
    func testAClipAnimatesTheWeights() throws {
        let strip = Self.strip(count: 4)
        let clip = Clip(name: "smile", frames: 4, fps: 4, tracks: [(1, [0, 0.25, 0.5, 0.75, 1]), (0, [1, 0, 0, 0, 1])])
        let model = try Self.model(format: strip.format, vertexData: strip.vertices, indices: strip.indices, flags: 0,
                                   targets: Self.targets(2, vertices: 4), morphVertices: 4, clips: [clip])
        let morphs = try XCTUnwrap(SceneModelMorphs(model: model))
        let rig = SceneMorphRig.model(morphs)
        XCTAssertEqual(rig.targetCounts, [2])
        let skeleton = try XCTUnwrap(model.skeleton)
        let clips = try XCTUnwrap(model.animations)
        XCTAssertEqual(clips[0].meshTracks?.first?.morphTracks?.count, 2)
        let animator = ScenePuppetAnimator(skeleton: skeleton, clips: clips, layers: [WEAnimationLayer(animation: 100)],
                                           morphRig: rig)
        animator.advance(delta: 0.375, values: EffectGraphTests.FixedValues())
        // 0.375 s at 4 fps: between frames 1 and 2, halfway.
        XCTAssertEqual(animator.morphs[0].weights[1], 0.375, accuracy: 1e-6)
        XCTAssertFalse(animator.morphs[0].isActive(0), "frames 1 and 2 of target 0 are 0")
        XCTAssertEqual(morphs.uniforms(mesh: 0, weights: animator.morphs).offsets[0...1], [1, 4])
        animator.advance(delta: 0.625, values: EffectGraphTests.FixedValues())
        XCTAssertEqual(animator.morphs[0].weights[0], 1, accuracy: 1e-6, "at 1 s the loop is back at frame 0")
        XCTAssertEqual(animator.morphs[0].weights[1], 0, "every frame starts over")
        XCTAssertEqual(animator.morphs[0].activeTargets.map(\.index), [0])
        XCTAssertNil(ScenePuppetAnimator(skeleton: skeleton, clips: clips, layers: []).morphRig)
    }

    // MARK: - On the GPU through WE's vertex stages

    /// A model's mesh through `generic4` with `MORPHING` (and `MORPHING_NORMALS`): the clip's
    /// weights from the animator, the uniforms and texture the renderer binds; each vertex moves by
    /// `g_MorphWeights[0] · Σ w·Δ` of the targets that apply.
    func testAWeightedTargetMovesModelVerticesOnTheGPU() throws {
        for normals in [false, true] {
            let count = 9
            let strip = Self.strip(count: count)
            // 13 targets: weights 0.1…0.9 on 0…8 through tracks, 9…12 constant 0.95: 11 apply.
            var tracks: [(UInt16, [Float])] = []
            for index in 0..<13 {
                let weight: Float = index < 9 ? Float(index + 1) / 10 : 0.95
                tracks.append((UInt16(index), [weight, weight]))
            }
            let model = try Self.model(format: strip.format, vertexData: strip.vertices, indices: strip.indices,
                                       flags: normals ? 0x400 : 0, targets: Self.targets(13, vertices: count, normals: normals),
                                       morphVertices: count, baseWeight: 0.5,
                                       clips: [Clip(name: "c", frames: 1, fps: 1, tracks: tracks)])
            let morphs = try XCTUnwrap(SceneModelMorphs(model: model))
            let animator = try XCTUnwrap(ScenePuppetAnimator(skeleton: try XCTUnwrap(model.skeleton), clips: model.animations ?? [],
                                                             layers: [WEAnimationLayer(animation: 100)],
                                                             morphRig: .model(morphs)))
            animator.advance(delta: 0.25, values: EffectGraphTests.FixedValues())
            let uniforms = morphs.uniforms(mesh: 0, weights: animator.morphs)
            XCTAssertEqual(uniforms.offsets[0], 11)
            let active = animator.morphs[0].activeTargets
            XCTAssertEqual(active.map(\.index), [9, 10, 8, 7, 6, 5, 4, 3, 2, 1, 0], "the first 11 set, largest first")

            let harness = try Harness()
            let mesh = model.meshes[0]
            let material = try harness.modelMaterials.build(materialPath: "materials/morph.json",
                                                            mesh: ModelMeshCombos(mesh: mesh, bones: 1, morphTargets: true))
            let variant = try XCTUnwrap(material.pass.variant)
            XCTAssertEqual(variant.combos["MORPHING"], 1)
            XCTAssertEqual(variant.combos["MORPHING_NORMALS"] ?? 0, normals ? 1 : 0)
            let packed = try XCTUnwrap(SceneMorphTexture.model(try XCTUnwrap(morphs.meshes[0]).targets, meshFlags: mesh.flags,
                                                               vertexCount: mesh.vertexCount))
            let texture = try XCTUnwrap(SceneMorphTexture.makeTexture(packed, device: harness.device, label: "morph"))
            let program = ModelMaterialUniforms(layout: variant.uniforms, constants: material.pass.constants)
            program.writeMorphs(uniforms)
            var bytes = program.bytes
            try harness.writeIdentity(["g_ModelMatrix", "g_ViewProjectionMatrix"], layout: try XCTUnwrap(variant.uniforms),
                                      into: &bytes)
            try harness.writeTextureSize(slot: 5, texture: texture, layout: try XCTUnwrap(variant.uniforms), into: &bytes)
            let gpu = try harness.run(variant.vertexMSL, format: mesh.format, vertexData: mesh.vertexData, count: count,
                                      uniforms: bytes, textures: [5: texture])
            for v in 0..<count {
                var expected = SIMD3<Float>(Float(v), Float(v % 2), 0)
                var sum = SIMD3<Float>(repeating: 0)
                for target in active { sum += Self.delta(target.index, v) * target.weight }
                expected += sum * 0.5
                XCTAssertLessThan(simd_distance(gpu[v], expected), 1e-3, "normals \(normals) vertex \(v): \(gpu[v]) vs \(expected)")
            }
        }
    }

    /// A puppet's mesh through `genericimage4` with `MORPHING` and `MORPHING_MODIFIERS`: a script's
    /// `setBlendShapeWeight` through the animator; each vertex moves by its morph vertex's delta
    /// (`a_PositionVec4.w`, from 1; 0 doesn't morph) times the weight and the modifier's
    /// `smoothstep(start, end, |xy − bone|)`.
    func testAWeightedTargetMovesPuppetVerticesOnTheGPU() throws {
        // Position4 (w the morph vertex), blend indices, blend weights, uv.
        let format = MDLVertexFormat(rawValue: 0x10000 | 0x800000 | 0x1000000 | 0x8)
        let points: [SIMD2<Float>] = [SIMD2(2, 0), SIMD2(7, 0), SIMD2(12, 0), SIMD2(2, 3), SIMD2(4.5, 0)]
        let morphIndex: [Float] = [1, 2, 3, 0, 4]
        var data: [Float] = []
        for (i, point) in points.enumerated() {
            data += [point.x, point.y, 0, morphIndex[i]]
            data += [0, 0, 0, 0].map { Float(bitPattern: $0) }
            data += [1, 0, 0, 0, Float(i) / 8, 0.5]
        }
        let morphVertices = 4
        var targets = Self.targets(2, vertices: morphVertices)
        // Target 1: a point rule about bone 0 (at (2, 0)) from 0 to 10; target 0's always 1.
        targets[1].modifier = .init(bone: 0, mode: 0, startDistance: 0, endDistance: 10)
        targets[0].modifier = .init(bone: 0, mode: 0, startDistance: -1, endDistance: -0.5)
        let model = try Self.model(format: format, vertexData: data, indices: [0, 1, 2, 2, 3, 4], flags: 0x3000,
                                   targets: targets, morphVertices: morphVertices, baseWeight: 1, rootOffset: SIMD3(2, 0, 0))
        let harness = try Harness()
        let source = SceneMetalTextureSource.dxt(TEXCompressedTexture(format: 0, width: 64, height: 64, data: [],
                                                                      contentWidth: 64, contentHeight: 64))
        let plan = try ScenePuppetPlan.make(model: model, rigPath: "rig.mdl", materialPath: "materials/image4.json",
                                            source: source, imageSize: SIMD2(64, 64), builder: harness.imageMaterials)
        XCTAssertTrue(plan.combos.morphing && plan.combos.morphingModifiers)
        let variant = try XCTUnwrap(plan.material.pass.variant)
        XCTAssertEqual(variant.combos["MORPHING_MODIFIERS"], 1)
        let animator = plan.makeAnimator()
        // Scripts write after the frame's evaluation (WE's object loop runs before their `update`).
        animator.advance(delta: 1.0 / 60, values: EffectGraphTests.FixedValues())
        animator.perform(.setBlendShape(index: 1, weight: 0.5))
        animator.perform(.setBlendShape(index: 0, weight: 0.25))
        let morph = try XCTUnwrap(animator.pose.morph)
        XCTAssertEqual(Array(morph.offsets[0...2]), [2, 4, 0], "target 1 (0.5) first; offsets by the MDMP vertex count")
        XCTAssertEqual(Array(try XCTUnwrap(morph.boneRules)[0...8]), [0, 0, 10, 0, -1, -0.5, 0, -1, 0])

        let texture = try XCTUnwrap(SceneMorphTexture.makeTexture(SceneMorphTexture.puppet(try XCTUnwrap(plan.morphs),
                                                                                           meshFlags: plan.meshFlags),
                                                                  device: harness.device, label: "morph"))
        let layout = try XCTUnwrap(variant.uniforms)
        var bytes = [UInt8](repeating: 0, count: max(layout.size, 16))
        try harness.writeIdentity(["g_ModelViewProjectionMatrix"], layout: layout, into: &bytes)
        ScenePuppetRenderer.writePose(animator.pose, layout: layout, into: &bytes)
        try harness.writeTextureSize(slot: 5, texture: texture, layout: layout, into: &bytes)
        let gpu = try harness.run(variant.vertexMSL, format: plan.format, vertexData: plan.vertexData, count: points.count,
                                  uniforms: bytes, textures: [5: texture])
        for (i, point) in points.enumerated() {
            var expected = SIMD3<Float>(point.x, point.y, 0)
            let j = Int(morphIndex[i])
            if j > 0 {
                let distance = simd_length(point - SIMD2(2, 0))
                let x = min(max(distance / 10, 0), 1)
                let amount = x * x * (3 - 2 * x)
                expected += Self.delta(1, j - 1) * 0.5 * amount + Self.delta(0, j - 1) * 0.25
            }
            XCTAssertLessThan(simd_distance(gpu[i], expected), 1e-3, "vertex \(i): \(gpu[i]) vs \(expected)")
        }
    }

    // MARK: - WE's editor (docs/test-risks.md MG5)

    /// The WE 2.8 editor's puppet with one blend shape ("Shape 31", id 31, script access), which
    /// moves the editor's vertex 196 (its ids count from 1: mesh vertex 195, at (15, 252.95)) by
    /// +126.168 in x: its `MDMP` holds the deltas normalised by the mesh's weight (126.47, the
    /// largest delta's length) as 16-bit signed normalised values, one per morph vertex (62,
    /// found by `a_PositionVec4.w` from 1, with a 16-bit alpha each, flag 0x1000).
    func testTheEditorsBlendShapeReadsAsWEsSnormTexture() throws {
        let model = try MDLModel(contentsOf: Fixtures.url("Models/mg5-puppet-blendshape.mdl"))
        let mesh = try XCTUnwrap(model.meshes.first)
        XCTAssertEqual(mesh.flags & 0x1000, 0x1000)
        let morphs = try XCTUnwrap(model.morphTargets?.first)
        XCTAssertEqual(morphs.targets.map(\.name), ["Shape 31"])
        XCTAssertEqual(morphs.targets.map(\.id), [31])
        XCTAssertEqual(morphs.vertexCount, 62)
        let scale = try XCTUnwrap(morphs.weight)
        XCTAssertEqual(scale, 126.47, accuracy: 0.01)
        XCTAssertEqual(morphs.targets[0].extra?.count, 124)
        // The vertex's morph vertex (`a_PositionVec4.w`, the position's fourth float).
        let stride = mesh.format.stride
        let w: Float = mesh.vertexData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 195 * stride + 12, as: Float.self) }
        XCTAssertEqual(w, 58)
        let packed = SceneMorphTexture.puppet(morphs, meshFlags: mesh.flags)
        let texel = Self.texel(packed, Int(w))
        let moved = SIMD3<Float>(texel.x, texel.y, texel.z) * scale
        XCTAssertEqual(moved.x, 126.168, accuracy: 0.01, "the editor's offset")
        XCTAssertEqual(moved.y, 0, accuracy: 0.01)
        // Every delta lies within its weight: none is past ±1 as the normalised values it is.
        let largest: Float = morphs.targets[0].positions.map(abs).max() ?? 0
        XCTAssertLessThanOrEqual(largest, 1)
    }

    // MARK: - Scripts

    func testScriptBlendShapesRoundTrip() throws {
        var rig = SceneScriptRigTests.rig
        rig.blendShapes = ["smile", "blink"]
        var image = SceneScriptObjectDescription.make(.image, id: 5, name: "puppet")
        image.rig = rig
        let plain = SceneScriptObjectDescription.make(.image, id: 6, name: "plain")
        let f = try SceneScriptObjectFixture(FakeSceneScriptObjectHost(scene: SceneScriptSceneDescription(objects: [image, plain])))
        f.runtime.load()
        f.evaluate("var puppet = thisScene.getLayer('puppet'), plain = thisScene.getLayer('plain');")
        XCTAssertEqual(f.evaluate("""
            [puppet.getBlendShapeIndex('blink'), puppet.getBlendShapeIndex('nope'), puppet.getBlendShapeIndex(1),
             puppet.getBlendShapeWeight('smile'), plain.getBlendShapeIndex('blink'), plain.getBlendShapeWeight(0)].join()
            """)?.toString(), "1,-1,-1,0,-1,0")
        f.evaluate("puppet.setBlendShapeWeight('blink', 0.75); puppet.setBlendShapeWeight(0, 0.25); puppet.setBlendShapeWeight(5, 1);")
        XCTAssertEqual(f.evaluate("[puppet.getBlendShapeWeight(1), puppet.getBlendShapeWeight('smile')].join()")?.toString(),
                       "0.75,0.25", "read back at once")
        f.runtime.frame(deltaTime: 1.0 / 60)
        let commands = f.host.takeCommands().compactMap { command -> SceneScriptRigCommand? in
            if case .rig(_, let rig) = command { return rig }
            return nil
        }
        XCTAssertEqual(commands, [.setBlendShape(index: 1, weight: 0.75), .setBlendShape(index: 0, weight: 0.25)])

        // The renderer's weights replace the script's copy at the next frame.
        let slot = try XCTUnwrap(f.store.rigSlot(of: try XCTUnwrap(f.model.slot(forObjectID: 5))))
        let feedback = SceneScriptRigFeedback(layers: [], locals: (0..<3).map { _ in matrix_identity_float4x4 },
                                              worlds: (0..<3).map { _ in matrix_identity_float4x4 }, blendShapeWeights: [0.5, 0])
        SceneScriptRigMirror().publish([5: feedback], into: f.store.rigs) { $0 == 5 ? slot : nil }
        f.runtime.frame(deltaTime: 1.0 / 60)
        XCTAssertEqual(f.evaluate("[puppet.getBlendShapeWeight(0), puppet.getBlendShapeWeight('blink')].join()")?.toString(), "0.5,0")

        // The command's decode and the animator's application.
        XCTAssertEqual(SceneScriptRigLayout.decode(.rigBlendShape, numbers: [1, 0.5], strings: []),
                       .setBlendShape(index: 1, weight: 0.5))
        XCTAssertNil(SceneScriptRigLayout.decode(.rigBlendShape, numbers: [1, .nan], strings: []))
    }

    func testAScriptWeightHoldsForOneFrame() throws {
        let strip = Self.strip(count: 3)
        let model = try Self.model(format: strip.format, vertexData: strip.vertices, indices: strip.indices, flags: 0,
                                   targets: Self.targets(2, vertices: 3), morphVertices: 3)
        let animator = ScenePuppetAnimator(skeleton: try XCTUnwrap(model.skeleton), clips: [], layers: [],
                                           morphRig: SceneMorphRig.puppet(model.morphTargets?.first, meshFlags: 0))
        animator.advance(delta: 1.0 / 60, values: EffectGraphTests.FixedValues())
        animator.perform(.setBlendShape(index: 1, weight: 0.5))
        XCTAssertEqual(animator.blendShapeWeights, [0, 0.5], "the frame it arrives in (after that frame's evaluation)")
        XCTAssertEqual(animator.pose.morph?.offsets[0...1], [1, 3])
        animator.advance(delta: 1.0 / 60, values: EffectGraphTests.FixedValues())
        XCTAssertEqual(animator.blendShapeWeights, [0, 0], "every frame starts over (0x1401fecba)")
        XCTAssertEqual(animator.pose.morph?.offsets[0], 0)
    }

    // MARK: - The GPU harness

    /// Runs a translated vertex stage as a compute kernel over a mesh's vertices, with its
    /// textures and `gl_VertexID`, and returns the clip positions with the translation's
    /// fix-ups undone (the identity matrices make them the local positions).
    final class Harness {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let modelMaterials: ModelMaterialPlanBuilder
        let imageMaterials: ImageMaterialPlanBuilder
        private let cache: URL

        init() throws {
            let assets = ShaderVariantTests.weAssets
            try XCTSkipUnless(FileManager.default.fileExists(atPath: assets.appending(path: "shaders/generic4.vert").path),
                              "bundled WE shaders missing")
            device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
            queue = try XCTUnwrap(device.makeCommandQueue())
            cache = FileManager.default.temporaryDirectory.appending(path: "owe-morph-\(UUID().uuidString)")
            let translator = ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: cache)
            func reader(_ roots: [URL]) -> (String) -> Data? {
                { path in
                    for root in roots {
                        if let data = FileManager.default.contents(atPath: root.appending(path: path).path) { return data }
                    }
                    return nil
                }
            }
            modelMaterials = ModelMaterialPlanBuilder(translator: translator, readFile: reader([Fixtures.url("ModelMaterials"), assets]),
                                                      loadTexture: { _, _ in .image(NSImage(size: NSSize(width: 4, height: 4))) })
            imageMaterials = ImageMaterialPlanBuilder(translator: translator, readFile: reader([Fixtures.url("ImageMaterials"), assets]),
                                                      loadTexture: { _, _ in nil })
        }

        deinit { try? FileManager.default.removeItem(at: cache) } // scratch cleanup

        func writeIdentity(_ names: [String], layout: UniformLayout, into bytes: inout [UInt8]) throws {
            let identity = matrix_identity_float4x4
            for name in names {
                let member = try XCTUnwrap(layout.members[name], name)
                UniformWriter.write([identity.columns.0, identity.columns.1, identity.columns.2, identity.columns.3]
                    .flatMap { [$0.x, $0.y, $0.z, $0.w] }, member: member, into: &bytes)
            }
        }

        func writeTextureSize(slot: Int, texture: MTLTexture, layout: UniformLayout, into bytes: inout [UInt8]) throws {
            let member = try XCTUnwrap(layout.members["g_Texture\(slot)Resolution"], "g_Texture\(slot)Resolution")
            let w = Float(texture.width), h = Float(texture.height)
            UniformWriter.write([w, h, w, h], member: member, into: &bytes)
        }

        func run(_ vertexMSL: String, format: MDLVertexFormat, vertexData: Data, count: Int, uniforms: [UInt8],
                 textures: [Int: MTLTexture]) throws -> [SIMD3<Float>] {
            let library = try device.makeLibrary(source: try Self.kernel(vertexMSL, format: format), options: nil)
            let pipeline = try device.makeComputePipelineState(function: try XCTUnwrap(library.makeFunction(name: "oweMorphCapture")))
            let sampler = try XCTUnwrap(device.makeSamplerState(descriptor: MTLSamplerDescriptor()))
            let uniformBuffer = try XCTUnwrap(device.makeBuffer(bytes: uniforms, length: max(uniforms.count, 16)))
            let vertices = try XCTUnwrap(vertexData.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) })
            let out = try XCTUnwrap(device.makeBuffer(length: count * 16, options: .storageModeShared))
            let commands = try XCTUnwrap(queue.makeCommandBuffer())
            let encoder = try XCTUnwrap(commands.makeComputeCommandEncoder())
            encoder.setComputePipelineState(pipeline)
            encoder.setBuffer(uniformBuffer, offset: 0, index: 0)
            encoder.setBuffer(vertices, offset: 0, index: 30)
            encoder.setBuffer(out, offset: 0, index: 29)
            for (slot, texture) in textures {
                encoder.setTexture(texture, index: slot)
                encoder.setSamplerState(sampler, index: slot)
            }
            encoder.dispatchThreads(MTLSize(width: count, height: 1, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: min(64, count), height: 1, depth: 1))
            encoder.endEncoding()
            commands.commit()
            commands.waitUntilCompleted()
            XCTAssertNil(commands.error)
            let raw = UnsafeBufferPointer(start: out.contents().assumingMemoryBound(to: SIMD4<Float>.self), count: count)
            return raw.map { SIMD3($0.x / $0.w, -$0.y / $0.w, ($0.z / $0.w) * 2 - 1) }
        }

        /// The vertex function as a plain function, called by a kernel that fills its stage-in
        /// from the mesh and passes the thread index as `gl_VertexID`; its buffers, textures and
        /// samplers keep their bindings.
        static func kernel(_ vertexMSL: String, format: MDLVertexFormat) throws -> String {
            let pattern = /vertex main0_out main0\(([^{]*)\)\s*\{/
            let match = try XCTUnwrap(vertexMSL.firstMatch(of: pattern), "an unexpected vertex entry point")
            var parameters: [String] = []
            var depth = 0, current = ""
            for character in String(match.1) {
                if character == "<" || character == "[" { depth += 1 }
                if character == ">" || character == "]" { depth -= 1 }
                if character == ",", depth == 0 {
                    parameters.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                } else {
                    current.append(character)
                }
            }
            parameters.append(current.trimmingCharacters(in: .whitespaces))
            var plain: [String] = [], kernelParameters: [String] = [], arguments: [String] = []
            for parameter in parameters {
                let declaration = parameter.replacingOccurrences(of: #"\s*\[\[[^\]]*\]\]"#, with: "", options: .regularExpression)
                let name = try XCTUnwrap(declaration.split(separator: " ").last.map { String($0).replacingOccurrences(of: "&", with: "") })
                plain.append(declaration)
                if parameter.contains("[[stage_in]]") {
                    arguments.append("in")
                } else if parameter.contains("[[vertex_id]]") {
                    arguments.append("vid")
                } else {
                    kernelParameters.append(parameter)
                    arguments.append(name)
                }
            }
            let body = vertexMSL.replacingCharacters(in: match.range,
                                                     with: "static main0_out main0_body(\(plain.joined(separator: ", ")))\n{")
                .replacingOccurrences(of: #"\s*\[\[(attribute|user|position)[^\]]*\]\]"#, with: "", options: .regularExpression)
            var fills = ""
            let structText = try XCTUnwrap(vertexMSL.firstMatch(of: /struct main0_in\s*\{([^}]*)\}/)?.1)
            for field in String(structText).matches(of: /(\w+) (a_\w+) \[\[attribute\(\d+\)\]\];/) {
                let type = String(field.1), name = String(field.2)
                guard let attribute = MDLVertexAttribute.named(name), let offset = format.offset(of: attribute) else { continue }
                fills += "    in.\(name) = \(type)(*(device const packed_\(type)*)(v + \(offset)));\n"
            }
            return body + """

            kernel void oweMorphCapture(\((kernelParameters + ["device const uchar* mesh [[buffer(30)]]",
                                                              "device float4* out [[buffer(29)]]",
                                                              "uint vid [[thread_position_in_grid]]"]).joined(separator: ", "))) {
                main0_in in = {};
                device const uchar* v = mesh + vid * \(format.stride);
            \(fills)    out[vid] = main0_body(\(arguments.joined(separator: ", "))).gl_Position;
            }
            """
        }
    }
}
