import XCTest
import Metal
@testable import OpenWallpaperEngine

/// WE's geometry stages folded into their vertex stage (`GeometryShaderEmulation`), translated
/// with the linked toolchain and built into Metal pipelines.
final class GeometryShaderEmulationTests: XCTestCase {
    private let root = ShaderVariantTests.weAssets

    private func readFile(_ path: String) -> Data? {
        FileManager.default.contents(atPath: root.appending(path: path).path)
    }

    private func translate(_ shader: String, combos: [String: Int]) throws -> (TranslatedShaderVariant, GeometryShaderEmulation) {
        let sources = try XCTUnwrap(try GeometryShaderEmulation.sources(shader, readFile: readFile))
        let compiler = InProcessShaderCompiler()
        func serve(_ path: String, _ text: String) throws -> ShaderSource {
            try ShaderSourceLoader(readFile: { $0 == path ? Data(text.utf8) : self.readFile($0) }).load(path, stage: .vertex)
        }
        let declarations = try serve("shaders/\(shader)+declarations.vert", sources.declarations)
        let fragment = try ShaderSourceLoader(readFile: readFile).load(shader, stage: .fragment)
        let resolved = ShaderVariantTranslator.resolveCombos(vertex: declarations, fragment: fragment,
                                                             overrides: [combos], boundTextureSlots: [0])
        let emulation = try GeometryShaderEmulation.make(sources, combos: resolved, compiler: compiler)
        let vertex = try serve("shaders/\(shader)+geom.vert", emulation.vertexText)
        let translator = ShaderVariantTranslator(compiler: compiler, cacheDirectory: nil)
        return (try translator.variant(vertex: vertex, fragment: fragment, combos: resolved), emulation)
    }

