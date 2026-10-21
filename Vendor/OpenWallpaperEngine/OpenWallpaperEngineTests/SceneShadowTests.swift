import XCTest
import AppKit
import Metal
import simd
@testable import OpenWallpaperEngine

/// Shadows' CPU side (docs/models-plan.md §2.10, §4.3 M8): WE's shelf packer against
/// hand-derived rectangles, the directional cascades' boxes, snap and matrices, a point light's
/// faces against `CalculateProjectedCoordsPoint` (`common_pbr_2.h`, ported below), the packer's
/// `g_LFeature_*` values, the batches, and the shadow variants' translation.
final class SceneShadowTests: XCTestCase {
    // MARK: - The atlas layout

    private func pack(_ maps: [(Int, Bool)]) -> (placements: [SIMD2<Int>], extent: SIMD2<Int>) {
        let layout = SceneShadowAtlasLayout.pack(maps.map { SceneShadowAtlasLayout.Map(size: $0.0, isPoint: $0.1) })
        return (layout.placements.map { SIMD2($0.x, $0.y) }, layout.extent)
    }

    /// Points first, then larger maps, left to right along the first shelf.
    func testPointsGoFirstAlongTheFirstShelf() {
        let layout = pack([(256, false), (256, true), (256, true)])
        XCTAssertEqual(layout.placements, [SIMD2(512, 0), SIMD2(0, 0), SIMD2(256, 0)])
        XCTAssertEqual(layout.extent, SIMD2(768, 256))
        let mixed = pack([(256, false), (512, false), (1024, false), (256, true)])
        XCTAssertEqual(mixed.placements, [SIMD2(1792, 0), SIMD2(1280, 0), SIMD2(256, 0), SIMD2(0, 0)])
        XCTAssertEqual(mixed.extent, SIMD2(2048, 1024), "not a power of two, as tall as the tallest")
    }

    /// Eight 1024 maps fill the 8192-wide shelf; the ninth rises on the shelf left above the first
    /// map, which the walk reaches before the full-width shelf its miss appended.
    func testAFullShelfSendsTheNextMapAboveTheFirst() {
        let layout = pack(Array(repeating: (1024, false), count: 9))
        XCTAssertEqual(layout.placements, (0..<8).map { SIMD2($0 * 1024, 0) } + [SIMD2(0, 1024)])
        XCTAssertEqual(layout.extent, SIMD2(8192, 2048))
        // The tenth goes over the second map: the walk passes the first column, now full.
        let ten = pack(Array(repeating: (1024, false), count: 10))
        XCTAssertEqual(ten.placements[9], SIMD2(1024, 1024))
    }

    /// A smaller map after a larger one goes on along the same shelf; nothing is at least 2×2.
    func testSmallerMapsFollowAndTheAtlasIsAtLeastTwoTexels() {
        let layout = pack([(256, false), (512, false)])
        XCTAssertEqual(layout.placements, [SIMD2(512, 0), SIMD2(0, 0)])
        XCTAssertEqual(layout.extent, SIMD2(768, 512))
        XCTAssertEqual(pack([]).extent, SIMD2(2, 2))
    }

    /// The atlas only grows: a frame needing less keeps the larger size, and the transforms are
    /// the rectangles over it.
    func testTheAtlasNeverShrinksAndTransformsAreItsRectangles() {
        var frame = SceneShadowFrame(maps: [
            SceneShadowMap(kind: .spot, lightID: "a", size: 256, renderViews: [], transformIndex: 0),
            SceneShadowMap(kind: .spot, lightID: "b", size: 256, renderViews: [], transformIndex: 1),
        ])
        frame.layOut(minimumExtent: SIMD2(1024, 128))
        XCTAssertEqual(frame.extent, SIMD2(1024, 256))
        XCTAssertEqual(frame.maps[1].origin, SIMD2(256, 0))
        XCTAssertEqual(frame.maps[1].transform(extent: frame.extent), SIMD4(0.25, 0, 0.25, 1))
        XCTAssertEqual(SceneShadowAtlas.mapSize(quality: 1), 256)
        XCTAssertEqual(SceneShadowAtlas.mapSize(quality: 2), 256)
        XCTAssertEqual(SceneShadowAtlas.mapSize(quality: 3), 512)
        XCTAssertEqual(SceneShadowAtlas.mapSize(quality: 4), 1024)
    }

