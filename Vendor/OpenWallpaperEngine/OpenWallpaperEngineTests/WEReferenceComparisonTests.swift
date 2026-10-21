import XCTest
import simd
@testable import OpenWallpaperEngine

/// Our frames against real Wallpaper Engine's (2.8.0.42 on Windows, 1920×1080 at 100 %; the
/// captures and how they were taken are in tools/peer/README.md on the `we-test-wp-images`
/// branch). Each captured wallpaper is drawn headlessly at the capture's settings and times
/// (`WEReferenceRenderer`) and compared per grid cell (mean colour, brightness, SSIM, edge
/// alignment) outside the taskbar strip and the item's masks (`Tests/Fixtures/WEReference/captures.json`).
///
/// It reports, it doesn't judge: the Markdown (`report.md`), our frames and WE | ours | difference
/// pictures go to `OWE_WE_REFERENCE_OUT` (default: a temporary folder). Runs only when
/// `OWE_WE_REFERENCE` (`TEST_RUNNER_OWE_WE_REFERENCE` through xcodebuild) points at the captures'
/// `tools/peer` folder and the library is present; `OWE_WE_REFERENCE_ONLY` lists workshop ids.
final class WEReferenceComparisonTests: XCTestCase {
    private var storage: URL!

    override func setUpWithError() throws {
        storage = FileManager.default.temporaryDirectory.appending(path: "owe-we-reference-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let storage, FileManager.default.fileExists(atPath: storage.path) {
            try FileManager.default.removeItem(at: storage)
        }
    }