    private func assertBuildsPipeline(_ variant: TranslatedShaderVariant, file: StaticString = #filePath, line: UInt = #line) throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let vertexLibrary = try device.makeLibrary(source: variant.vertexMSL, options: nil)
        let fragmentLibrary = try device.makeLibrary(source: variant.fragmentMSL, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        let vertex = try XCTUnwrap(vertexLibrary.makeFunction(name: "main0"))
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragmentLibrary.makeFunction(name: "main0")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.vertexDescriptor = EffectGraphRenderer.vertexDescriptor(for: vertex)
        XCTAssertNoThrow(try device.makeRenderPipelineState(descriptor: descriptor), file: file, line: line)
        XCTAssertTrue(variant.vertexMSL.contains("[[vertex_id]]"), "the corner comes from the vertex id", file: file, line: line)
    }

    func testGenericParticleGeometryCompilesForEveryRendererForm() throws {
        _ = try Fixtures.assets()
        for combos in [["GS_ENABLED": 1],
                       ["GS_ENABLED": 1, "THICKFORMAT": 1, "TRAILRENDERER": 1],
                       ["GS_ENABLED": 1, "THICKFORMAT": 1, "SPRITESHEET": 1, "SPRITESHEETBLEND": 1],
                       ["GS_ENABLED": 1, "REFRACT": 1]] {
            let (variant, emulation) = try translate("genericparticle", combos: combos)
            XCTAssertEqual(try emulation.maxVertexCount(combos: combos), 4)
            XCTAssertEqual(try emulation.vertexCountPerInstance(combos: combos), 6)
            try assertBuildsPipeline(variant)
            XCTAssertNotNil(variant.attributes["a_TexCoordVec4"], "\(combos)")
        }
    }

    func testRopeGeometryCountsSubdivisions() throws {
        _ = try Fixtures.assets()
        for subdivision in [0, 3] {
            let combos = ["GS_ENABLED": 1, "THICKFORMAT": 1, "TRAILSUBDIVISION": subdivision]
            let (variant, emulation) = try translate("genericropeparticle", combos: combos)
            XCTAssertEqual(try emulation.maxVertexCount(combos: combos), 4 + subdivision * 2)
            try assertBuildsPipeline(variant)
        }
        // Without the combo the shader's own `#define TRAILSUBDIVISION 0` applies.
        let (_, emulation) = try translate("genericropeparticle", combos: ["GS_ENABLED": 1])
        XCTAssertEqual(try emulation.maxVertexCount(combos: [:]), 4)
    }

    func testWEGeometryStagesDrawEachStripVertexOnce() throws {
        _ = try Fixtures.assets()
        for shader in ["genericparticle", "genericropeparticle", "flatpoint"] {
            let (_, emulation) = try translate(shader, combos: ["GS_ENABLED": 1])
            XCTAssertFalse(emulation.restartsStrips, "\(shader) never restarts its strip")
            XCTAssertFalse(emulation.vertexText.contains("owe_gs_restartStrip"), shader)
        }
    }

    func testStripIndicesKeepTheStripWinding() {
        let quad: [UInt32] = [0, 1, 2, 2, 1, 3]
        XCTAssertEqual(GeometryShaderEmulation.stripIndices(vertices: 4), quad)
        let six: [UInt32] = [0, 1, 2, 2, 1, 3, 2, 3, 4, 4, 3, 5]
        XCTAssertEqual(GeometryShaderEmulation.stripIndices(vertices: 6), six)
        let list: [UInt32] = [0, 1, 2, 3, 4, 5]
        XCTAssertEqual(GeometryShaderEmulation.listIndices(count: 6), list)
        XCTAssertEqual(ParticleMaterialPlan.Stage.Geometry.expandedQuads.indices, quad, "a quad is a 4-vertex strip")
        XCTAssertEqual(ParticleMaterialPlan.Stage.Geometry.emulated(vertexCount: 12).indices, six)
        XCTAssertEqual(ParticleMaterialPlan.Stage.Geometry.emulated(vertexCount: 6, restartsStrips: true).indices, list)
    }

    func testFlatPointGeometryCompiles() throws {
        _ = try Fixtures.assets()
        let (variant, _) = try translate("flatpoint", combos: ["GS_ENABLED": 1])
        try assertBuildsPipeline(variant)
    }

    func testShadersWithoutGeometryStageAreNotEmulated() throws {
        XCTAssertNil(try GeometryShaderEmulation.sources("genericimage2", readFile: readFile))
    }

    func testNonPointInputIsReported() {
        let geometry = "[input:triangles]\nin vec4 gl_Position;\nout vec4 gl_Position;\n[maxvertexcount(3)]\nvoid main() {}"
        XCTAssertThrowsError(try GeometryShaderEmulation.combine(vertex: "void main() {}", geometry: geometry, path: "x.geom"))
    }

    func testRestartStripAndCustomEmitCountsTranslate() throws {
        // A workshop-style geometry stage: two separate quads per point through RestartStrip.
        let vertex = """
        attribute vec3 a_Position;
        attribute vec4 a_Color;
        varying vec4 v_Color;
        void main() {
            gl_Position = vec4(a_Position, 1.0);
            v_Color = a_Color;
        }
        """
        let geometry = """
        in vec4 v_Color;
        in vec4 gl_Position;
        out vec4 v_Color;
        out vec4 gl_Position;
        [maxvertexcount(8)]
        void main() {
            PS_INPUT v;
            v.v_Color = IN[0].v_Color;
            for (int q = 0; q < 2; ++q) {
                for (int c = 0; c < 4; ++c) {
                    v.gl_Position = IN[0].gl_Position + vec4(float(q) * 2.0 + float(c / 2), float(c - (c / 2) * 2), 0.0, 0.0);
                    OUT.Append(v);
                }
                OUT.RestartStrip();
            }
        }
        """
        let emulation = try GeometryShaderEmulation.combine(vertex: vertex, geometry: geometry, path: "custom.geom")
        XCTAssertEqual(try emulation.vertexCountPerInstance(combos: [:]), 18)
        XCTAssertTrue(emulation.restartsStrips, "drawn one vertex per list entry")
        let path = "shaders/custom+geom.vert"
        let fragmentText = "varying vec4 v_Color;\nvoid main() { gl_FragColor = v_Color; }"
        let loader = ShaderSourceLoader(readFile: { name in
            name == path ? Data(emulation.vertexText.utf8) : (name.hasSuffix(".frag") ? Data(fragmentText.utf8) : nil)
        })
        let translator = ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: nil)
        let variant = try translator.variant(vertex: try loader.load(path, stage: .vertex),
                                             fragment: try loader.load("shaders/custom", stage: .fragment), combos: [:])
        try assertBuildsPipeline(variant)
    }

    func testMaxVertexCountExpressions() {
        XCTAssertEqual(GeometryShaderEmulation.evaluate("4 + TRAILSUBDIVISION * 2", values: ["TRAILSUBDIVISION": 3]), 10)
        XCTAssertEqual(GeometryShaderEmulation.evaluate("(2 + N) * 3 - 1", values: ["N": 2]), 11)
        XCTAssertEqual(GeometryShaderEmulation.evaluate("UNKNOWN + 4", values: [:]), 4)
        XCTAssertNil(GeometryShaderEmulation.evaluate("4 +", values: [:]))
        XCTAssertNil(GeometryShaderEmulation.evaluate("4 / 0", values: [:]))
    }
}


