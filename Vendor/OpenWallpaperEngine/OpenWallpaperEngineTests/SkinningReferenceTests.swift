import XCTest
import Metal
import simd
@testable import OpenWallpaperEngine

/// Skinning against WE's rules (docs/models-plan.md §2.8, §4.3 M6): `Scripts/skinning-reference.py`
/// (committed output for the fixture rig, run at test time for the library's), `SkinningReference`
/// (the same rules in Swift, double precision), the app's `SceneAnimationLayerStack` +
/// `SceneSkeleton`, and the GPU: the translated puppet vertex stage run over the rig's vertices.
/// Everything agrees within 1e-4 of each value's magnitude (at least 1e-4 absolute).
final class SkinningReferenceTests: XCTestCase {
    static let tolerance = 1e-4

    // MARK: - The fixture rig

    /// `v13-puppet.mdl` (3 bones, a "mirror" clip with a disabled track) at t = 0, 0.05 and 0.13 s
    /// (past the clip's end: the mirror turns).
    func testTheFixtureRigMatchesTheScript() throws {
        let model = try MDLModel(contentsOf: Fixtures.url("Models/v13-puppet.mdl"))
        let entries = try SkinningReferenceEntry.load(Fixtures.url("Models/skinning.json"))
        let entry = try XCTUnwrap(entries.first)
        try check(model, against: entry, label: "v13-puppet")
    }

    /// The translated `genericimage2` vertex stage with the puppet combos (`SKINNING`, the exact
    /// `BONECOUNT`) skins the fixture's and a posed grid's vertices as the CPU does.
    func testTheGPUSkinsLikeTheCPU() throws {
        let harness = try GPUHarness()
        let model = try MDLModel(contentsOf: Fixtures.url("Models/v13-puppet.mdl"))
        let clip = try XCTUnwrap(model.animations?.first)
        let skeleton = try XCTUnwrap(model.skeleton)
        for time in [0.0, 0.05, 0.13] {
            let reference = SkinningReference.pose(skeleton, clip: clip, time: time)
            let expected = try XCTUnwrap(SkinningReference.skin(model.meshes[0], palette: reference.palette))
            let gpu = try harness.skin(model, palette: reference.palette.map(simd_float4x4.init(converting:)))
            assertClose(gpu.map(SIMD3<Double>.init), expected, "fixture GPU at \(time)")
        }

        // A 12-bone grid, every bone turned, moved and scaled.
        let bones = 12
        let mesh = Self.grid(bones: bones)
        var gridBones: [MDLBone] = []
        for index in 0..<bones {
            let parent: UInt32 = index == 0 ? 0xFFFF_FFFF : UInt32(index - 1)
            let offset = SIMD3<Float>(Float(index) * 10, 0, 0)
            gridBones.append(MDLBone(name: "b\(index)", flags: 1, parent: parent,
                                     matrix: ScenePuppetTests.translation(offset), properties: ""))
        }
        let gridSkeleton = MDLSkeleton(version: 1, bones: gridBones)
        let grid = MDLModel(tag: "MDLV0013", version: 13, legacyFormat: mesh.format.rawValue, materialsPerMesh: 1,
                            meshes: [mesh], skeleton: gridSkeleton, end: 0, trailingByteCount: 0)
        var generator = SystemRandomNumberGenerator()
        let palette = (0..<bones).map { _ -> simd_double4x4 in
            let transform = SceneBoneTransform(
                translation: SIMD3(Float.random(in: -300...300, using: &generator), Float.random(in: -300...300, using: &generator), 0),
                rotation: simd_quatf(angle: Float.random(in: -3...3, using: &generator), axis: SIMD3(0, 0, 1)),
                scale: SIMD3(Float.random(in: 0.5...2, using: &generator), Float.random(in: 0.5...2, using: &generator), 1))
            return simd_double4x4(transform.matrix)
        }
        let expected = try XCTUnwrap(SkinningReference.skin(mesh, palette: palette))
        let gpu = try harness.skin(grid, palette: palette.map(simd_float4x4.init(converting:)))
        assertClose(gpu.map(SIMD3<Double>.init), expected, "grid GPU")
    }

