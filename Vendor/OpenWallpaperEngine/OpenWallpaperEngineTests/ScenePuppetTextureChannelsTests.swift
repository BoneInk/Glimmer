import XCTest
import Metal
import MetalKit
import simd
import OWESceneEditing
@testable import OpenWallpaperEngine

/// Puppet Warp texture channels against WE 2.8.42's own files (`Tests/Fixtures/Models/TextureChannels`:
/// the editor's rope puppet saved with Texture Channels off and with one channel on, a recoloured
/// rope cropped to x 16…80) and its RenderDoc capture: the `.mdl` gains a second mesh with flag 0x2
/// (the channel quad, stride 44), and the puppet samples the image with the channels drawn over
/// it, which at the default weight 0 is the image itself.
final class ScenePuppetTextureChannelsTests: XCTestCase {
    private static let folder = "Models/TextureChannels"

    private static func model(_ variant: String) throws -> MDLModel {
        try MDLReader.read(try Fixtures.data("\(folder)/models/rope_puppet_\(variant).mdl"))
    }

    // MARK: - MDLV

    /// The off variant: one mesh, the puppet's (stride 80), as every puppet before channels.
    func testTheOffVariantHasOnlyThePuppetMesh() throws {
        let model = try Self.model("off")
        XCTAssertEqual(model.meshes.count, 1)
        XCTAssertFalse(model.meshes[0].isTextureChannelMesh)
        XCTAssertEqual(model.meshes[0].format.stride, 80)
        XCTAssertEqual(model.end, 40226)
        XCTAssertEqual(model.trailingByteCount, 0)
    }

    /// The on variant: the u32 at 0x11 is the mesh count (1 → 2); the puppet's mesh is unchanged
    /// and the channel mesh follows it, before `MDLS0004`: its material, flags 0x2 with the row
    /// count 1, format 0x800021 (position @0, blend indices @12, `a_TexCoordVec4` @28, stride 44)
    /// and one quad over the crop, x 16…80 by y 0…512 in the image's pixels, y up.
    func testTheOnVariantAddsTheChannelMesh() throws {
        let off = try Self.model("off"), on = try Self.model("on")
        let bytes = try Fixtures.data("\(Self.folder)/models/rope_puppet_on.mdl")
        XCTAssertEqual(bytes[0x11], 2)
        XCTAssertEqual(on.meshes.count, 2)
        XCTAssertEqual(on.end, 40494)
        XCTAssertEqual(on.trailingByteCount, 0)
        XCTAssertEqual(on.meshes[0], off.meshes[0], "the puppet's mesh is the same")
        XCTAssertEqual(on.skeleton?.bones.map(\.name), off.skeleton?.bones.map(\.name))
        XCTAssertEqual(on.sections.map(\.tag), ["MDLS0004"])

        let channel = on.meshes[1]
        XCTAssertTrue(channel.isTextureChannelMesh)
        XCTAssertEqual(channel.materials, ["materials/rope_channelmap.json"])
        XCTAssertEqual(channel.flags, 2)
        XCTAssertEqual(channel.flagsExtra, 1, "BLENDROWCOUNT")
        XCTAssertEqual(channel.format.rawValue, 0x800021)
        XCTAssertEqual(channel.format.stride, 44)
        XCTAssertEqual(channel.format.elements.map(\.attribute.name), ["a_Position", "a_BlendIndices", "a_TexCoordVec4"])
        XCTAssertEqual(channel.format.elements.map(\.offset), [0, 12, 28])
        XCTAssertEqual(channel.vertexCount, 4)
        XCTAssertEqual(channel.indices, [0, 1, 2, 0, 2, 3])
        XCTAssertEqual(channel.floatValues(.position), [16, 512, 0, 80, 512, 0, 80, 0, 0, 16, 0, 0])
        XCTAssertEqual(channel.unsignedValues(.blendIndices), [UInt32](repeating: 0, count: 16), "every corner names channel 0")
        // xy: the atlas, v down from the crop's top; zw: the base image (16/96 … 80/96).
        let texCoords = try XCTUnwrap(channel.floatValues(XCTUnwrap(MDLVertexAttribute.named("a_TexCoordVec4"))))
        let expected: [Float] = [0, 0, 1 / 6, 0, 1, 0, 5 / 6, 0, 1, 1, 5 / 6, 1, 0, 1, 1 / 6, 1]
        for (value, want) in zip(texCoords, expected) { XCTAssertEqual(value, want, accuracy: 1e-6) }
        XCTAssertNil(channel.extraPositions)
        XCTAssertNil(channel.vector4Block)
        XCTAssertEqual(channel.groups, [])
    }

