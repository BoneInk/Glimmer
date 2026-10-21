import XCTest
import AppKit
@testable import OpenWallpaperEngine

/// `ShaderSourceMemo` hands back what parsing and folding the same text again would: the same
/// declarations, the same folded geometry stage, so the same plans and variant keys.
final class ShaderSourceMemoTests: XCTestCase {
    private let roots = [Fixtures.url("Particles"), ShaderVariantTests.weAssets]

    private func read(_ path: String) -> Data? {
        roots.lazy.compactMap { FileManager.default.contents(atPath: $0.appending(path: path).path) }.first
    }

    private func renderer(_ json: String) throws -> WEParticleRenderer {
        try JSONDecoder().decode(WEParticleRenderer.self, from: Data(json.utf8))
    }

    func testMemoizedSourceParsesAsTheLoaderDoes() throws {
        _ = try Fixtures.assets()
        let memo = ShaderSourceMemo()
        for stage in ShaderStage.allCases {
            let plain = try ShaderSourceLoader(readFile: read).load("genericparticle", stage: stage)
            let first = try ShaderSourceLoader(readFile: read, memo: memo).load("genericparticle", stage: stage)
            let second = try ShaderSourceLoader(readFile: read, memo: memo).load("genericparticle", stage: stage)
            for source in [first, second] {
                XCTAssertEqual(source.path, plain.path)
                XCTAssertEqual(source.text, plain.text)
                XCTAssertEqual(source.combos, plain.combos)
                XCTAssertEqual(source.uniforms.map { "\($0.type) \($0.name) \($0.arrayCount ?? 1)" },
                               plain.uniforms.map { "\($0.type) \($0.name) \($0.arrayCount ?? 1)" })
                XCTAssertEqual(source.uniforms.map { $0.annotation as NSDictionary },
                               plain.uniforms.map { $0.annotation as NSDictionary })
                XCTAssertEqual(source.preludeAnalysis.identifiers, plain.preludeAnalysis.identifiers)
            }
        }
        XCTAssertEqual(memo.counts.hits, ShaderStage.allCases.count)
        XCTAssertEqual(memo.counts.misses, ShaderStage.allCases.count)
    }

    func testMemoizedGeometryEmulationMatchesMake() throws {
        _ = try Fixtures.assets()
        let compiler = InProcessShaderCompiler()
        let sources = try XCTUnwrap(GeometryShaderEmulation.sources("genericropeparticle", readFile: read))
        let memo = ShaderSourceMemo()
        for combos in [["THICKFORMAT": 1, "TRAILSUBDIVISION": 4, "GS_ENABLED": 1],
                       ["THICKFORMAT": 1, "TRAILRENDERER": 1, "TRAILSUBDIVISION": 1, "GS_ENABLED": 1]] {
            let direct = try GeometryShaderEmulation.make(sources, combos: combos, compiler: compiler)
            for _ in 0..<2 {
                let memoized = try memo.geometryEmulation(sources, combos: combos, compiler: compiler)
                XCTAssertEqual(memoized.vertexText, direct.vertexText)
                XCTAssertEqual(memoized.maxVertexCountExpression, direct.maxVertexCountExpression)
                XCTAssertEqual(memoized.defines, direct.defines)
                XCTAssertEqual(memoized.restartsStrips, direct.restartsStrips)
            }
        }
        XCTAssertEqual(memo.counts.misses, 2)
        XCTAssertEqual(memo.counts.hits, 2)
    }

    /// A plan built from the memo's entries (the second build) has the first's stages and keys,
    /// and those match a translator that never planned before.
    func testPlansFromTheMemoMatchFreshPlans() throws {
        _ = try Fixtures.assets()
        func builder() -> ParticleMaterialPlanBuilder {
            ParticleMaterialPlanBuilder(translator: ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: nil),
                                        readFile: read, loadTexture: { _, _ in nil })
        }
        let shared = builder()
        for json in [#"{"name":"sprite"}"#, #"{"name":"spritetrail"}"#, #"{"name":"rope"}"#, #"{"name":"ropetrail","subdivision":4}"#] {
            func plan(_ builder: ParticleMaterialPlanBuilder) throws -> ParticleMaterialPlan {
                try builder.build(materialPath: "materials/solid.json", renderer: try renderer(json), flags: 0,
                                  baseTexture: .image(NSImage()), spriteSheet: nil)
            }
            let fresh = try plan(builder())
            let first = try plan(shared)
            let second = try plan(shared)
            for built in [first, second] {
                XCTAssertEqual(built.shader, fresh.shader, json)
                XCTAssertEqual(built.stages.map(\.geometry), fresh.stages.map(\.geometry), json)
                XCTAssertEqual(built.stages.map(\.variantKey), fresh.stages.map(\.variantKey), json)
                XCTAssertEqual(built.stages.map { $0.variant.textureSlots }, fresh.stages.map { $0.variant.textureSlots }, json)
                XCTAssertEqual(built.stages.map { $0.textures.keys.sorted() }, fresh.stages.map { $0.textures.keys.sorted() }, json)
            }
        }
        XCTAssertGreaterThan(shared.translator.sources.counts.hits, 0)
    }
}
