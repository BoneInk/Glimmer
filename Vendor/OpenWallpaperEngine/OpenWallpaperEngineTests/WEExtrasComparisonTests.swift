import XCTest
import simd
@testable import OpenWallpaperEngine

/// The effect gallery's "extras" (tools/peer/effect_gallery/EXTRAS.md on the peer's branch: solid
/// layer blend modes, timelines, text font effects, refraction), drawn headlessly as WE captured
/// them: the gallery's settings (post-processing on, MSAA x2), the still at 5 s and, for a
/// timeline, 30 frames at 6 fps from there. It reports, it doesn't judge: our frames, WE | ours |
/// difference pictures and `report.tsv` (mean abs and SSIM against WE's still) go to
/// `OWE_WE_EXTRAS_OUT`.
///
/// Runs only when `OWE_WE_EXTRAS` (`TEST_RUNNER_OWE_WE_EXTRAS` through xcodebuild) points at a
/// folder holding `projects/fxx_*` (with their `.tex` files restored) and `we/<name>.png`, WE's
/// stills. `OWE_WE_EXTRAS_ONLY` lists project names without the `fxx_` prefix.
final class WEExtrasComparisonTests: XCTestCase {
    /// The capture's Windows taskbar.
    private static let comparedHeight = 1030
    private static let stillTime = 5.0
    private static let clipStep = 1.0 / 6
    private static let clipFrames = 30

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appending(path: "owe-we-extras-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch, FileManager.default.fileExists(atPath: scratch.path) {
            try FileManager.default.removeItem(at: scratch)
        }
    }

    func testExtrasAgainstWEsCaptures() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let root = environment["OWE_WE_EXTRAS"], !root.isEmpty else {
            throw XCTSkip("set OWE_WE_EXTRAS to the folder with projects/fxx_* and we/*.png")
        }
        let folder = URL(fileURLWithPath: root, isDirectory: true)
        let output = environment["OWE_WE_EXTRAS_OUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? folder.appending(path: "ours")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let only = Set((environment["OWE_WE_EXTRAS_ONLY"] ?? "").split(separator: ",").map(String.init))
        let projects = try FileManager.default.contentsOfDirectory(atPath: folder.appending(path: "projects").path)
            .filter { $0.hasPrefix("fxx_") }.sorted()
        var report = ["name\tmean abs vs WE\tSSIM vs WE"]
        for project in projects {
            let name = String(project.dropFirst(4))
            guard only.isEmpty || only.contains(name) else { continue }
            let directory = folder.appending(path: "projects/\(project)")
            let timeline = name.hasPrefix("timeline_")
            let frames = try render(directory, frames: timeline ? Self.clipFrames : 1)
            try frames[0].write(to: output.appending(path: "\(name)-ours.png"))
            if timeline {
                let clip = output.appending(path: "\(name)-clip")
                try FileManager.default.createDirectory(at: clip, withIntermediateDirectories: true)
                for (index, frame) in frames.enumerated() {
                    try frame.write(to: clip.appending(path: String(format: "f%03d.png", index + 1)))
                }
            }
            let capture = folder.appending(path: "we/\(name).png")
            guard FileManager.default.fileExists(atPath: capture.path) else {
                report.append("\(name)\tno capture\t")
                continue
            }
            let we = try WEReferenceImage.load(capture)
            let size = WEReferenceRenderer.size
            let taskbar = size.y - Self.comparedHeight
            let mask = WEReferenceMask(width: size.x, height: size.y, masks: [], taskbar: taskbar)
            let metrics = WEReferenceMetrics.compare(we: we, ours: frames[0], mask: mask,
                                                     grid: .init(columns: 4, rows: 2), taskbar: taskbar)
            report.append(String(format: "%@\t%.2f\t%.3f", name, metrics.meanAbs, metrics.ssim))
            let difference = WEReferenceMetrics.differenceImage(we: we, ours: frames[0], mask: mask)
            try WEReferenceImage.sideBySide([we.reduced(by: 2), frames[0].reduced(by: 2), difference])
                .write(to: output.appending(path: "\(name)-compare.png"))
        }
        let text = report.joined(separator: "\n") + "\n"
        try text.write(to: output.appending(path: "report.tsv"), atomically: true, encoding: .utf8)
        print("Extras against WE (output \(output.path)):\n\(text)")
    }

    /// The still at 5 s, then `frames − 1` more at 6 fps.
    private func render(_ directory: URL, frames: Int) throws -> [WEReferenceImage] {
        let data = try Data(contentsOf: directory.appending(path: "project.json"))
        let project = try decodeTolerant(WEProject.self, from: data)
        var settings = SceneRenderSettings()
        // WE's settings for the gallery: post-processing on, MSAA x2, full textures.
        settings.postProcessing = .enabled
        settings.particleBudget = .unlimited
        settings.textureReduction = 1
        settings.sceneDetail = .full
        settings.renderResolution = .yourDisplay
        settings.antiAliasing = .msaa_x2
        let renderer = WEReferenceRenderer(directory: directory, project: project, settings: settings,
                                           storage: scratch.appending(path: "storage-\(directory.lastPathComponent)"))
        let size = WEReferenceRenderer.size
        let centre = SIMD2(Double(size.x) / 2, Double(size.y) / 2)
        let shots = (0..<frames).map {
            WEReferenceRenderer.Shot(time: Self.stillTime + Double($0) * Self.clipStep, cursor: centre)
        }
        defer { Fixtures.removeStoredSettings(for: directory) }
        return try renderer.render(shots)
    }
}
