import XCTest
import Metal
@testable import OpenWallpaperEngine

final class ShaderVariantTests: XCTestCase {
    /// The WE assets from `OWE_ASSETS`; a path that doesn't exist without them, so tests that
    /// check for it skip (CI has none).
    static var weAssets: URL {
        WallpaperEngineAssets.directory ?? URL(fileURLWithPath: "/nonexistent/owe-assets", isDirectory: true)
    }

    private var translator: ShaderVariantTranslator!
    private var cache: URL!

    override func setUpWithError() throws {
        cache = FileManager.default.temporaryDirectory.appending(path: "owe-variants-\(UUID().uuidString)")
        translator = ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: cache)
    }

    override func tearDownWithError() throws {
        if let cache { try? FileManager.default.removeItem(at: cache) }
    }

    /// Builds a render pipeline the way the renderer will: vertex descriptor from the function's own
    /// attributes, streams in buffer 30.
    static func makePipeline(_ variant: TranslatedShaderVariant, device: MTLDevice) throws -> MTLRenderPipelineState {
        let vertexLibrary = try device.makeLibrary(source: variant.vertexMSL, options: nil)
        let fragmentLibrary = try device.makeLibrary(source: variant.fragmentMSL, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexLibrary.makeFunction(name: "main0")
        descriptor.fragmentFunction = fragmentLibrary.makeFunction(name: "main0")
        descriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
        let vertexDescriptor = MTLVertexDescriptor()
        for attribute in descriptor.vertexFunction?.vertexAttributes ?? [] where attribute.isActive {
            let index = attribute.attributeIndex
            vertexDescriptor.attributes[index].format = vertexFormat(attribute.attributeType)
            vertexDescriptor.attributes[index].offset = 0
            vertexDescriptor.attributes[index].bufferIndex = 30 - index
            vertexDescriptor.layouts[30 - index].stride = 16
        }
        descriptor.vertexDescriptor = vertexDescriptor
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    static func vertexFormat(_ type: MTLDataType) -> MTLVertexFormat {
        switch type {
        case .float: return .float
        case .float2: return .float2
        case .float3: return .float3
        case .uint4: return .uint4
        case .int4: return .int4
        default: return .float4
        }
    }

    func testFixtureIdiomsTranslateAndBuildPipeline() throws {
        let loader = ShaderSourceLoader(roots: [Fixtures.url("ShaderAssets")])
        let vertex = try loader.load("effects/test/shaders/effects/test", stage: .vertex)
        let fragment = try loader.load("effects/test/shaders/effects/test", stage: .fragment)
        let combos = ShaderVariantTranslator.resolveCombos(vertex: vertex, fragment: fragment, overrides: [], boundTextureSlots: [0])
        let variant = try translator.variant(vertex: vertex, fragment: fragment, combos: combos)
        XCTAssertEqual(variant.textureSlots, [0])
        XCTAssertEqual(variant.attributes["a_Position"], 0)
        XCTAssertNotNil(variant.uniforms?.members["g_ModelViewProjectionMatrix"])
        XCTAssertNoThrow(try Self.makePipeline(variant, device: try XCTUnwrap(MTLCreateSystemDefaultDevice())))
    }

    // MARK: - Dialect (M8): each case below comes from a library wallpaper that failed to translate.

    /// Translates `effects/dialect/shaders/effects/<name>` and builds its pipeline.
    private func translateDialectFixture(_ name: String) throws -> TranslatedShaderVariant {
        let loader = ShaderSourceLoader(roots: [Fixtures.url("ShaderAssets")])
        let path = "effects/dialect/shaders/effects/\(name)"
        let vertex = try loader.load(path, stage: .vertex)
        let fragment = try loader.load(path, stage: .fragment)
        let combos = ShaderVariantTranslator.resolveCombos(vertex: vertex, fragment: fragment, overrides: [], boundTextureSlots: [0])
        let variant = try translator.variant(vertex: vertex, fragment: fragment, combos: combos)
        XCTAssertNoThrow(try Self.makePipeline(variant, device: try XCTUnwrap(MTLCreateSystemDefaultDevice())))
        return variant
    }

    // MARK: - Names the engine supplies

    /// A pair from inline sources, its includes and combos parsed as for WE's files.
    private func inlinePair(vertex: String, fragment: String) throws -> (ShaderSource, ShaderSource) {
        let files = ["shaders/inline.vert": vertex, "shaders/inline.frag": fragment]
        let loader = ShaderSourceLoader(readFile: { files[$0].map { Data($0.utf8) } })
        return (try loader.load("inline", stage: .vertex), try loader.load("inline", stage: .fragment))
    }

    private static let inlineVertex = """
    attribute vec3 a_Position;
    attribute vec2 a_TexCoord;
    varying vec2 v_TexCoord;
    void main() { gl_Position = vec4(a_Position, 1.0); v_TexCoord = a_TexCoord; }
    """

    /// WE's macros for handing a texture to a function (`ApplyReflection`, `ApplyMorphPosition`).
    func testTextureParameterMacrosPassASampler() throws {
        let (vertex, fragment) = try inlinePair(vertex: Self.inlineVertex, fragment: """
        uniform sampler2D g_Texture0;
        varying vec2 v_TexCoord;
        vec4 Read(DECLARE_SAMPLER2D_PARAMETER(t), vec2 uv) { return texSample2D(t, uv); }
        void main() { gl_FragColor = Read(MAKE_SAMPLER2D_ARGUMENT(g_Texture0), v_TexCoord); }
        """)
        let variant = try translator.variant(vertex: vertex, fragment: fragment, combos: [:])
        XCTAssertEqual(variant.textureSlots, [0])
    }

    /// A sampler's combo is defined only while its texture is bound: `#ifdef NORMALMAP` fails
    /// without a normal map, as `generic3` and `genericparticle` expect.
    func testUnboundSamplerComboIsUndefined() throws {
        let (vertex, fragment) = try inlinePair(vertex: Self.inlineVertex, fragment: """
        uniform sampler2D g_Texture1; // {"combo":"NORMALMAP"}
        varying vec2 v_TexCoord;
        void main() {
        #ifdef NORMALMAP
            gl_FragColor = texSample2D(g_Texture1, v_TexCoord) * 0.25;
        #else
            gl_FragColor = vec4(v_TexCoord, 0.0, 0.75);
        #endif
        }
        """)
        let unbound = ShaderVariantTranslator.resolveCombos(vertex: vertex, fragment: fragment, overrides: [], boundTextureSlots: [0])
        XCTAssertEqual(unbound["NORMALMAP"], 0)
        XCTAssertNil(ShaderVariantTranslator.definedCombos(vertex: vertex, fragment: fragment, combos: unbound)["NORMALMAP"])
        XCTAssertTrue(try translator.variant(vertex: vertex, fragment: fragment, combos: unbound).fragmentMSL.contains("0.75"))
        let bound = ShaderVariantTranslator.resolveCombos(vertex: vertex, fragment: fragment, overrides: [], boundTextureSlots: [0, 1])
        XCTAssertTrue(try translator.variant(vertex: vertex, fragment: fragment, combos: bound).fragmentMSL.contains("0.25"))
    }

    /// A declared combo at 0 stays defined, sampler or not: WE defines every combo it resolves.
    func testDeclaredComboAtZeroStaysDefined() throws {
        let (vertex, fragment) = try inlinePair(vertex: Self.inlineVertex, fragment: """
        // [COMBO] {"combo":"MASK","default":0}
        uniform sampler2D g_Texture1; // {"combo":"MASK"}
        varying vec2 v_TexCoord;
        void main() { gl_FragColor = vec4(float(MASK)); }
        """)
        XCTAssertEqual(ShaderVariantTranslator.definedCombos(vertex: vertex, fragment: fragment, combos: ["MASK": 0])["MASK"], 0)
    }

    /// `TEX<n>FORMAT` is set for every `formatcombo` sampler with a texture, the slot's own or its
    /// default (`util/fur`, R8, for `fur4`'s `g_Texture8`), RGBA-loaded formats as
    /// `FORMAT_RGBA8888`.
    func testFormatCombosCoverDefaultTexturesAndRGBA() throws {
        func tex(_ format: UInt32) -> Data {
            var data = Data("TEXV0005\u{0}TEXI0001\u{0}".utf8)
            withUnsafeBytes(of: format.littleEndian) { data.append(contentsOf: $0) }
            data.append(Data(count: 16))
            return data
        }
        let files = ["materials/util/fur.tex": tex(9)]
        let builder = ImageMaterialPlanBuilder(translator: translator, readFile: { files[$0] }, loadTexture: { _, _ in nil })
        let samplers = ShaderSourceLoader.parseUniforms("""
        uniform sampler2D g_Texture1; // {"formatcombo":true}
        uniform sampler2D g_Texture8; // {"default":"util/fur","formatcombo":true}
        uniform sampler2D g_Texture9; // {"formatcombo":true}
        """)
        let headers = builder.formatHeaders(samplers, listed: [1: tex(0)], materialPath: "materials/m.json")
        XCTAssertEqual(ImageMaterialPlanBuilder.formatCombos(samplers, headers: headers),
                       ["TEX1FORMAT": 0, "TEX8FORMAT": 9])
        XCTAssertEqual(TEXImageFormat(rawValue: 1).formatComboValue, 0, "RGB888 loads as RGBA")
        XCTAssertEqual(TEXImageFormat(rawValue: 4).formatComboValue, 4, "DXT5 samples as stored")
    }

    /// Scalar splat, vector truncation, float→int, float `%`, float and packed-float4 array
    /// indices, `mix` of different sizes, a `vec4` sampling coordinate.
    func testHLSLImplicitConversionsTranslate() throws {
        _ = try translateDialectFixture("conversions")
    }

    /// A shader's own `M_PI`/`log10` replace the prelude's instead of clashing with them.
    func testShaderDefinitionsOverridePreludeMacros() throws {
        let prelude = ShaderPrelude.text(for: .fragment, combos: [:], source: "#define M_PI 3.14\nfloat log10(float x) { return x; }")
        XCTAssertFalse(prelude.contains("#define M_PI "))
        XCTAssertFalse(prelude.contains("#define log10(x)"))
        XCTAssertTrue(prelude.contains("#define M_PI_2 "))
        // Clear of metal::log10: renamed in the SPIR-V, not by the prelude.
        let variant = try translateDialectFixture("redefines")
        XCTAssertTrue(variant.fragmentMSL.contains("we_log10("), variant.fragmentMSL)
    }

    /// HLSL lets a vertex shader modify its inputs; GLSL doesn't.
    func testWrittenAttributeBecomesAGlobalCopy() {
        let vertex = "#version 450\nin vec2 a_TexCoord;\nout vec2 v_TexCoord;\nvoid main() {\n a_TexCoord *= 2.0;\n v_TexCoord = a_TexCoord;\n}\n"
        let fragment = "#version 450\nin vec2 v_TexCoord;\nout vec4 out_FragColor;\nvoid main() { out_FragColor = vec4(v_TexCoord, 0.0, 1.0); }\n"
        let pair = HLSLLinkage.link(vertex: vertex, fragment: fragment)
        XCTAssertTrue(pair.vertex.contains("layout(location = 1) in vec2 a_TexCoord_weIn;\nvec2 a_TexCoord;"), pair.vertex)
        XCTAssertTrue(pair.vertex.contains("a_TexCoord = a_TexCoord_weIn;"), pair.vertex)
        XCTAssertEqual(pair.attributes["a_TexCoord"], 1)
    }

    /// A header goes after a top-level `struct`, never inside its braces.
    func testIncludesAreNotInsertedInsideAStruct() {
        let text = "uniform float u;\nstruct Grid {\n vec2 id;\n};\nvoid main() {}\n"
        let offset = ShaderSourceLoader.includeInsertionOffset(in: text)
        XCTAssertEqual(offset, (text as NSString).range(of: "void main").location)
    }

    /// Locals and functions named with C++ keywords are renamed; a uniform keeps its name, since
    /// values bind to it by name.
    func testCppKeywordNamesCompileAndUniformsKeepTheirNames() throws {
        let variant = try translateDialectFixture("reserved")
        // `or` and `operator` are renamed in the SPIR-V (OpName); so is `this`, which GLSL reserves:
        // the prelude's `we_this` gets WE's name back there, which MSL can't take.
        for name in ["we_or", "we_operator", "we_this"] { XCTAssertTrue(variant.fragmentMSL.contains(name), name) }
        // A uniform named with a C++ keyword compiles and still binds by WE's name.
        let vertex = "#version 450\nlayout(location = 0) in vec4 p;\nvoid main() { gl_Position = p; }\n"
        let fragment = "#version 450\nuniform float new;\nlayout(location = 0) out vec4 o;\nvoid main() { o = vec4(new); }\n"
        let pair = try InProcessShaderCompiler().compilePairToMSL(vertex: vertex, fragment: fragment)
        XCTAssertTrue(pair.fragment.msl.contains("we_new"), pair.fragment.msl)
        XCTAssertNotNil(try ShaderVariantTranslator.uniformLayout(from: pair.fragment.reflection)?.members["new"])
        XCTAssertNoThrow(try MTLCreateSystemDefaultDevice()?.makeLibrary(source: pair.fragment.msl, options: nil))
    }

    func testUnmatchedEndifIsDropped() {
        let text = ShaderSourceLoader.dropUnmatchedEndifs(in: "#if A\n#endif\n#endif\n#ifdef B\n#endif")
        XCTAssertEqual(text, "#if A\n#endif\n// (unmatched) #endif\n#ifdef B\n#endif")
    }

    /// `vec4` out of the vertex stage, `vec2` into the fragment stage: Metal needs matching types.
    func testVaryingDeclaredWithDifferentSizesLinks() throws {
        let variant = try translateDialectFixture("varyings")
        XCTAssertTrue(variant.fragmentMSL.contains("float4 v_TexCoord_weVarying"), variant.fragmentMSL)
    }

    /// A varying may be named `a_…`: only the vertex stage's inputs are attributes.
    func testAVaryingNamedLikeAnAttributeLinks() throws {
        let variant = try translateDialectFixture("avaryings")
        XCTAssertEqual(variant.attributes.keys.sorted(), ["a_Position", "a_TexCoord"])
        XCTAssertTrue(variant.fragmentMSL.contains("a_TexCloudsCoord [[user(locn0)]]"), variant.fragmentMSL)
    }

    /// A header's own include is emitted before the header that uses it.
    func testNestedIncludesComeBeforeTheirIncluder() throws {
        let source = try ShaderSourceLoader(roots: [Fixtures.url("ShaderAssets")])
            .load("effects/dialect/shaders/effects/includes", stage: .fragment)
        let inner = try XCTUnwrap(source.text.range(of: "vec3 Inner("))
        let outer = try XCTUnwrap(source.text.range(of: "vec3 Outer("))
        XCTAssertLessThan(inner.lowerBound, outer.lowerBound)
        _ = try translateDialectFixture("includes")
    }

    func testShakeTexturesLandInTheirOwnSlots() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.weAssets.path), "WE install not present")
        let loader = ShaderSourceLoader(roots: [Self.weAssets])
        let path = "effects/shake/shaders/effects/shake"
        let vertex = try loader.load(path, stage: .vertex)
        let fragment = try loader.load(path, stage: .fragment)
        let combos = ShaderVariantTranslator.resolveCombos(vertex: vertex, fragment: fragment,
                                                           overrides: [["AUDIOPROCESSING": 1, "NOISE": 1]],
                                                           boundTextureSlots: [0, 1, 3])
        XCTAssertEqual(combos["MASK"], 1, "g_Texture3 is annotated combo MASK")
        let variant = try translator.variant(vertex: vertex, fragment: fragment, combos: combos)
        XCTAssertTrue(variant.fragmentMSL.contains("g_Texture1 [[texture(1)]]"), "slot must equal N")
        XCTAssertTrue(variant.fragmentMSL.contains("g_Texture3 [[texture(3)]]"))
        let spectrum = try XCTUnwrap(variant.uniforms?.members["g_AudioSpectrum16Left"])
        XCTAssertEqual(spectrum.count, 16)
        XCTAssertEqual(spectrum.arrayStride, 16, "std140 float arrays have a 16-byte stride")
        XCTAssertNoThrow(try Self.makePipeline(variant, device: try XCTUnwrap(MTLCreateSystemDefaultDevice())))
    }

    /// Every built-in effect pair, default combos: translate, compile MSL, build a pipeline.
    func testEveryBuiltinEffectPairBuildsAPipeline() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.weAssets.path), "WE install not present")
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let loader = ShaderSourceLoader(roots: [Self.weAssets])
        let effects = Self.weAssets.appending(path: "effects")
        var pairs: [String] = []
        for effect in try FileManager.default.contentsOfDirectory(atPath: effects.path).sorted() {
            let shaders = effects.appending(path: "\(effect)/shaders/effects")
            for file in (try? FileManager.default.contentsOfDirectory(atPath: shaders.path)) ?? [] where file.hasSuffix(".frag") {
                pairs.append("effects/\(effect)/shaders/effects/\(file.dropLast(5))")
            }
        }
        XCTAssertGreaterThanOrEqual(pairs.count, 68)
        var failures: [String] = []
        for path in pairs {
            do {
                let vertex = try loader.load(path, stage: .vertex)
                let fragment = try loader.load(path, stage: .fragment)
                let combos = ShaderVariantTranslator.resolveCombos(vertex: vertex, fragment: fragment, overrides: [], boundTextureSlots: [0])
                let variant = try translator.variant(vertex: vertex, fragment: fragment, combos: combos)
                _ = try Self.makePipeline(variant, device: device)
            } catch {
                failures.append("\(path): \(String(describing: error).prefix(300))")
            }
        }
        XCTAssertEqual(failures, [], "\(failures.count) of \(pairs.count) failed:\n" + failures.joined(separator: "\n"))
    }
}
