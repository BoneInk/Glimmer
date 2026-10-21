import XCTest
import Metal
import AppKit
import simd
@testable import OpenWallpaperEngine

/// Model bones (docs/models-plan.md §2.8, §4.3 M6): a library model posed by the app the way the
/// model renderer poses it (`SceneModelPlan.makeAnimator` from the object's animation layers, the
/// palette into `ModelMaterialUniforms`' bones slot at WE's rounded `BONECOUNT`) and skinned by
/// WE's own `generic4` vertex stage on the GPU, against `SkinningReference` (WE's rules on the
/// CPU, double precision) within 1e-4 of each value's magnitude. Skipped without the library.
final class ModelSkinningTests: XCTestCase {
    func testALibraryModelSkinsOnTheGPULikeTheReference() throws {
        let assets = ShaderVariantTests.weAssets
        let directory = LibrarySweepTests.libraryRoot.appending(path: "3159348391", directoryHint: .isDirectory)
        let path = "models/parappa/parappa.mdl"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: directory.appending(path: path).path), "PaRappa not in the library")
        let model = try MDLModel.load(path: path, package: nil, directory: directory)
        let skeleton = try XCTUnwrap(model.skeleton)
        XCTAssertEqual(skeleton.bones.count, 115)
        let clips = try XCTUnwrap(model.animations)
        let clip = try XCTUnwrap(clips.first)
        let mesh = try XCTUnwrap(model.meshes.first { $0.isSkinned })

        let cache = FileManager.default.temporaryDirectory.appending(path: "owe-model-skinning-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache) } // scratch cleanup
        let roots = [Fixtures.url("ModelMaterials"), assets]
        let builder = ModelMaterialPlanBuilder(
            translator: ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: cache),
            readFile: { path in
                for root in roots {
                    if let data = FileManager.default.contents(atPath: root.appending(path: path).path) { return data }
                }
                return nil
            },
            loadTexture: { _, _ in .image(NSImage(size: NSSize(width: 4, height: 4))) })
        let material = try builder.build(materialPath: "materials/generic4.json",
                                         mesh: ModelMeshCombos(mesh: mesh, bones: skeleton.bones.count, morphTargets: false))
        let variant = try XCTUnwrap(material.pass.variant)
        XCTAssertEqual(variant.combos["BONECOUNT"], 128)
        let plan = SceneModelPlan(path: path, meshes: [SceneModelPlan.Mesh(
            index: 0, material: material, format: mesh.format, vertexData: mesh.vertexData, indexData: mesh.indexData,
            usesUInt32Indices: mesh.usesUInt32Indices, indexCount: mesh.indexCount)],
            bounds: model.bounds, skeleton: skeleton, clips: clips)

        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let kernel = try SkinningReferenceTests.GPUHarness.kernel(variant.vertexMSL, format: mesh.format)
        let library = try device.makeLibrary(source: kernel, options: nil)
        let pipeline = try device.makeComputePipelineState(function: try XCTUnwrap(library.makeFunction(name: "oweCapture")))
        let layout = try XCTUnwrap(variant.uniforms)
        let vertices = try XCTUnwrap(mesh.vertexData.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) })
        let count = mesh.vertexCount

        var posed = 0
        for time in [0.0, 0.4, 1.1] {
            let animator = try XCTUnwrap(plan.makeAnimator(layers: [WEAnimationLayer(animation: clip.id)], objectName: "parappa"))
            animator.advance(delta: Float(time), values: EffectGraphTests.FixedValues())
            let uniforms = ModelMaterialUniforms(layout: layout, constants: material.pass.constants)
            uniforms.writeBones(animator.pose.boneComponents)
            var bytes = uniforms.bytes
            let identity = matrix_identity_float4x4
            for name in ["g_ModelMatrix", "g_ViewProjectionMatrix"] {
                let member = try XCTUnwrap(layout.members[name], name)
                UniformWriter.write([identity.columns.0, identity.columns.1, identity.columns.2, identity.columns.3]
                    .flatMap { [$0.x, $0.y, $0.z, $0.w] }, member: member, into: &bytes)
            }
            let uniformBuffer = try XCTUnwrap(device.makeBuffer(bytes: bytes, length: max(bytes.count, 16)))
            let out = try XCTUnwrap(device.makeBuffer(length: count * 16, options: .storageModeShared))
            let commands = try XCTUnwrap(queue.makeCommandBuffer())
            let encoder = try XCTUnwrap(commands.makeComputeCommandEncoder())
            encoder.setComputePipelineState(pipeline)
            encoder.setBuffer(uniformBuffer, offset: 0, index: 0)
            encoder.setBuffer(vertices, offset: 0, index: 1)
            encoder.setBuffer(out, offset: 0, index: 2)
            encoder.dispatchThreads(MTLSize(width: count, height: 1, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: min(64, count), height: 1, depth: 1))
            encoder.endEncoding()
            commands.commit()
            commands.waitUntilCompleted()
            let raw = UnsafeBufferPointer(start: out.contents().assumingMemoryBound(to: SIMD4<Float>.self), count: count)
            // The translation's Metal clip fix-ups (y negated, z remapped) undone.
            let gpu = raw.map { SIMD3<Double>(Double($0.x / $0.w), Double(-$0.y / $0.w), Double(($0.z / $0.w) * 2 - 1)) }

            let reference = SkinningReference.pose(skeleton, clip: clip, time: time)
            let expected = try XCTUnwrap(SkinningReference.skin(mesh, palette: reference.palette))
            XCTAssertEqual(gpu.count, expected.count)
            var worst = 0.0
            for (a, e) in zip(gpu, expected) {
                for axis in 0..<3 { worst = max(worst, abs(a[axis] - e[axis]) / max(1, abs(e[axis]))) }
            }
            XCTAssertLessThanOrEqual(worst, SkinningReferenceTests.tolerance, "parappa at \(time) s: worst relative error")
            let bind = mesh.floatValues(.position).map { values in
                stride(from: 0, to: values.count, by: 3).map { SIMD3<Double>(Double(values[$0]), Double(values[$0 + 1]),
                                                                             Double(values[$0 + 2])) }
            } ?? []
            if zip(expected, bind).contains(where: { simd_distance($0, $1) > 1e-3 }) { posed += 1 }
        }
        XCTAssertGreaterThan(posed, 0, "the clip moves the mesh off its bind pose")
    }
}