    // MARK: - The library

    /// The rigs M6 names (PaRappa's pj and parappa, the SAS shuffle, the Knight and the Samurai),
    /// through the script run now; the puppets also through the GPU. Skipped without the library or python3.
    func testLibraryRigsMatchTheScript() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: LibrarySweepTests.libraryRoot.path), "wallpaper library not present")
        try XCTSkipIf(ReferenceScript.python == nil, "no python3 to run Scripts/skinning-reference.py")
        let output = FileManager.default.temporaryDirectory.appending(path: "owe-skinning-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: output) } // scratch cleanup
        try ReferenceScript.run("skinning-reference.py", arguments: ["library", "--out", output.path])
        let entries = try SkinningReferenceEntry.load(output)
        try XCTSkipIf(entries.isEmpty, "none of the rigs' wallpapers is in the library")
        let harness = try GPUHarness()
        for entry in entries {
            let item = try XCTUnwrap(entry.item)
            let directory = LibrarySweepTests.libraryRoot.appending(path: item, directoryHint: .isDirectory)
            let model: MDLModel
            do {
                model = try MDLModel.load(path: entry.file, package: nil, directory: directory)
            } catch {
                // Not loose in OpenWallpaperStorage (a workshop item): the script found it elsewhere.
                continue
            }
            try check(model, against: entry, label: "\(item) \(entry.file)")
            guard entry.file.hasSuffix("_puppet.mdl"), let skeleton = model.skeleton,
                  let clip = model.animations?.first(where: { $0.id == entry.clipID }) else { continue }
            for pose in entry.poses {
                let reference = SkinningReference.pose(skeleton, clip: clip, time: pose.time)
                let expected = try XCTUnwrap(SkinningReference.skin(model.meshes[0], palette: reference.palette))
                let gpu = try harness.skin(model, palette: reference.palette.map(simd_float4x4.init(converting:)))
                assertClose(gpu.map(SIMD3<Double>.init), expected, "\(item) GPU at \(pose.time)")
            }
        }
    }

    // MARK: - Checks

    /// The script's clock, palette and positions against `SkinningReference`, and the palette
    /// against the app's layer stack played from 0 by the same time.
    private func check(_ model: MDLModel, against entry: SkinningReferenceEntry, label: String) throws {
        let skeleton = try XCTUnwrap(model.skeleton, label)
        let clips = try XCTUnwrap(model.animations, label)
        let clipIndex = try XCTUnwrap(clips.firstIndex { $0.id == entry.clipID }, label)
        let clip = clips[clipIndex]
        for pose in entry.poses {
            let reference = SkinningReference.pose(skeleton, clip: clip, time: pose.time)
            XCTAssertEqual(reference.clockTime, pose.clockTime, accuracy: 1e-9, "\(label) clock at \(pose.time)")
            XCTAssertEqual([reference.frame0, reference.frame1], [pose.frame0, pose.frame1], "\(label) frames at \(pose.time)")
            let expectedPalette = pose.palette
            let referencePalette = reference.palette.flatMap(Self.values)
            assertClose(referencePalette, expectedPalette, "\(label) reference palette at \(pose.time)")

            let app = Self.appPalette(skeleton, clips: clips, clip: clipIndex, time: Float(pose.time))
            assertClose(app.flatMap { Self.values(simd_double4x4($0)) }, expectedPalette,
                        "\(label) app palette at \(pose.time)")

            for (key, positions) in pose.positions {
                let mesh = try XCTUnwrap(Int(key).map { model.meshes[$0] }, label)
                let skinned = try XCTUnwrap(SkinningReference.skin(mesh, palette: reference.palette), label)
                assertClose(skinned.flatMap { [$0.x, $0.y, $0.z] }, positions, "\(label) mesh \(key) at \(pose.time)")
            }
        }
    }

    /// The app's palette: one layer of the clip, weight 1, advanced once from 0 by `time`.
    static func appPalette(_ skeleton: MDLSkeleton, clips: [MDLAnimation], clip: Int, time: Float) -> [simd_float4x4] {
        let bones = SceneSkeleton(skeleton)
        var stack = SceneAnimationLayerStack(skeleton: bones, clips: clips)
        stack.insert(SceneAnimationLayer(key: 0, name: "", clip: clip, animation: clips[clip]))
        var update = SceneAnimationLayerUpdate()
        let pose = stack.evaluate(delta: time, update: &update)
        return bones.palette(worlds: bones.worlds(locals: pose.map(\.matrix)))
    }

    static func values(_ m: simd_double4x4) -> [Double] {
        [m.columns.0, m.columns.1, m.columns.2, m.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
    }

    private func assertClose(_ actual: [Double], _ expected: [Double], _ label: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, label, file: file, line: line)
        var worst = 0.0, at = -1
        for (index, (a, e)) in zip(actual, expected).enumerated() {
            let excess = abs(a - e) / max(1, abs(e))
            if !(excess <= worst) { worst = excess; at = index }
        }
        XCTAssertLessThanOrEqual(worst, Self.tolerance, "\(label): worst relative error at \(at)", file: file, line: line)
    }

    private func assertClose(_ actual: [SIMD3<Double>], _ expected: [SIMD3<Double>], _ label: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        assertClose(actual.flatMap { [$0.x, $0.y, $0.z] }, expected.flatMap { [$0.x, $0.y, $0.z] }, label,
                    file: file, line: line)
    }

    /// A strip of quads, quad k on bone k, laid along x.
    static func grid(bones: Int) -> MDLMesh {
        var quads: [(position: SIMD4<Float>, uv: SIMD4<Float>)] = []
        for k in 0..<bones {
            let left = Float(k) * 20 - 100
            quads.append((position: SIMD4<Float>(left, 30, left + 20, -30), uv: SIMD4<Float>(0, 0, 1, 1)))
        }
        let boneIndices: [UInt32] = (0..<bones).map { UInt32($0) }
        return ScenePuppetTests.mesh(quads: quads, bones: boneIndices)
    }

    // MARK: - GPU

    /// The mesh pass's translated vertex stage, turned into a compute kernel over the rig's
    /// vertices (its stage-in read from the interleaved buffer by attribute name), with an identity
    /// `g_ModelViewProjectionMatrix`: its `gl_Position` is the skinned position, with the
    /// translation's Metal clip fix-ups (y negated, z remapped) undone.
    final class GPUHarness {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let builder: ImageMaterialPlanBuilder
        private let cache: URL

        init() throws {
            let assets = ShaderVariantTests.weAssets
            try XCTSkipUnless(FileManager.default.fileExists(atPath: assets.appending(path: "shaders/genericimage2.vert").path),
                              "bundled WE shaders missing")
            device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
            queue = try XCTUnwrap(device.makeCommandQueue())
            cache = FileManager.default.temporaryDirectory.appending(path: "owe-skinning-gpu-\(UUID().uuidString)")
            let translator = ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: cache)
            let roots = [Fixtures.url("ImageMaterials"), assets]
            builder = ImageMaterialPlanBuilder(
                translator: translator,
                readFile: { path in
                    for root in roots {
                        if let data = FileManager.default.contents(atPath: root.appending(path: path).path) { return data }
                    }
                    return nil
                },
                loadTexture: { _, _ in nil })
        }

        deinit { try? FileManager.default.removeItem(at: cache) } // scratch cleanup

        func skin(_ model: MDLModel, palette: [simd_float4x4]) throws -> [SIMD3<Float>] {
            let size = SIMD2<Float>(1024, 1024)
            let source = SceneMetalTextureSource.dxt(TEXCompressedTexture(format: 0, width: 1024, height: 1024, data: [],
                                                                          contentWidth: 1024, contentHeight: 1024))
            let plan = try ScenePuppetPlan.make(model: model, rigPath: "rig.mdl", materialPath: "materials/image4.json",
                                                source: source, imageSize: size, builder: builder)
            let variant = try XCTUnwrap(plan.material.pass.variant)
            let kernel = try Self.kernel(variant.vertexMSL, format: plan.format)
            let library = try device.makeLibrary(source: kernel, options: nil)
            let pipeline = try device.makeComputePipelineState(function: try XCTUnwrap(library.makeFunction(name: "oweCapture")))

            let layout = try XCTUnwrap(variant.uniforms)
            var bytes = [UInt8](repeating: 0, count: max(layout.size, 16))
            if let member = layout.members["g_ModelViewProjectionMatrix"] {
                let identity = matrix_identity_float4x4
                UniformWriter.write([identity.columns.0, identity.columns.1, identity.columns.2, identity.columns.3]
                    .flatMap { [$0.x, $0.y, $0.z, $0.w] }, member: member, into: &bytes)
            }
            ScenePuppetRenderer.writePose(ScenePuppetPose(bones: palette, bonesAlpha: Array(repeating: 1, count: palette.count)),
                                          layout: layout, into: &bytes)
            let count = model.meshes[0].vertexCount
            let uniforms = try XCTUnwrap(device.makeBuffer(bytes: bytes, length: bytes.count))
            let vertices = try XCTUnwrap(plan.vertexData.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) })
            let out = try XCTUnwrap(device.makeBuffer(length: count * 16, options: .storageModeShared))
            let commands = try XCTUnwrap(queue.makeCommandBuffer())
            let encoder = try XCTUnwrap(commands.makeComputeCommandEncoder())
            encoder.setComputePipelineState(pipeline)
            encoder.setBuffer(uniforms, offset: 0, index: 0)
            encoder.setBuffer(vertices, offset: 0, index: 1)
            encoder.setBuffer(out, offset: 0, index: 2)
            encoder.dispatchThreads(MTLSize(width: count, height: 1, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: min(64, count), height: 1, depth: 1))
            encoder.endEncoding()
            commands.commit()
            commands.waitUntilCompleted()
            let positions = UnsafeBufferPointer(start: out.contents().assumingMemoryBound(to: SIMD4<Float>.self), count: count)
            return positions.map { SIMD3($0.x / $0.w, -$0.y / $0.w, ($0.z / $0.w) * 2 - 1) }
        }

        /// The vertex function as a plain function called by a kernel that fills its stage-in.
        static func kernel(_ vertexMSL: String, format: MDLVertexFormat) throws -> String {
            let entry = try XCTUnwrap(vertexMSL.range(of: #"vertex main0_out main0\(main0_in in \[\[stage_in\]\], constant (\w+)& (\w+) \[\[buffer\(0\)\]\]\)"#,
                                                      options: .regularExpression), "an unexpected vertex entry point")
            let signature = String(vertexMSL[entry])
            let uniformType = try XCTUnwrap(signature.firstMatch(of: /constant (\w+)&/)?.1)
            var source = vertexMSL.replacingCharacters(in: entry, with: "static main0_out main0_body(main0_in in, constant \(uniformType)& u)")
                .replacingOccurrences(of: #"\s*\[\[(attribute|user|position)[^\]]*\]\]"#, with: "", options: .regularExpression)
            // The body names its uniform parameter as SPIR-V-Cross did.
            let parameter = try XCTUnwrap(signature.firstMatch(of: /& (\w+) \[\[buffer/)?.1)
            source = source.replacingOccurrences(of: "main0_in in, constant \(uniformType)& u)",
                                                 with: "main0_in in, constant \(uniformType)& \(parameter))")
            var fills = ""
            let structText = try XCTUnwrap(vertexMSL.firstMatch(of: /struct main0_in\s*\{([^}]*)\}/)?.1)
            for match in String(structText).matches(of: /(\w+) (a_\w+) \[\[attribute\(\d+\)\]\];/) {
                let type = String(match.1), name = String(match.2)
                guard let attribute = MDLVertexAttribute.named(name), let offset = format.offset(of: attribute) else { continue }
                fills += "    in.\(name) = \(type)(*(device const packed_\(type)*)(v + \(offset)));\n"
            }
            return source + """

            kernel void oweCapture(constant \(uniformType)& u [[buffer(0)]], device const uchar* mesh [[buffer(1)]],
                                   device float4* out [[buffer(2)]], uint vid [[thread_position_in_grid]]) {
                main0_in in = {};
                device const uchar* v = mesh + vid * \(format.stride);
            \(fills)    out[vid] = main0_body(in, u).gl_Position;
            }
            """
        }
    }
}