    /// "Cheaper shadows" halves each map, never below 128, keeping the settings' order; old
    /// settings without the key keep it on.
    func testCheaperShadowsHalveTheMaps() throws {
        XCTAssertEqual([1, 2, 3, 4].map { SceneShadowAtlas.mapSize(quality: $0, reduced: true) }, [128, 128, 256, 512])
        let old = try JSONDecoder().decode(GlobalSettings.self, from: Data("{}".utf8))
        XCTAssertTrue(old.cheaperShadows)
        XCTAssertTrue(SceneRenderSettings(old).cheaperShadows)
        XCTAssertFalse(SceneRenderSettings().cheaperShadows)
    }

    /// Each point light's six faces are one batch; the other maps go six views at a time.
    func testBatchesPutEachPointAloneAndSixViewsTogether() {
        let view = matrix_identity_float4x4
        var maps = (0..<7).map { SceneShadowMap(kind: .spot, lightID: "s\($0)", size: 256, renderViews: [view], transformIndex: $0) }
        maps.append(SceneShadowMap(kind: .point, lightID: "p", size: 256, renderViews: Array(repeating: view, count: 6),
                                   transformIndex: 0))
        let batches = SceneShadowPass.batches(maps)
        XCTAssertEqual(batches.map(\.views.count), [6, 6, 1])
        XCTAssertEqual(batches[0].viewports, maps[7].viewports, "the point first")
        XCTAssertEqual(maps[7].viewports.map { SIMD2($0.z, $0.w) }, Array(repeating: SIMD2(128, 85), count: 6))
    }

    // MARK: - Directional cascades

    /// A light shining straight down (row 0 = −Y) with rows 1 and 2 along +X and +Z.
    private static let downward = simd_float4x4(columns: (SIMD4(0, -1, 0, 0), SIMD4(1, 0, 0, 0), SIMD4(0, 0, 1, 0),
                                                           SIMD4(4, 20, -3, 1)))

    /// §2.10's cascades: (b, d) = (c0, 4·c1), (c1, 4·c1), (c2, max(1.5·c2, 4·c1)); the centre
    /// `eye + F′·b/2` with `F′ = F − ½(F·L)L`, snapped to b / size along the light's rows 1 and 2;
    /// the box ±b/2 across, ±d/2 along the light, depth 1 toward it.
    func testCascadeBoxesSnapAndMatrices() {
        XCTAssertEqual(SceneShadowViews.cascadePairs(SIMD3(3, 10, 100)), [SIMD2(3, 40), SIMD2(10, 40), SIMD2(100, 150)])
        XCTAssertEqual(SceneShadowViews.cascadePairs(SIMD3(2, 3, 5)), [SIMD2(2, 12), SIMD2(3, 12), SIMD2(5, 12)])
        let eye = SIMD3<Float>(0.3, 2, 5.7)
        let forward = simd_normalize(SIMD3<Float>(0.2, -0.5, -1))
        let size = 512
        let cascades = SceneShadowViews.cascades(world: Self.downward, distances: SIMD3(3, 10, 100), mapSize: size,
                                                 eye: eye, forward: forward, orthographic: false)
        XCTAssertEqual(cascades.count, 3)
        let light = SIMD3<Float>(0, -1, 0)
        let spread = forward - 0.5 * simd_dot(forward, light) * light
        for (pair, matrix) in zip(SceneShadowViews.cascadePairs(SIMD3(3, 10, 100)), cascades) {
            let texel = pair.x / Float(size)
            var centre = eye + spread * pair.x / 2
            centre.x -= fmodf(centre.x, texel)
            centre.z -= fmodf(centre.z, texel)
            func project(_ p: SIMD3<Float>) -> SIMD3<Float> {
                let clip: SIMD4<Float> = matrix * SIMD4<Float>(p, 1)
                return SIMD3(clip.x, clip.y, clip.z) / clip.w
            }
            Self.assertNear(project(centre), SIMD3(0, 0, 0.5), 1e-4, "the snapped centre is the box's middle")
            // x̂ = row 2 (+Z), ŷ = row 1 (+X), toward the light = −row 0 (+Y).
            Self.assertNear(project(centre + SIMD3(0, 0, pair.x / 2)), SIMD3(1, 0, 0.5), 1e-4, "+x edge")
            Self.assertNear(project(centre + SIMD3(pair.x / 2, 0, 0)), SIMD3(0, 1, 0.5), 1e-4, "+y edge")
            Self.assertNear(project(centre + SIMD3(0, pair.y / 2, 0)), SIMD3(0, 0, 1), 1e-4, "nearest the light")
            Self.assertNear(project(centre - SIMD3(0, pair.y / 2, 0)), SIMD3(0, 0, 0), 1e-4, "farthest")
        }
        // An orthographic scene's centre lies at z = 0 before the snap (which keeps it there).
        let ortho = SceneShadowViews.cascades(world: Self.downward, distances: SIMD3(3, 10, 100), mapSize: size,
                                              eye: SIMD3(960, 540, 2000), forward: SIMD3(0, 0, -1), orthographic: true)
        let middle: SIMD4<Float> = ortho[0].inverse * SIMD4<Float>(0, 0, 0.5, 1)
        XCTAssertEqual(middle.z / middle.w, 0, accuracy: 1e-3)
        XCTAssertEqual(middle.y / middle.w, 540, accuracy: 1e-2, "no snap along the light")
        XCTAssertEqual(middle.x / middle.w, 960, accuracy: 3.0 / 512 + 1e-2)
    }

