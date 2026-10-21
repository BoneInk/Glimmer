import XCTest
import simd
@testable import OpenWallpaperEngine

/// Every built-in particle preset variant and every particle component preview against WE's
/// particle gallery (`WEParticleGallery`): each project is built from the WE install's assets,
/// drawn headlessly by `WEReferenceRenderer` (the still at 5.5 s, then 5 s at 5 fps) and measured as
/// the gallery's summarize.py measures WE's captures. Particles are random, so statistics are
/// compared, not pixels: the clip's mean coverage and its motion must match WE's
/// (`Tests/Fixtures/WEParticleGallery/expected.json`) within tolerance; a known gap is reported, not failed.
///
/// Runs only when `OWE_PARTICLE_GALLERY` (`TEST_RUNNER_OWE_PARTICLE_GALLERY` through xcodebuild) is
/// set: `1`, or the gallery folder, which adds WE | ours pictures of the stills. It needs a WE
/// install (the presets and previews aren't in the assets cache): `OWE_ASSETS` (`TEST_RUNNER_OWE_ASSETS`),
/// the install or its `assets` folder, which the test host then uses as its assets directory.
/// `OWE_PARTICLE_GALLERY_ONLY` lists names (`fire_1`, `ptce_rope`); the report and pictures go to
/// `OWE_PARTICLE_GALLERY_OUT`, and `OWE_PARTICLE_GALLERY_FRAMES=1` also writes each clip frame at half size.
final class WEParticleGalleryTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appending(path: "owe-particle-gallery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch, FileManager.default.fileExists(atPath: scratch.path) {
            try FileManager.default.removeItem(at: scratch)
        }
    }

    func testPresetsAndComponentsMatchWEsGallery() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let gallery = environment["OWE_PARTICLE_GALLERY"], !gallery.isEmpty else {
            throw XCTSkip("set OWE_PARTICLE_GALLERY to 1 or to the particle gallery folder")
        }
        let assets = try XCTUnwrap(WallpaperEngineAssets.directory)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: assets.appending(path: "presets").path),
                          "the assets directory isn't a WE install (no presets)")
        let captures: URL? = gallery == "1" ? nil : URL(fileURLWithPath: gallery, isDirectory: true)
        let output = environment["OWE_PARTICLE_GALLERY_OUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appending(path: "owe-particle-gallery-out")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let writeFrames = environment["OWE_PARTICLE_GALLERY_FRAMES"] == "1"
        let only = Set((environment["OWE_PARTICLE_GALLERY_ONLY"] ?? "").split(separator: ",").map(String.init))
        let expectations = Dictionary(try WEParticleGallery.expectations().map { ($0.name, $0) }) { first, _ in first }

        let items = try WEParticleGallery.presetItems(assets: assets, in: scratch, only: only)
            + WEParticleGallery.elementItems(assets: assets, in: scratch, only: only)
        var backgrounds: [String: WEReferenceImage] = [:]
        var report = ["name\tcoverage WE\tcoverage ours\tmotion WE\tmotion ours\tverdict"]
        for item in items {
            let directory = try item.make()
            defer { try? FileManager.default.removeItem(at: directory) } // Scratch space; the scratch folder goes at the end anyway.
            let seeds = max(expectations[item.name]?.seeds ?? 1, 1)
            var frames: [WEReferenceImage] = []
            var coverages: [Double] = [], motions: [Double] = []
            for seed in 0..<seeds {
                let drawn = try render(directory, particleSeed: UInt32(seed))
                if seed == 0 { frames = drawn }
                // The clip's mean coverage at half size, as the gallery's clip (5 fps, 960 × 540) is
                // measured; one still of random particles is too noisy to compare.
                let halves = drawn.dropFirst().map { WEParticleGallery.scaled($0, width: $0.width / 2, height: $0.height / 2) }
                let clip: [Double]
                if let background = item.background {
                    if backgrounds[background] == nil {
                        let full = try WEReferenceImage.load(WEParticleGallery.fixtures.appending(path: "\(background).png"))
                        backgrounds[background] = WEParticleGallery.subsampled(full)
                    }
                    let half = try XCTUnwrap(backgrounds[background])
                    clip = halves.map { WEParticleGallery.coverage($0, background: half, height: 515) }
                } else {
                    clip = halves.map { WEParticleGallery.coverageAgainstMode($0, height: 515) }
                }
                coverages.append(clip.reduce(0, +) / Double(max(clip.count, 1)))
                motions.append(WEParticleGallery.motion(Array(drawn.dropFirst())))
            }
            if seeds > 1 {
                print(String(format: "%@ per seed: coverage %@, motion %@", item.name,
                             coverages.map { String(format: "%.2f", $0) }.joined(separator: " "),
                             motions.map { String(format: "%.2f", $0) }.joined(separator: " ")))
            }
            let coverage = coverages.reduce(0, +) / Double(seeds)
            let motion = motions.reduce(0, +) / Double(seeds)
            try frames[0].write(to: output.appending(path: "\(item.name)-ours.png"))
            if writeFrames {
                let folder = output.appending(path: "frames/\(item.name)", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for (index, frame) in frames.enumerated() {
                    try WEParticleGallery.scaled(frame, width: frame.width / 2, height: frame.height / 2).write(to: folder.appending(path: String(format: "f%02d.png", index)))
                }
            }
            if let captures {
                let file = item.name.hasPrefix("ptce_") ? "elements/\(item.name).png" : "captures/\(item.name).png"
                let url = captures.appending(path: file)
                if FileManager.default.fileExists(atPath: url.path) {
                    let we = try WEReferenceImage.load(url)
                    try WEReferenceImage.sideBySide([WEParticleGallery.scaled(we, width: 960, height: 540),
                                                      WEParticleGallery.scaled(frames[0], width: 960, height: 540)])
                        .write(to: output.appending(path: "\(item.name)-compare.png"))
                }
            }
            guard let expectation = expectations[item.name] else {
                report.append(String(format: "%@\t\t%.2f\t\t%.2f\tno expectation", item.name, coverage, motion))
                continue
            }
            let coverageOK = abs(coverage - expectation.coverage) <= expectation.allowedCoverage
            let motionOK = abs(motion - expectation.motion) <= expectation.allowedMotion
            let verdict = coverageOK && motionOK ? "match" : (expectation.knownGap.map { "known: \($0)" } ?? "OFF")
            report.append(String(format: "%@\t%.2f\t%.2f\t%.2f\t%.2f\t%@", item.name, expectation.coverage, coverage,
                                 expectation.motion, motion, verdict))
            let check = {
                XCTAssertEqual(coverage, expectation.coverage, accuracy: expectation.allowedCoverage, "\(item.name): coverage")
                XCTAssertEqual(motion, expectation.motion, accuracy: expectation.allowedMotion, "\(item.name): motion")
            }
            if let gap = expectation.knownGap {
                XCTExpectFailure(gap, options: .nonStrict(), failingBlock: check)
            } else {
                check()
            }
        }
        let text = report.joined(separator: "\n") + "\n"
        try text.write(to: output.appending(path: "report.tsv"), atomically: true, encoding: .utf8)
        print("Particle gallery against WE (output \(output.path)):\n\(text)")
    }

    /// WE 2.8.0.42's particle flag tests (tools/peer/particle_schema/flagtests, README D and E), when
    /// `OWE_PARTICLE_FLAGTESTS` points at that folder:
    /// - `pf_childflags_0/2`: a static child with link flags 0 or 2 under the layer's `colorn`
    ///   "1 0 0" is red either way (WE 133,12,14 and 134,12,14).
    /// - `pf_remapclamp_*`: `remapvalue` lifetimefraction 0…0.5 → size × 0…1 on static particles;
    ///   the clip's light over the background against `pf_remapsanity_none` (no remap) is WE's 0.64
    ///   for flags 1, 0.65 for flags 2 and 1.33 for flags 0 (unclamped). WE's `absent` capture
    ///   (0.64) contradicts its parser, which reads an absent `flags` as 0 (0x1401ce803); it is
    ///   likely the previous project captured again (README "Capture reliability"), so it's reported, not asserted.
    func testFlagTestsMatchWE() throws {
        guard let root = ProcessInfo.processInfo.environment["OWE_PARTICLE_FLAGTESTS"], !root.isEmpty else {
            throw XCTSkip("set OWE_PARTICLE_FLAGTESTS to the flagtests folder")
        }
        let folder = URL(fileURLWithPath: root, isDirectory: true)
        func run(_ name: String) throws -> [WEReferenceImage] {
            let directory = scratch.appending(path: name)
            try FileManager.default.copyItem(at: folder.appending(path: "projects/\(name)"), to: directory)
            return try render(directory)
        }
        for name in ["pf_childflags_0", "pf_childflags_2"] {
            let still = try run(name)[0]
            var sum = SIMD3<Double>.zero, count = 0.0
            still.pixels.withUnsafeBufferPointer { p in
                for y in 0..<WEParticleGallery.comparedHeight {
                    for x in (still.width / 2 + 200)..<still.width {
                        let o = (y * still.width + x) * 4
                        let rgb = SIMD3(Double(p[o]), Double(p[o + 1]), Double(p[o + 2]))
                        guard rgb.max() > 60 else { continue }
                        sum += rgb
                        count += 1
                    }
                }
            }
            XCTAssertGreaterThan(count, 100, "\(name): the child draws")
            let mean = sum / max(count, 1)
            XCTAssertGreaterThan(mean.x, 3 * max(mean.y, mean.z), "\(name): the child takes the layer's red, \(mean)")
        }
        func light(_ frames: [WEReferenceImage]) -> Double {
            var total = 0.0
            for frame in frames.dropFirst() {
                let small = WEParticleGallery.scaled(frame, width: 960, height: 540)
                small.pixels.withUnsafeBufferPointer { p in
                    for i in 0..<(960 * 515) { total += max(0.299 * Double(p[i * 4]) + 0.587 * Double(p[i * 4 + 1]) + 0.114 * Double(p[i * 4 + 2]) - 13, 0) }
                }
            }
            return total
        }
        let none = light(try run("pf_remapsanity_none"))
        for (name, we) in [("pf_remapclamp_1", 0.64), ("pf_remapclamp_f2", 0.65), ("pf_remapclamp_f0", 1.33)] {
            let ratio = light(try run(name)) / max(none, 1)
            XCTAssertEqual(ratio, we, accuracy: 0.15, "\(name): light against no remap")
        }
        let absent = light(try run("pf_remapclamp_absent")) / max(none, 1)
        print(String(format: "Flag tests: remapvalue without flags draws %.2f of no remap (WE's capture 0.64, its parser 1.33)", absent))
    }

    /// The still, then the clip's frames at 5 fps.
    private func render(_ directory: URL, particleSeed: UInt32 = 0) throws -> [WEReferenceImage] {
        let data = try Data(contentsOf: directory.appending(path: "project.json"))
        let project = try decodeTolerant(WEProject.self, from: data)
        var settings = SceneRenderSettings()
        // WE's settings for the galleries: post-processing on, MSAA x2.
        settings.postProcessing = .enabled
        settings.particleBudget = .unlimited
        settings.textureReduction = 1
        settings.sceneDetail = .full
        settings.renderResolution = .yourDisplay
        settings.antiAliasing = .msaa_x2
        var renderer = WEReferenceRenderer(directory: directory, project: project, settings: settings,
                                           storage: scratch.appending(path: "storage-\(directory.lastPathComponent)"))
        renderer.particleSeed = particleSeed
        let shots = (0...WEParticleGallery.motionFrames).map {
            WEReferenceRenderer.Shot(time: WEParticleGallery.stillTime + Double(max($0 - 1, 0)) * WEParticleGallery.motionStep,
                                     cursor: WEParticleGallery.cursor)
        }
        defer { Fixtures.removeStoredSettings(for: directory) }
        return try renderer.render(shots)
    }
}
