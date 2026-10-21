import XCTest
import Metal
@testable import OpenWallpaperEngine

/// Reduced-resolution blur buffers (WP3-C): which effects and buffers shrink, by how much, and the
/// perceptual gates on library wallpapers.
final class EffectResolutionPolicyTests: XCTestCase {
    private func fbo(_ json: String) throws -> EffectFBO {
        try JSONDecoder().decode(EffectFBO.self, from: Data(json.utf8))
    }

    private func effect(_ file: String, fbos: [EffectFBO]) -> SceneEffectPlan {
        SceneEffectPlan(file: file, fbos: fbos, passes: [])
    }

    func testBlurLikeEffectsAreFoundByTheirDownsampledBuffersOnly() throws {
        let half = try fbo(#"{"name":"a","scale":2,"format":"rgba8888"}"#)
        let full = try fbo(#"{"name":"a","scale":1,"format":"rgba8888"}"#)
        let fixedHalf = try fbo(#"{"name":"a","scale":2,"format":"rgba8888","width":256,"height":256}"#)
        XCTAssertTrue(EffectResolutionPolicy.isBlurLike(effect("effects/custom/effect.json", fbos: [half])))
        XCTAssertTrue(EffectResolutionPolicy.isBlurLike(effect("effects/anything/effect.json", fbos: [full, half])))
        // The name says nothing: a "blur" with only full-size buffers keeps its size.
        XCTAssertFalse(EffectResolutionPolicy.isBlurLike(effect("effects/blurprecise/effect.json", fbos: [full])))
        XCTAssertFalse(EffectResolutionPolicy.isBlurLike(effect("effects/godrays/effect.json", fbos: [])))
        XCTAssertFalse(EffectResolutionPolicy.isBlurLike(effect("effects/custom/effect.json", fbos: [fixedHalf])),
                       "a fixed-size buffer is a tile, not a downsample")
        XCTAssertFalse(EffectResolutionPolicy.isBlurLike(effect("effects/waterripple/effect.json", fbos: [full])))
    }

    func testDivisorFollowsTheSliderAndCapsTheTotalScale() throws {
        let quarter = try fbo(#"{"name":"a","scale":4,"format":"rgba8888"}"#)
        let blur = effect("effects/blur/effect.json", fbos: [quarter])
        XCTAssertEqual(EffectResolutionPolicy(divisor: 1).divisor(for: quarter, in: blur), 1)
        XCTAssertEqual(EffectResolutionPolicy(divisor: 2).divisor(for: quarter, in: blur), 2)
        XCTAssertEqual(EffectResolutionPolicy(divisor: 4).divisor(for: quarter, in: blur), 2, "¼ × ½ = ⅛ at most")
        XCTAssertEqual(EffectResolutionPolicy(divisor: 4, sharpContent: true).divisor(for: quarter, in: blur), 1)
    }

    func testFixedTiledAndFrameCarryingBuffersKeepTheirSize() throws {
        let fixed = try fbo(#"{"name":"a","scale":1,"format":"rgba8888","width":256,"height":256}"#)
        let tiled = try fbo(#"{"name":"b","scale":1,"format":"rgba8888","uvs":"repeat"}"#)
        let policy = EffectResolutionPolicy(divisor: 2)
        let half = try fbo(#"{"name":"h","scale":2,"format":"rgba8888"}"#)
        let blur = effect("effects/blur/effect.json", fbos: [fixed, tiled, half])
        XCTAssertEqual(policy.divisor(for: fixed, in: blur), 1)
        XCTAssertEqual(policy.divisor(for: tiled, in: blur), 1)
        let copy = SceneEffectPassPlan(command: .copy(source: "previous", target: "b"), variantKey: "", variant: nil,
                                       blending: "normal", target: nil, textures: [:], constants: .init(staticValues: [:], dynamic: []))
        let copying = SceneEffectPlan(file: "effects/motionblur/effect.json", fbos: [tiled], passes: [copy])
        let plain = try fbo(#"{"name":"c","scale":1,"format":"rgba8888"}"#)
        XCTAssertEqual(policy.divisor(for: plain, in: copying), 1)
    }

    func testReducedSizeKeepsAMinimumSideAndReportsTheAuthoredSize() throws {
        XCTAssertEqual(EffectResolutionPolicy.reduced(SIMD2(1000, 500), by: 2), SIMD2(500, 250))
        XCTAssertEqual(EffectResolutionPolicy.reduced(SIMD2(40, 20), by: 4), SIMD2(40, 20))
        XCTAssertEqual(EffectResolutionPolicy.reduced(SIMD2(64, 32), by: 4), SIMD2(32, 16))
        let half = try fbo(#"{"name":"a","scale":2,"format":"rgba8888"}"#)
        let (size, standsFor) = EffectResolutionPolicy(divisor: 2).fboSize(half, in: effect("effects/blur/effect.json", fbos: [half]),
                                                                           width: 800, height: 400)
        XCTAssertEqual(size, SIMD2(200, 100))
        XCTAssertEqual(standsFor, SIMD2(400, 200))
    }

    /// The §4 lossy gate (SSIM ≥ 0.98, ΔE99 ≤ 2.0) at ½ and ¼ against full size, per wallpaper of
    /// `OWE_BLUR_LIBRARY` (folders under `OWE_LIBRARY`, comma separated, or `all`).
    func testReducedBlurPassesThePerceptualGateOnLibraryWallpapers() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let ids = environment["OWE_BLUR_LIBRARY"], !ids.isEmpty else {
            throw XCTSkip("set OWE_BLUR_LIBRARY to compare library wallpapers")
        }
        let library = LibrarySweepTests.libraryRoot
        let names = ids == "all"
            ? ((try? FileManager.default.contentsOfDirectory(atPath: library.path)) ?? []).sorted()
            : ids.split(separator: ",").map(String.init)
        let size = SIMD2(1280, 720)
        var failures: [String] = []
        for name in names {
            let directory = library.appending(path: name)
            guard let data = FileManager.default.contents(atPath: directory.appending(path: "project.json").path),
                  let project = try? JSONDecoder().decode(WEProject.self, from: data),
                  project.type.lowercased() == "scene" else { continue }
            let harnesses = try [1, 1, 2, 4].enumerated().map { index, divisor in
                let harness = try SceneFrameHarness(directory: directory, size: size, screenID: "blur\(index)")
                harness.renderer.blurDivisorOverride = divisor
                return harness
            }
            defer { harnesses.forEach { $0.close() } }
            var worst: [Int: (ssim: Double, deltaE: Double)] = [2: (1, 0), 4: (1, 0)]
            var compared = 0
            for frame in 0..<40 {
                for harness in harnesses { harness.draw(frames: 1, step: 1.0 / 30) }
                guard frame >= 10, frame % 5 == 0 else { continue }
                let reference = Self.read(harnesses[0])
                // Frames that differ between two full-size runs (random particles) say nothing.
                guard PerceptualCompare.ssim(reference, Self.read(harnesses[1])) >= 0.9999 else { continue }
                compared += 1
                for (index, divisor) in [(2, 2), (3, 4)] {
                    let verdict = PerceptualCompare.evaluate(reference: reference, candidate: Self.read(harnesses[index]), kind: .lossy)
                    worst[divisor] = (min(worst[divisor]!.ssim, verdict.ssim), max(worst[divisor]!.deltaE, verdict.deltaE99))
                    if !verdict.passed { failures.append("\(name) ÷\(divisor) frame \(frame): \(verdict)") }
                }
            }
            print(String(format: "ReducedBlur %@: compared %d, ½ SSIM %.5f ΔE99 %.3f, ¼ SSIM %.5f ΔE99 %.3f", name, compared,
                         worst[2]!.ssim, worst[2]!.deltaE, worst[4]!.ssim, worst[4]!.deltaE))
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    private static func read(_ scene: SceneFrameHarness) -> PerceptualImage {
        let size = scene.size
        var bytes = [UInt8](repeating: 0, count: size.x * size.y * 4)
        scene.view.currentDrawable?.texture.getBytes(&bytes, bytesPerRow: size.x * 4,
                                                     from: MTLRegionMake2D(0, 0, size.x, size.y), mipmapLevel: 0)
        for pixel in stride(from: 0, to: bytes.count, by: 4) {
            bytes.swapAt(pixel, pixel + 2)
            bytes[pixel + 3] = 255
        }
        return PerceptualImage(width: size.x, height: size.y, rgba: bytes)
    }
}