    // MARK: - Wallpaper Editor

    /// The Wallpaper Editor lists the channels (read only) and writes their mesh back byte for
    /// byte, with the clips' channel tracks, one sample a frame.
    func testTheEditorKeepsTheChannels() throws {
        let source = try Self.model("on")
        var document = try PuppetMDLReader.read(try Fixtures.data("\(Self.folder)/models/rope_puppet_on.mdl"),
                                                imageSize: SIMD2(96, 512))
        let channels = try XCTUnwrap(document.preserved.textureChannels)
        XCTAssertEqual(channels.map(\.material), ["materials/rope_channelmap.json"])
        XCTAssertEqual(channels.map(\.blendRows), [1])
        XCTAssertEqual(channels.map(\.channelCount), [1])
        XCTAssertNil(try PuppetMDLReader.read(try Fixtures.data("\(Self.folder)/models/rope_puppet_off.mdl"),
                                              imageSize: SIMD2(96, 512)).preserved.textureChannels)

        let clip = document.addClip(named: "blink", fps: 10, frames: 4)
        document.clips[clip].channelTracks = [PuppetChannelTrack(tag: 0, samples: [0, 1, 1])]
        let written = try MDLReader.read(try PuppetMDLWriter.write(document))
        XCTAssertEqual(written.meshes.count, 2)
        XCTAssertEqual(written.meshes[1], source.meshes[1], "the channel mesh as it was")
        let tracks = try XCTUnwrap(written.animations?.first?.scalarTracksA)
        XCTAssertEqual(tracks.map(\.samples), [[0, 1, 1, 1, 1]], "frames + 1 samples, the last held")
    }

    // MARK: - Weights

