import XCTest
import simd
@testable import OpenWallpaperEngine

/// Every built-in effect at its defaults against WE's effect gallery (`WEEffectGallery`): each
/// gallery scene is built from the fixture pictures and the WE assets' effect, drawn headlessly by
/// `WEReferenceRenderer` (the still at 5 s, then a 3 s clip at 25 fps), and measured as the
/// gallery's summarize.py measures WE's captures: the difference from the no-effect scene, and the
/// motion of the clip encoded as WE's was (`WEEffectGallery.clipMotion`).
/// Those two must match WE's (`Tests/Fixtures/WEEffectGallery/expected.json`) within tolerance;
/// random or animated effects are matched by these statistics, not by pixels.
///
/// Runs only when `OWE_EFFECT_GALLERY` (`TEST_RUNNER_OWE_EFFECT_GALLERY` through xcodebuild) is set:
/// `1`, or the gallery folder, which adds a comparison with WE's stills (mean abs, SSIM) and renders
/// the gallery's editor-made `user_effecttest-*` projects too. EXTRAS.md's blur `COMPOSITE` modes are
/// in the list (`uses`, `passes`). `OWE_EFFECT_GALLERY_ONLY` lists effects;
/// the report and pictures go to `OWE_EFFECT_GALLERY_OUT` (default: a temporary folder).
final class WEEffectGalleryTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appending(path: "owe-effect-gallery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch, FileManager.default.fileExists(atPath: scratch.path) {
            try FileManager.default.removeItem(at: scratch)
        }
    }

    func testEffectsAtTheirDefaultsMatchWEsGallery() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let gallery = environment["OWE_EFFECT_GALLERY"], !gallery.isEmpty else {
            throw XCTSkip("set OWE_EFFECT_GALLERY to 1 or to the effect gallery folder")
        }
        try XCTSkipUnless(Fixtures.hasWEShaderSources, "WE's effect shader sources aren't available")
        try XCTSkipUnless(WEEffectGallery.ffmpeg != nil, "the gallery's motion is measured through ffmpeg")
        let assets = try XCTUnwrap(WallpaperEngineAssets.directory)
        let captures: URL? = gallery == "1" ? nil : URL(fileURLWithPath: gallery, isDirectory: true)
        let output = environment["OWE_EFFECT_GALLERY_OUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appending(path: "owe-effect-gallery-out")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let only = Set((environment["OWE_EFFECT_GALLERY_ONLY"] ?? "").split(separator: ",").map(String.init))
        let expectations = try WEEffectGallery.expectations()

        let control = try render(WEEffectGallery.makeProject(effect: nil, assets: assets, in: scratch), stillOnly: true)[0]
        try control.write(to: output.appending(path: "none-ours.png"))
        var report = ["effect\tdiff WE\tdiff ours\tmotion WE\tmotion ours\tmean abs vs WE\tSSIM vs WE\tverdict"]
        for expectation in expectations where only.isEmpty || only.contains(expectation.effect) {
            let directory: URL
            if expectation.effect.hasPrefix("user_") {
                guard let captures else { continue }
                let source = captures.appending(path: "projects/\(expectation.effect.replacingOccurrences(of: "user_", with: "user_effecttest-"))")
                directory = scratch.appending(path: source.lastPathComponent)
                try FileManager.default.copyItem(at: source, to: directory)
            } else {
                directory = try WEEffectGallery.makeProject(effect: expectation.effectFolder, passes: expectation.passes,
                                                            name: expectation.effect, assets: assets, in: scratch)
            }
            let frames = try render(directory, stillOnly: false)
            let diff = WEEffectGallery.meanAbsoluteDifference(frames[0], control)
            let motion = try WEEffectGallery.clipMotion(Array(frames.dropFirst()), scratch: scratch)
            try frames[0].write(to: output.appending(path: "\(expectation.effect)-ours.png"))
            var versusWE = "\t\t"
            if let captures {
                let url = captures.appending(path: expectation.capturePath)
                if FileManager.default.fileExists(atPath: url.path) {
                    let we = try WEReferenceImage.load(url)
                    let size = WEReferenceRenderer.size
                    let taskbar = size.y - WEEffectGallery.comparedHeight
                    let mask = WEReferenceMask(width: size.x, height: size.y, masks: [], taskbar: taskbar)
                    let metrics = WEReferenceMetrics.compare(we: we, ours: frames[0], mask: mask,
                                                             grid: .init(columns: 4, rows: 2), taskbar: taskbar, edges: false)
                    versusWE = String(format: "%.1f\t%.3f", metrics.meanAbs, metrics.ssim)
                    let difference = WEReferenceMetrics.differenceImage(we: we, ours: frames[0], mask: mask)
                    try WEReferenceImage.sideBySide([we.reduced(by: 2), frames[0].reduced(by: 2), difference])
                        .write(to: output.appending(path: "\(expectation.effect)-compare.png"))
                }
            }
            let diffOK = abs(diff - expectation.diff) <= expectation.allowedDiff
            let motionOK = abs(motion - expectation.motion) <= expectation.allowedMotion
            let verdict = diffOK && motionOK ? "match" : (expectation.knownGap.map { "known: \($0)" } ?? "OFF")
            report.append(String(format: "%@\t%.2f\t%.2f\t%.2f\t%.2f\t%@\t%@", expectation.effect, expectation.diff, diff,
                                 expectation.motion, motion, versusWE, verdict))
            let check = {
                XCTAssertEqual(diff, expectation.diff, accuracy: expectation.allowedDiff, "\(expectation.effect): difference from the control")
                XCTAssertEqual(motion, expectation.motion, accuracy: expectation.allowedMotion, "\(expectation.effect): motion")
            }
            if let gap = expectation.knownGap {
                XCTExpectFailure("\(gap)", options: .nonStrict(), failingBlock: check)
            } else {
                check()
            }
        }
        let text = report.joined(separator: "\n") + "\n"
        try text.write(to: output.appending(path: "report.tsv"), atomically: true, encoding: .utf8)
        print("Effect gallery against WE (output \(output.path)):\n\(text)")
    }

    /// The still at 5 s, then unless `stillOnly` the clip's frames from `clipStart` at WE's frame rate.
    private func render(_ directory: URL, stillOnly: Bool) throws -> [WEReferenceImage] {
        let data = try Data(contentsOf: directory.appending(path: "project.json"))
        let project = try decodeTolerant(WEProject.self, from: data)
        var settings = SceneRenderSettings()
        // WE's settings for the gallery (its README): post-processing on, MSAA x2.
        settings.postProcessing = .enabled
        settings.particleBudget = .unlimited
        settings.textureReduction = 1
        settings.sceneDetail = .full
        settings.renderResolution = .yourDisplay
        settings.antiAliasing = .msaa_x2
        var renderer = WEReferenceRenderer(directory: directory, project: project, settings: settings,
                                           storage: scratch.appending(path: "storage-\(directory.lastPathComponent)"))
        renderer.frameRate = WEEffectGallery.frameRate
        let clipFrames = Int((WEEffectGallery.clipDuration * WEEffectGallery.frameRate).rounded())
        let clip: [Double] = stillOnly ? [] : (0..<clipFrames).map { (index: Int) -> Double in
            WEEffectGallery.clipStart + Double(index) / WEEffectGallery.frameRate
        }
        let shots = ([WEEffectGallery.stillTime] + clip).map {
            WEReferenceRenderer.Shot(time: $0, cursor: WEEffectGallery.cursor)
        }
        defer { Fixtures.removeStoredSettings(for: directory) }
        return try renderer.render(shots)
    }
}