    // MARK: - Point faces

    /// `CalculateProjectedCoordsPoint` as WE's shader has it (`common_pbr_2.h`): the face by the
    /// largest component of `world − origin`, its view, the projection from `projectionInfo`,
    /// and the atlas coordinates of the face in the light's cell.
    private static func calculateProjectedCoordsPoint(_ world: SIMD3<Float>, origin o: SIMD3<Float>, info: SIMD4<Float>,
                                                      transform: SIMD4<Float>, quality: Int) -> (face: Int, coords: SIMD3<Float>) {
        let delta = world - o, a = simd_abs(delta)
        let scale = SIMD2<Float>(0.5, 0.3333)
        let compensation: Float = quality <= 2 ? 0.47 : (quality == 3 ? 0.48 : 0.49)
        let steps = SIMD2(transform.z, transform.w) * scale
        let face: Int
        if a.x >= a.y && a.x >= a.z { face = delta.x >= 0 ? 0 : 1 } else if a.y >= a.x && a.y >= a.z { face = delta.y >= 0 ? 2 : 3 } else {
            face = delta.z >= 0 ? 4 : 5
        }
        let offsets: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(steps.x, 0), SIMD2(0, steps.y), SIMD2(steps.x, steps.y),
                                       SIMD2(0, steps.y * 2), SIMD2(steps.x, steps.y * 2)]
        let view = SceneShadowViews.pointFaceViews(origin: o)[face]
        let project = simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, info.x, info.z), SIMD4(0, 0, info.y, info.w)))
        let viewProject: simd_float4x4 = project * view
        var p: SIMD4<Float> = viewProject * SIMD4<Float>(world, 1)
        p = SIMD4(p.x / p.w, p.y / p.w, p.z / p.w, p.w)
        var uv = SIMD2(p.x, p.y) * SIMD2(compensation, -compensation) + 0.5
        uv = uv * SIMD2(transform.z, transform.w) * scale + SIMD2(transform.x, transform.y) + offsets[face]
        return (face, SIMD3(uv.x, uv.y, p.z))
    }

    /// The faces are drawn where WE's shader looks them up: for points all round a light, the
    /// shader's face is ours, its bases are the render views', and the texel it reads is where the
    /// point lands in the face's viewport (the shader's 0.47…0.49 against the 94…91.2° faces, and
    /// its 0.3333 against whole-texel rows, within 2 texels); its depth is the unbiased projection's.
    func testPointFacesMatchCalculateProjectedCoordsPoint() {
        var light = SceneLight(kind: .point)
        light.radius = 12
        let origin = SIMD3<Float>(1, 2, -3)
        var generator = SystemRandomNumberGenerator()
        for quality in 1...4 {
            let projection = SceneShadowViews.pointProjection(light, quality: quality, orthographic: false)
            let info = SceneShadowViews.projectionInfo(projection)
            let size = SceneShadowAtlas.mapSize(quality: quality)
            let map = SceneShadowMap(kind: .point, lightID: "p", size: size,
                                     renderViews: SceneShadowViews.pointRenderViews(projection: projection, origin: origin),
                                     transformIndex: 0, origin: SIMD2(size, 0))
            let extent = SIMD2(size * 3, size)
            let transform = map.transform(extent: extent)
            for _ in 0..<400 {
                let direction = simd_normalize(SIMD3<Float>(Float.random(in: -1...1, using: &generator),
                                                            Float.random(in: -1...1, using: &generator),
                                                            Float.random(in: -1...1, using: &generator)))
                let world = origin + direction * Float.random(in: 0.5...10, using: &generator)
                let shader = Self.calculateProjectedCoordsPoint(world, origin: origin, info: info, transform: transform, quality: quality)
                let faceView: simd_float4x4 = SceneShadowViews.pointFaceViews(origin: origin)[shader.face]
                let faceProjection: simd_float4x4 = projection * faceView
                let unbiased: SIMD4<Float> = faceProjection * SIMD4<Float>(world, 1)
                XCTAssertEqual(shader.coords.z, unbiased.z / unbiased.w, accuracy: 1e-4)
                let clip: SIMD4<Float> = map.renderViews[shader.face] * SIMD4<Float>(world, 1)
                let ndc = SIMD2(clip.x, clip.y) / clip.w
                XCTAssertLessThanOrEqual(max(abs(ndc.x), abs(ndc.y)), 1.0001, "inside its face's view")
                let rect = map.viewports[shader.face]
                let texel = SIMD2(Float(rect.x) + (ndc.x * 0.5 + 0.5) * Float(rect.z),
                                  Float(rect.y) + (0.5 - ndc.y * 0.5) * Float(rect.w))
                let looked = SIMD2(shader.coords.x, shader.coords.y) * SIMD2(Float(extent.x), Float(extent.y))
                XCTAssertLessThanOrEqual(simd_distance(texel, looked), 2, "quality \(quality) face \(shader.face)")
            }
        }
        XCTAssertEqual(SceneShadowViews.pointFieldOfView(quality: 2), 94)
        XCTAssertEqual(SceneShadowViews.pointFieldOfView(quality: 3), 92)
        XCTAssertEqual(SceneShadowViews.pointFieldOfView(quality: 4), 91.2)
    }

    // MARK: - The packer's values

    private static func lightWorld(position: SIMD3<Float>, direction: SIMD3<Float>) -> simd_float4x4 {
        let x = simd_normalize(direction)
        let helper = abs(x.y) > 0.9 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)
        let z = simd_normalize(simd_cross(x, helper))
        let y = simd_cross(z, x)
        return simd_float4x4(columns: (SIMD4(x, 0), SIMD4(y, 0), SIMD4(z, 0), SIMD4(position, 1)))
    }

    /// One shadowed spot, point and directional: the spot's projection is its light projection
    /// (the volumetrics'), the directional's three cascades follow it, the point's projection info
    /// is (P22, P32, P23, P33); each map's rectangle goes into its transform; the render matrices
    /// carry WE's bias and the uniforms don't. A cookie spot gets a projection and no map.
    func testThePackerWritesWEsShadowFeatures() throws {
        func light(_ kind: WELightKind, shadow: Bool = true, cookie: Bool = false) -> SceneLight {
            var light = SceneLight(kind: kind)
            light.color = SIMD3(repeating: 1)
            light.intensity = 1
            light.radius = 10
            light.castShadow = shadow
            light.useCookie = cookie
            return light
        }
        let spotWorld = Self.lightWorld(position: SIMD3(0, 5, 0), direction: SIMD3(0, -1, 0.2))
        let pointWorld = Self.lightWorld(position: SIMD3(2, 3, 1), direction: SIMD3(1, 0, 0))
        let sunWorld = Self.lightWorld(position: .zero, direction: SIMD3(0.3, -1, 0.1))
        let cookieWorld = Self.lightWorld(position: SIMD3(-2, 4, 0), direction: SIMD3(0, -1, 0))
        let lights = [
            SceneLightPacker.Light(light: light(.spot), world: spotWorld, localOrigin: .zero, visible: true, id: "spot"),
            SceneLightPacker.Light(light: light(.point), world: pointWorld, localOrigin: .zero, visible: true, id: "point"),
            SceneLightPacker.Light(light: light(.directional), world: sunWorld, localOrigin: .zero, visible: true, id: "sun"),
            SceneLightPacker.Light(light: light(.spot, shadow: false, cookie: true), world: cookieWorld, localOrigin: .zero,
                                   visible: true, id: "cookie"),
        ]
        let budget = WELightConfig(point: 1, spot: 2, directional: 1, spotShadow: 1, spotCookie: 1, directionalShadow: 1,
                                   pointShadow: 1)
        let eye = SIMD3<Float>(0, 3, 8), forward = simd_normalize(SIMD3<Float>(0, -0.3, -1))
        let context = SceneLightPacker.ShadowContext(quality: 3, eye: eye, forward: forward, orthographic: false,
                                                     atlasExtent: .zero)
        let packed = SceneLightPacker.lightingV1(lights, budget: budget, shadows: true, viewForward: forward,
                                                 shadowContext: context)
        let projections = try XCTUnwrap(packed.arrays["g_LFeature_ShadowProjection"])
        XCTAssertEqual(projections.count, 16 * 5, "F = cookie + shadow spot + 3 cascades")
        func matrix(_ index: Int) -> simd_float4x4 {
            let f = Array(projections[(16 * index)..<(16 * index + 16)])
            return simd_float4x4(columns: (SIMD4(f[0], f[1], f[2], f[3]), SIMD4(f[4], f[5], f[6], f[7]),
                                           SIMD4(f[8], f[9], f[10], f[11]), SIMD4(f[12], f[13], f[14], f[15])))
        }
        // The spot groups: cookie (slot 0), then shadow (slot 1); cascades from slot 2.
        Self.assertNear(matrix(0), SceneVolumetricLight.spotProjection(light: lights[3].light, world: cookieWorld, orthographic: false))
        let spotProjection = SceneVolumetricLight.spotProjection(light: lights[0].light, world: spotWorld, orthographic: false)
        Self.assertNear(matrix(1), spotProjection)
        let cascades = SceneShadowViews.cascades(world: sunWorld, distances: SIMD3(3, 10, 100), mapSize: 512, eye: eye,
                                                 forward: forward, orthographic: false)
        for index in 0..<3 { Self.assertNear(matrix(2 + index), cascades[index]) }

        let maps = packed.shadows.maps
        XCTAssertEqual(maps.map(\.kind), [.point, .spot, .cascade, .cascade, .cascade], "in the packer's order")
        XCTAssertEqual(maps.filter { $0.kind == .spot }.map(\.lightID), ["spot"], "the cookie spot has no map")
        XCTAssertEqual(maps.filter { $0.kind == .cascade }.map(\.transformIndex), [2, 3, 4])
        XCTAssertEqual(maps.count, 5)
        let spotMap = try XCTUnwrap(maps.first { $0.kind == .spot })
        XCTAssertEqual(spotMap.transformIndex, 1)
        Self.assertNear(spotMap.renderViews[0], SceneShadowViews.biased(spotProjection, by: 0.0005))
        XCTAssertEqual(spotMap.renderViews[0].columns.3.z, spotProjection.columns.3.z - 0.0005, accuracy: 1e-6)

        let pointMap = try XCTUnwrap(maps.first { $0.kind == .point })
        XCTAssertEqual(pointMap.origin, .zero, "points first in the atlas")
        XCTAssertEqual(pointMap.size, 512)
        let pointProjection = SceneCamera.perspective(fovDegrees: 92, aspect: 1, near: 0.05, far: 10)
        let info = try XCTUnwrap(packed.arrays["g_LFeature_ShadowPointProjection"])
        XCTAssertEqual(info, [pointProjection.columns.2.z, pointProjection.columns.3.z, pointProjection.columns.2.w,
                              pointProjection.columns.3.w])
        XCTAssertEqual(packed.shadows.pointProjections["point"], SIMD4(info[0], info[1], info[2], info[3]))
        let biased = SceneShadowViews.biased(pointProjection, by: 0.00333)
        Self.assertNear(pointMap.renderViews[0], biased * SceneShadowViews.pointFaceViews(origin: SIMD3(2, 3, 1))[0])

        let extent = packed.shadows.extent
        XCTAssertEqual(extent, SIMD2(512 * 5, 512), "five 512 maps along one shelf")
        let transforms = try XCTUnwrap(packed.arrays["g_LFeature_ShadowProjectionTransform"])
        XCTAssertEqual(Array(transforms[0..<4]), [0, 0, 0, 0], "the cookie spot has no rectangle")
        XCTAssertEqual(Array(transforms[4..<8]), Self.components(spotMap.transform(extent: extent)))
        XCTAssertEqual(try XCTUnwrap(packed.arrays["g_LFeature_ShadowPointProjectionTransform"]),
                       Self.components(pointMap.transform(extent: extent)))
        XCTAssertEqual(packed.shadows.lightTransforms["spot"], spotMap.transform(extent: extent))

        // Shadows off: the budget folds, no map, and only the cookie's projection.
        let off = SceneLightPacker.lightingV1(lights, budget: budget.withShadowsDisabled, shadows: false, viewForward: forward,
                                              shadowContext: SceneLightPacker.ShadowContext(quality: 0, eye: eye, forward: forward,
                                                                                            orthographic: false))
        XCTAssertTrue(off.shadows.maps.isEmpty)
        XCTAssertEqual(off.arrays["g_LFeature_ShadowProjection"]?.count, 16)
    }

    /// Models cast unless `castshadow` says otherwise, bound or not.
    func testModelsCastUnlessAuthoredOtherwise() {
        var model = SceneModelObject(id: "1", name: "m", order: 0, authored: WESceneModel(source: .path("a.mdl")))
        XCTAssertTrue(SceneShadowPass.castsShadow(model))
        model.renderValues[.castshadow] = .bool(false)
        XCTAssertFalse(SceneShadowPass.castsShadow(model))
        model.renderValues[.castshadow] = .object(SceneRawValue.Object(value: .bool(true), userName: "shadows"))
        XCTAssertTrue(SceneShadowPass.castsShadow(model))
    }

    // MARK: - Shadow variants

    /// fur4 and foliage4 name their own casters; everything else takes `shadowcaster.json`'s.
    func testShadowPassHeaders() throws {
        _ = try Fixtures.assets()
        let loader = ShaderSourceLoader(roots: [ShaderVariantTests.weAssets])
        XCTAssertEqual(ModelMaterialPlanBuilder.shadowPassShader(in: try loader.load("fur4", stage: .fragment).text), "shadowcasterfur4")
        XCTAssertEqual(ModelMaterialPlanBuilder.shadowPassShader(in: try loader.load("foliage4", stage: .fragment).text),
                       "shadowcasterfoliage4")
        XCTAssertNil(ModelMaterialPlanBuilder.shadowPassShader(in: try loader.load("generic4", stage: .fragment).text))
    }

    /// Every shipped caster translates with and without skinning and alpha-to-coverage, draws one
    /// instance per view into the viewport its instance picks, and builds a depth-only pipeline.
    func testEveryShippedCasterTranslatesAndBuilds() throws {
        _ = try Fixtures.assets()
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let translator = ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: nil, failureDirectory: nil)
        let loader = ShaderSourceLoader(roots: [ShaderVariantTests.weAssets])
        let format = MDLVertexFormat(rawValue: 0x180000f)
        for shader in ["shadowcaster", "shadowcasterfoliage4", "shadowcasterfur4"] {
            let vertex = try loader.load(shader, stage: .vertex), fragment = try loader.load(shader, stage: .fragment)
            for (skinning, coverage) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
                let combos = SceneEngineCombos(sceneOrtho: false).applied(to: ShaderVariantTranslator.resolveCombos(
                    vertex: vertex, fragment: fragment,
                    overrides: [["SKINNING": skinning, "BONECOUNT": 64, "ALPHATOCOVERAGE": coverage]], boundTextureSlots: [0]))
                let variant = try translator.variant(vertex: vertex, fragment: fragment, combos: combos)
                XCTAssertTrue(variant.vertexMSL.contains("viewport_array_index"), "\(shader) \(combos)")
                XCTAssertTrue(variant.vertexMSL.contains("instance_id"), "\(shader)")
                XCTAssertNotNil(variant.uniforms?.members["g_ViewportViewProjectionMatrices"], "\(shader)")
                XCTAssertNoThrow(try device.makeRenderPipelineState(
                    descriptor: SceneShadowPass.pipelineDescriptor(variant, format: format, customShader: false, device: device)),
                    "\(shader) \(combos)")
            }
        }
    }

    /// A lit image under a shadowed budget (`genericimage4`'s `g_Texture6`) and a lit model
    /// (`generic4`'s) read the frame's atlas; the model's opaque material gets its shadow variant.
    func testLitMaterialsBindTheShadowAtlas() throws {
        _ = try Fixtures.assets()
        let budget = WELightConfig(spot: 1, spotShadow: 1)
        let engine = SceneEngineCombos(sceneOrtho: false, lightBudget: budget, shadowQuality: 2)
        XCTAssertTrue(engine.castsShadows)
        XCTAssertFalse(SceneEngineCombos(sceneOrtho: false, lightBudget: budget, shadowQuality: 0).castsShadows)
        XCTAssertFalse(SceneEngineCombos(sceneOrtho: false, lightBudget: WELightConfig(spot: 1), shadowQuality: 2).castsShadows)
        let translator = ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: nil, failureDirectory: nil)
        func read(_ roots: [URL]) -> (String) -> Data? {
            { path in roots.lazy.compactMap { FileManager.default.contents(atPath: $0.appending(path: path).path) }.first }
        }
        let image = try XCTUnwrap(try ImageMaterialPlanBuilder(
            translator: translator, readFile: read([Fixtures.url("ImageMaterials"), ShaderVariantTests.weAssets]),
            loadTexture: { _, _ in nil }, sceneEngineCombos: engine).build(materialPath: "materials/lit.json", colorBlendMode: nil))
        XCTAssertEqual(image.pass.variant?.combos["LIGHTS_SHADOW_MAPPING"], 1)
        guard case .fbo(SceneShadowAtlas.name)? = image.pass.textures[6] else {
            return XCTFail("genericimage4's g_Texture6: \(String(describing: image.pass.textures[6]))")
        }
        let models = ModelMaterialPlanBuilder(
            translator: translator, readFile: read([Fixtures.url("ModelMaterials"), ShaderVariantTests.weAssets]),
            loadTexture: { _, _ in .image(NSImage(size: NSSize(width: 4, height: 4))) }, sceneEngineCombos: engine)
        let mesh = ModelRenderTests.cube()
        let lit = try models.build(materialPath: "materials/lit.json", mesh: ModelMeshCombos(mesh: mesh, bones: 0, morphTargets: false))
        guard case .fbo(SceneShadowAtlas.name)? = lit.pass.textures[6] else { return XCTFail("generic4's g_Texture6") }
        let caster = try XCTUnwrap(lit.shadowCaster)
        XCTAssertTrue(caster.materialPath.hasSuffix("(shadow: shadowcaster)"))
        XCTAssertEqual(caster.raster, .engineDefault, "shadowcaster.json's states")
        XCTAssertEqual(caster.pass.variant?.combos["SKINNING"], 0)
        XCTAssertNil(caster.shadowCaster)
        // Alpha-to-coverage: the caster discards by the albedo's alpha, read from the material's slot 0.
        let coverage = try XCTUnwrap(try models.build(materialPath: "materials/lit_coverage.json",
                                                      mesh: ModelMeshCombos(mesh: mesh, bones: 0, morphTargets: false)).shadowCaster)
        XCTAssertEqual(coverage.pass.variant?.combos["ALPHATOCOVERAGE"], 1)
        XCTAssertEqual(coverage.blending, "alphatocoverage")
        guard case .asset? = coverage.pass.textures[0] else { return XCTFail("the albedo") }
        // Translucent materials don't cast.
        XCTAssertNil(try models.build(materialPath: "materials/facecolor_translucent.json",
                                      mesh: ModelMeshCombos(mesh: mesh, bones: 0, morphTargets: false)).shadowCaster)
    }

    // MARK: - Helpers

    private static func components(_ v: SIMD4<Float>) -> [Float] { [v.x, v.y, v.z, v.w] }

    static func assertNear(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ tolerance: Float, _ message: String = "",
                           file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThanOrEqual(simd_reduce_max(simd_abs(a - b)), tolerance, "\(a) vs \(b) \(message)", file: file, line: line)
    }

    static func assertNear(_ a: simd_float4x4, _ b: simd_float4x4, _ tolerance: Float = 1e-5,
                           file: StaticString = #filePath, line: UInt = #line) {
        for column in 0..<4 {
            let difference = simd_reduce_max(simd_abs(a[column] - b[column]))
            let scale = max(1, simd_reduce_max(simd_abs(b[column])))
            XCTAssertLessThanOrEqual(difference, tolerance * scale, "column \(column): \(a[column]) vs \(b[column])", file: file, line: line)
        }
    }
}