    /// The channel weights (`g_BlendMap`) start at 0 and come from the clips' first scalar list,
    /// one track per channel, as the puppet update lays layers over them (0x1401fefa0…).
    func testAnimationLayersSetTheChannelWeights() throws {
        let skeleton = MDLSkeleton(version: 1, bones: [
            MDLBone(name: "b0", flags: 1, parent: 0xFFFF_FFFF, matrix: matrix_identity_float4x4, properties: ""),
        ])
        var clip = SceneAnimationLayersTests.clip(id: 1, fps: 10, frames: 10, pose: SceneAnimationLayersTests.still())
        // Channel 0 ramps 0 → 1 over the clip, channel 1 holds 0.5.
        clip.scalarTracksA = [
            .init(tag: 0, samples: (0...10).map { Float($0) / 10 }),
            .init(tag: 0, samples: Array(repeating: 0.5, count: 11)),
        ]
        let still = ScenePuppetAnimator(skeleton: skeleton, clips: [clip], layers: [])
        still.advance(delta: 0.1, values: EmptySceneValues())
        XCTAssertEqual(still.pose.blendMap.prefix(2), [0, 0], "no layer: every channel 0")

        let layers = try JSONDecoder().decode([WEAnimationLayer].self, from: Data(#"[{"animation": 1}]"#.utf8))
        let animator = ScenePuppetAnimator(skeleton: skeleton, clips: [clip], layers: layers)
        animator.advance(delta: 0.25, values: EmptySceneValues())     // frame 2.5
        XCTAssertEqual(animator.pose.blendMap[0], 0.25, accuracy: 1e-5)
        XCTAssertEqual(animator.pose.blendMap[1], 0.5, accuracy: 1e-5)
        XCTAssertEqual(animator.pose.blendMap.count, SceneAnimationLayerStack.maximumTextureChannels)

        // A layer at weight ½ lerps from what the channel holds; an additive one adds value · w.
        var held = clip
        held.scalarTracksA = [.init(tag: 0, samples: Array(repeating: 0.5, count: 11)), .init(tag: 0, samples: Array(repeating: 0.5, count: 11))]
        let stack = SceneAnimationLayerStack(skeleton: SceneSkeleton(skeleton), clips: [held])
        var layer = SceneAnimationLayer(key: 0, name: "", clip: 0, animation: held, blend: 0.5)
        var channels: [Float] = [1, 0]
        stack.applyChannels(layer, weight: 0.5, to: &channels)
        XCTAssertEqual(channels, [0.75, 0.25])
        layer.additive = true
        stack.applyChannels(layer, weight: 0.5, to: &channels)
        XCTAssertEqual(channels, [1, 0.5])
    }

    // MARK: - Rendering

    /// The channels' plan: the second mesh through `puppettexturechannels` with `BLENDROWCOUNT` 1
    /// and without `DOUBLEBUFFERED` (WE's capture), the atlas in slot 0 and the base in slot 1,
    /// and its vertices at the offsets the translated stage reads.
    func testTheChannelPlanReadsTheMeshThroughWEsShader() throws {
        let rig = try Rig()
        let plan = try rig.plan("on")
        let channels = try XCTUnwrap(plan.channels)
        XCTAssertNil(try rig.plan("off").channels)
        XCTAssertEqual(channels.blendRows, 1)
        XCTAssertEqual(channels.channelCount, 1)
        XCTAssertFalse(channels.isDoubleBuffered)
        let variant = try XCTUnwrap(channels.material.pass.variant)
        XCTAssertEqual(variant.combos["BLENDROWCOUNT"], 1)
        // Without DOUBLEBUFFERED only the atlas is sampled; the base's slot needs nothing bound.
        guard case .asset(let atlas, _) = channels.material.pass.textures[0] else {
            return XCTFail("the atlas is the material's own texture")
        }
        XCTAssertTrue(atlas.hasSuffix("|rope_channelmap"))
        XCTAssertNotNil(variant.uniforms?.members["g_BlendMap"])

        let (vertexLibrary, _) = try variant.makeLibraries(device: rig.device)
        let vertex = try XCTUnwrap(vertexLibrary.makeFunction(name: "main0"))
        let descriptor = ScenePuppetRenderer.vertexDescriptor(for: vertex, attributes: variant.attributes, format: channels.format)
        func element(_ name: String) throws -> MTLVertexAttributeDescriptor {
            try XCTUnwrap(descriptor.attributes[try XCTUnwrap(variant.attributes[name])])
        }
        XCTAssertEqual(try element("a_Position").offset, 0)
        XCTAssertEqual(try element("a_Position").format, .float3)
        XCTAssertEqual(try element("a_BlendIndices").offset, 12)
        XCTAssertEqual(try element("a_BlendIndices").format, .uint4)
        XCTAssertEqual(try element("a_TexCoordVec4").offset, 28)
        XCTAssertEqual(try element("a_TexCoordVec4").format, .float4)
        XCTAssertEqual(descriptor.layouts[ScenePuppetRenderer.meshBuffer].stride, 44)
    }

    /// At the default weight 0 the on variant draws exactly as the off one (WE's stills and its
    /// capture, whose target is the image); at weight 1 the channel replaces the rope where the
    /// atlas maps (x 16…80) and nothing else changes.
    func testTheChannelShowsOnlyWhereTheAtlasMapsAndOnlyWhenWeighted() throws {
        let rig = try Rig()
        let off = try rig.plan("off"), on = try rig.plan("on")
        let channels = try XCTUnwrap(on.channels)
        XCTAssertTrue(rig.renderer.waitUntilReady(off) && rig.renderer.waitUntilReady(on), "the mesh pipelines compile")
        XCTAssertTrue(rig.renderer.channels.waitUntilReady(channels), "the channel pipeline compiles")

        let offPixels = try rig.draw(off, layer: "off", blendMap: [])
        let defaultPixels = try rig.draw(on, layer: "on", blendMap: [])
        let zeroPixels = try rig.draw(on, layer: "on", blendMap: [0, 0, 0, 0])
        XCTAssertEqual(defaultPixels, offPixels, "weight 0: the image as it is")
        XCTAssertEqual(zeroPixels, offPixels)
        XCTAssertEqual(rig.renderer.channels.drawsEncoded, 0, "nothing to draw at weight 0")

        let channelPixels = try rig.draw(on, layer: "on", blendMap: [1, 0, 0, 0])
        XCTAssertEqual(rig.renderer.channels.drawsEncoded, 1)
        let atlas = try rig.picture("rope_channelmap")
        let width = 96
        var changedOutside = 0, inside = 0, matching = 0
        for y in 0..<512 {
            for x in 0..<width {
                let at = (y * width + x) * 4
                let before = Array(offPixels[at..<at + 4]), after = Array(channelPixels[at..<at + 4])
                if (16..<80).contains(x) {
                    // Where the puppet's mesh covers the image, it shows the atlas's texel.
                    guard before[3] == 255 else { continue }
                    inside += 1
                    let texel = (y * 64 + (x - 16)) * 4
                    let want = Array(atlas[texel..<texel + 3])
                    if zip(after.prefix(3), want).allSatisfy({ abs(Int($0) - Int($1)) <= 2 }) { matching += 1 }
                } else if before != after {
                    changedOutside += 1
                }
            }
        }
        XCTAssertGreaterThan(inside, 64 * 400, "the rope covers most of the crop")
        XCTAssertEqual(matching, inside, "the channel's colours where the atlas maps")
        XCTAssertEqual(changedOutside, 0, "nothing changes outside the crop")
        // The rope's orange (250, 200, 70) became the channel's (70, 250, 200).
        let middle = (256 * width + 48) * 4
        XCTAssertEqual(Array(offPixels[middle..<middle + 3]), [250, 200, 70])
        XCTAssertEqual(Array(channelPixels[middle..<middle + 3]), [70, 250, 200])

        // The weights back to 0: the image again. Back at 1, the drawing at 1 is kept, not redrawn.
        XCTAssertEqual(try rig.draw(on, layer: "on", blendMap: [0, 0, 0, 0]), offPixels)
        XCTAssertEqual(try rig.draw(on, layer: "on", blendMap: [1, 0, 0, 0]), channelPixels)
        XCTAssertEqual(rig.renderer.channels.drawsEncoded, 1)
    }

    /// The fixture's rig, WE's shaders and the renderer.
    private final class Rig {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let renderer: ScenePuppetRenderer
        let builder: ImageMaterialPlanBuilder
        private let cache: URL
        private let loader: MTKTextureLoader
        private var textures: [String: MTLTexture] = [:]

        init() throws {
            let assets = try Fixtures.assets()
            try XCTSkipUnless(FileManager.default.fileExists(atPath: assets.appending(path: "shaders/puppettexturechannels.vert").path),
                              "WE's puppettexturechannels shader missing")
            device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
            queue = try XCTUnwrap(device.makeCommandQueue())
            loader = MTKTextureLoader(device: device)
            renderer = try XCTUnwrap(ScenePuppetRenderer(device: device, archive: nil))
            cache = FileManager.default.temporaryDirectory.appending(path: "owe-puppet-channels-\(UUID().uuidString)")
            let roots = [Fixtures.url(ScenePuppetTextureChannelsTests.folder), assets]
            func read(_ path: String) -> Data? {
                for root in roots {
                    if let data = FileManager.default.contents(atPath: root.appending(path: path).path) { return data }
                }
                return nil
            }
            builder = ImageMaterialPlanBuilder(
                translator: ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: cache),
                readFile: read,
                loadTexture: { name, _ in
                    read("materials/\(name).tex").flatMap { TEXParser(data: $0).extractImage() }.map { .image($0) }
                })
        }

        deinit { try? FileManager.default.removeItem(at: cache) } // scratch cleanup

        func plan(_ variant: String) throws -> ScenePuppetPlan {
            let image = try XCTUnwrap(builder.loadTexture("rope", "materials/rope.json"))
            return try ScenePuppetPlan.make(model: try ScenePuppetTextureChannelsTests.model(variant),
                                            rigPath: "models/rope_puppet_\(variant).mdl", materialPath: "materials/rope.json",
                                            source: image, imageSize: SIMD2(96, 512), builder: builder)
        }

        func texture(_ name: String) throws -> MTLTexture {
            if let made = textures[name] { return made }
            guard case .image(let image) = try XCTUnwrap(builder.loadTexture(name, "materials/rope.json")),
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw XCTSkip("\(name).tex doesn't decode to an image")
            }
            let made = try SceneTextureUpload.texture(from: cgImage, loader: loader, device: device)
            textures[name] = made
            return made
        }

        /// The texture's texels, RGBA8 rows from the top.
        func picture(_ name: String) throws -> [UInt8] { try ScenePuppetTestSupport.rgba8(try texture(name), device: device) }

        /// The puppet's albedo in its bind pose with the channels at `blendMap`.
        func draw(_ plan: ScenePuppetPlan, layer: String, blendMap: [Float]) throws -> [UInt8] {
            var pose = ScenePuppetPose.bind(boneCount: plan.boneCount)
            pose.blendMap = blendMap
            let commands = try XCTUnwrap(queue.makeCommandBuffer())
            let target = try XCTUnwrap(renderer.albedo(plan, ScenePuppetRenderer.Draw(
                layerID: layer, source: try texture("rope"), pose: pose, frame: BuiltinFrameContext(),
                values: EmptySceneValues(), assetTexture: { [unowned self] key, _ in
                    try? self.texture(String(key.split(separator: "|").last ?? "")) // test lookup; nil fails the draw
                }), commandBuffer: commands))
            commands.commit()
            commands.waitUntilCompleted()
            return try ScenePuppetTestSupport.rgba8(target, device: device)
        }
    }
}