    func testFramesAgainstWEsCaptures() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let root = environment["OWE_WE_REFERENCE"], !root.isEmpty else {
            throw XCTSkip("set OWE_WE_REFERENCE to the captures' tools/peer folder")
        }
        let captures = URL(fileURLWithPath: root, isDirectory: true)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: captures.appending(path: "README.md").path),
                          "no captures at \(captures.path)")
        let library = LibrarySweepTests.libraryRoot
        try XCTSkipUnless(FileManager.default.fileExists(atPath: library.path), "wallpaper library not present")
        let output = environment["OWE_WE_REFERENCE_OUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appending(path: "owe-we-reference-out")
        let only = Set((environment["OWE_WE_REFERENCE_ONLY"] ?? "").split(separator: ",").map(String.init))
        let config = try WEReferenceConfig.load()
        var report = WEReferenceReport()
        var compared = 0
        for item in config.items where only.isEmpty || only.contains(item.id) {
            compared += try compare(item, config: config, captures: captures, library: library, output: output,
                                    report: &report)
        }
        XCTAssertGreaterThan(compared, 0, "no still was compared")
        let header = "# WE reference comparison (generated)\n\nOutput: \(output.path)"
        let text = report.markdown(header: header)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try text.write(to: output.appending(path: "report.md"), atomically: true, encoding: .utf8)
        print(text)
    }

    /// Draws and compares one wallpaper's captures; returns the stills compared.
    private func compare(_ item: WEReferenceConfig.Item, config: WEReferenceConfig, captures: URL, library: URL,
                         output: URL, report: inout WEReferenceReport) throws -> Int {
        let directory = library.appending(path: item.id, directoryHint: .isDirectory)
        guard let data = FileManager.default.contents(atPath: directory.appending(path: "project.json").path) else {
            report.missing(item, reason: "not in the library")
            return 0
        }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
        let project = try decodeTolerant(WEProject.self, from: Data(text.utf8))
        let masks = item.masks ?? []
        let size = WEReferenceRenderer.size
        let mask = WEReferenceMask(width: size.x, height: size.y, masks: masks, taskbar: config.taskbarHeight)
        let folder = output.appending(path: item.id, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        report.begin(item, masks: masks)
        // By capture folder, then still file.
        var ours: [String: [String: WEReferenceImage]] = [:]
        var theirs: [String: [String: WEReferenceImage]] = [:]
        var count = 0
        for capture in item.captures {
            let stills = capture.resolvedStills
            let shots = stills.map { still in
                let cursor = still.cursor.map { SIMD2($0[0], $0[1]) }
                return WEReferenceRenderer.Shot(time: still.time, cursor: cursor ?? SIMD2(Double(size.x) / 2, Double(size.y) / 2))
            }
            let renderer = WEReferenceRenderer(directory: directory, project: project, settings: Self.settings(capture),
                                               textureResolution: GSTextureResolutionQuality(weConfigValue: capture.textureResolution ?? "full"),
                                               storage: storage, localTime: capture.localTime)
            let frames = try renderer.render(shots)
            for (still, frame) in zip(stills, frames) {
                let url = captures.appending(path: "\(item.id)/\(capture.folder)/\(still.file)")
                guard FileManager.default.fileExists(atPath: url.path) else {
                    report.note("- \(capture.folder)/\(still.file): no capture")
                    continue
                }
                let we = try WEReferenceImage.load(url)
                XCTAssertEqual(SIMD2(we.width, we.height), size, url.path)
                let metrics = WEReferenceMetrics.compare(we: we, ours: frame, mask: mask, grid: config.grid,
                                                         taskbar: config.taskbarHeight)
                let unreliable = capture.unreliable?.contains(still.file) ?? false
                report.add(item, capture: capture, still: still.file, metrics: metrics, unreliable: unreliable)
                let stem = "\(capture.folder)-" + (still.file as NSString).deletingPathExtension
                try frame.write(to: folder.appending(path: "\(stem)-ours.png"))
                let difference = WEReferenceMetrics.differenceImage(we: we, ours: frame, mask: mask)
                let pictures = [we.reduced(by: 2), frame.reduced(by: 2), difference]
                try WEReferenceImage.sideBySide(pictures).write(to: folder.appending(path: "\(stem)-compare.png"))
                ours[capture.folder, default: [:]][still.file] = frame
                theirs[capture.folder, default: [:]][still.file] = we
                count += 1
            }
        }
        checkRegions(item, ours: ours, theirs: theirs, mask: mask, report: &report)
        checkBaselines(item, ours: ours, theirs: theirs, mask: mask, report: &report)
        checkParallax(item, ours: ours, theirs: theirs, report: &report)
        report.note("\nPictures (WE | ours | difference ×4, masked in blue): \(folder.path)")
        return count
    }

    /// WE's settings for the captures (tools/peer/README.md): the user's config (medium preset,
    /// post-processing on, reflections, full textures) with the capture's post-processing, volumetrics and shadows;
    /// the texture resolution is resolved by the renderer (`WEReferenceRenderer.textureResolution`).
    /// WE has no particle budget.
    private static func settings(_ capture: WEReferenceConfig.Capture) -> SceneRenderSettings {
        var settings = SceneRenderSettings()
        settings.postProcessing = .enabled
        settings.reflection = true
        settings.particleBudget = .unlimited
        // WE's own detail, whatever the app's default, one pixel per point.
        settings.sceneDetail = .full
        settings.renderResolution = .yourDisplay
        if let value = capture.postProcessing {
            settings.postProcessing = GSPostProcessingQuality(rawValue: value) ?? settings.postProcessing
            XCTAssertNotNil(GSPostProcessingQuality(rawValue: value), "post-processing \(value)")
        }
        if let value = capture.volumetrics {
            settings.volumetrics = GSLightingQuality(rawValue: value) ?? settings.volumetrics
            XCTAssertNotNil(GSLightingQuality(rawValue: value), "volumetrics \(value)")
        }
        if let value = capture.shadows {
            settings.shadows = GSLightingQuality(rawValue: value) ?? settings.shadows
            XCTAssertNotNil(GSLightingQuality(rawValue: value), "shadows \(value)")
        }
        return settings
    }

    private func checkRegions(_ item: WEReferenceConfig.Item, ours: [String: [String: WEReferenceImage]],
                              theirs: [String: [String: WEReferenceImage]], mask: WEReferenceMask,
                              report: inout WEReferenceReport) {
        guard let regions = item.regions, !regions.isEmpty else { return }
        var lines = ["", "| region | capture/still | luma WE | luma ours |", "|---|---|---|---|"]
        for region in regions {
            for capture in item.captures {
                for still in capture.resolvedStills {
                    guard let we = theirs[capture.folder]?[still.file], let frame = ours[capture.folder]?[still.file] else {
                        continue
                    }
                    let a = WEReferenceMetrics.regionLuma(we, rect: region.rect, mask: mask)
                    let b = WEReferenceMetrics.regionLuma(frame, rect: region.rect, mask: mask)
                    let name = "\(region.name) (\(region.rect.description))"
                    lines.append(String(format: "| %@ | %@/%@ | %.1f | %.1f |", name, capture.folder, still.file, a, b))
                }
            }
        }
        report.note(lines.joined(separator: "\n") + "\n")
    }

    /// For a capture with a baseline: what its setting adds over the baseline's first still.
    private func checkBaselines(_ item: WEReferenceConfig.Item, ours: [String: [String: WEReferenceImage]],
                                theirs: [String: [String: WEReferenceImage]], mask: WEReferenceMask,
                                report: inout WEReferenceReport) {
        let withBaseline = item.captures.filter { $0.baseline != nil }
        guard !withBaseline.isEmpty else { return }
        var lines = ["", "What each setting adds over its baseline (first stills): mean brightening, centroid, long-axis angle (° clockwise from +x).",
                     "", "| capture | over | WE | ours |", "|---|---|---|---|"]
        for capture in withBaseline {
            guard let baseline = capture.baseline,
                  let file = capture.resolvedStills.first?.file,
                  let baseFile = item.captures.first(where: { $0.folder == baseline })?.resolvedStills.first?.file,
                  let we = theirs[capture.folder]?[file], let weBase = theirs[baseline]?[baseFile],
                  let frame = ours[capture.folder]?[file], let frameBase = ours[baseline]?[baseFile] else { continue }
            let a = WEReferenceMetrics.added(we, over: weBase, mask: mask)
            let b = WEReferenceMetrics.added(frame, over: frameBase, mask: mask)
            lines.append("| \(capture.folder) | \(baseline) | \(Self.describe(a)) | \(Self.describe(b)) |")
        }
        report.note(lines.joined(separator: "\n") + "\n")
    }

    private static func describe(_ added: WEReferenceMetrics.Added) -> String {
        String(format: "%.2f at (%.0f, %.0f), %.0f°", added.mean, added.centroid.x, added.centroid.y, added.angle)
    }

    private func checkParallax(_ item: WEReferenceConfig.Item, ours: [String: [String: WEReferenceImage]],
                               theirs: [String: [String: WEReferenceImage]], report: inout WEReferenceReport) {
        guard let parallax = item.parallax, let capture = item.captures.first else { return }
        let folder = capture.folder
        guard let weFrom = theirs[folder]?[parallax.from], let oursFrom = ours[folder]?[parallax.from] else { return }
        var lines = ["", "Parallax: the image's shift from \(parallax.from) (x, y px; \(parallax.rect.description)).",
                     "", "| to | WE | ours |", "|---|---|---|"]
        for file in parallax.to {
            guard let we = theirs[folder]?[file], let frame = ours[folder]?[file] else { continue }
            let a = WEReferenceMetrics.shift(from: weFrom, to: we, rect: parallax.rect)
            let b = WEReferenceMetrics.shift(from: oursFrom, to: frame, rect: parallax.rect)
            lines.append("| \(file) | \(a.x), \(a.y) | \(b.x), \(b.y) |")
        }
        report.note(lines.joined(separator: "\n") + "\n")
    }
}
