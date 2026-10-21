import XCTest
import simd
@testable import OpenWallpaperEngine

/// The two captured puppets (the Knight 2515150033 and the Cyberpunk Samurai 2321732083) against
/// WE's 5-second puppet clips' stills (tools/peer README, batch 3: `<id>/puppet5s`), drawn by
/// `WEReferenceRenderer` at the stills' times. It reports, it doesn't judge: the metrics go to the
/// log and `OWE_WE_REFERENCE_OUT/puppets` (WE | ours | difference pictures). Both rigs' bind pose
/// is their sheet laid out flat; WE shows them assembled by their animation layers' pose, which
/// skinning draws (docs/models-plan.md M6, P2). The motion test measures how much the frame moves
/// over 5 s, as `tools/peer/analyze.py` did for WE's clips. Runs only with `OWE_WE_REFERENCE` and
/// the library.
final class ScenePuppetReferenceTests: XCTestCase {
    func testPuppetsAgainstWEsPuppetClips() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let root = environment["OWE_WE_REFERENCE"], !root.isEmpty else {
            throw XCTSkip("set OWE_WE_REFERENCE to the captures' tools/peer folder")
        }
        let captures = URL(fileURLWithPath: root, isDirectory: true)
        let library = LibrarySweepTests.libraryRoot
        try XCTSkipUnless(FileManager.default.fileExists(atPath: library.path), "wallpaper library not present")
        let output = (environment["OWE_WE_REFERENCE_OUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appending(path: "owe-we-reference-out")).appending(path: "puppets")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let storage = FileManager.default.temporaryDirectory.appending(path: "owe-puppet-reference-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: storage) } // scratch cleanup
        let config = try WEReferenceConfig.load()
        var report = "item\tstill\tmean abs Δ\tSSIM\n"
        var compared = 0
        for id in ["2515150033", "2321732083"] {
            let directory = library.appending(path: id, directoryHint: .isDirectory)
            let folder = captures.appending(path: "\(id)/puppet5s", directoryHint: .isDirectory)
            guard FileManager.default.fileExists(atPath: folder.path),
                  let data = FileManager.default.contents(atPath: directory.appending(path: "project.json").path) else {
                report += "\(id)\tno capture or not in the library\n"
                continue
            }
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
            let project = try decodeTolerant(WEProject.self, from: Data(text.utf8))
            var settings = SceneRenderSettings()
            settings.postProcessing = .enabled
            settings.reflection = true
            settings.particleBudget = .unlimited
            settings.textureReduction = 1
            settings.sceneDetail = .full
            settings.renderResolution = .yourDisplay
            let size = WEReferenceRenderer.size
            let center = SIMD2(Double(size.x) / 2, Double(size.y) / 2)
            let renderer = WEReferenceRenderer(directory: directory, project: project, settings: settings, storage: storage)
            let stills = [("still1.png", 10.0), ("still2.png", 12.0)]
            let frames = try renderer.render(stills.map { WEReferenceRenderer.Shot(time: $0.1, cursor: center) })
            let mask = WEReferenceMask(width: size.x, height: size.y, masks: [], taskbar: config.taskbarHeight)
            for ((file, _), frame) in zip(stills, frames) {
                let url = folder.appending(path: file)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                let we = try WEReferenceImage.load(url)
                let metrics = WEReferenceMetrics.compare(we: we, ours: frame, mask: mask, grid: config.grid,
                                                         taskbar: config.taskbarHeight)
                report += "\(id)\t\(file)\t\(String(format: "%.1f", metrics.meanAbs))\t"
                    + "\(String(format: "%.3f", metrics.ssim))\n"
                let difference = WEReferenceMetrics.differenceImage(we: we, ours: frame, mask: mask)
                try WEReferenceImage.sideBySide([we.reduced(by: 2), frame.reduced(by: 2), difference])
                    .write(to: output.appending(path: "\(id)-puppet5s-\((file as NSString).deletingPathExtension)-compare.png"))
                compared += 1
            }
        }
        XCTAssertGreaterThan(compared, 0, "no puppet still was compared")
        try report.write(to: output.appending(path: "report.tsv"), atomically: true, encoding: .utf8)
        print("Puppets against WE's puppet5s clips:\n\(report)")
    }

    /// `analyze.py`'s puppet motion: the frames every 0.5 s over 5 s, grey, 480×270 (the top 255
    /// rows, above the taskbar), and the mean absolute difference between consecutive frames. WE's
    /// comes from its `puppet5s/clip.mp4` (through ffmpeg), ours from renders at 10…14.5 s. The
    /// phase isn't comparable (WE's clip starts at an unknown clip time), the amount of motion is.
    func testPuppetMotionAgainstWEsClips() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let root = environment["OWE_WE_REFERENCE"], !root.isEmpty else {
            throw XCTSkip("set OWE_WE_REFERENCE to the captures' tools/peer folder")
        }
        let library = LibrarySweepTests.libraryRoot
        try XCTSkipUnless(FileManager.default.fileExists(atPath: library.path), "wallpaper library not present")
        let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first(where: FileManager.default.isExecutableFile)
        let output = (environment["OWE_WE_REFERENCE_OUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appending(path: "owe-we-reference-out")).appending(path: "puppets")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let storage = FileManager.default.temporaryDirectory.appending(path: "owe-puppet-motion-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: storage) } // scratch cleanup
        var report = "item\tsource\tmean frame diff per 0.5 s\tmean\n"
        for id in ["2515150033", "2321732083"] {
            let directory = library.appending(path: id, directoryHint: .isDirectory)
            guard let data = FileManager.default.contents(atPath: directory.appending(path: "project.json").path) else { continue }
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
            let project = try decodeTolerant(WEProject.self, from: Data(text.utf8))
            var settings = SceneRenderSettings()
            settings.postProcessing = .enabled
            settings.reflection = true
            settings.particleBudget = .unlimited
            settings.textureReduction = 1
            settings.sceneDetail = .full
            settings.renderResolution = .yourDisplay
            let size = WEReferenceRenderer.size
            let center = SIMD2(Double(size.x) / 2, Double(size.y) / 2)
            let renderer = WEReferenceRenderer(directory: directory, project: project, settings: settings, storage: storage)
            let frames = try renderer.render((0..<10).map { WEReferenceRenderer.Shot(time: 10 + Double($0) * 0.5, cursor: center) })
            let ours = Self.motion(frames.map(Self.grey))
            report += "\(id)\tours\t\(ours.map { String(format: "%.2f", $0) }.joined(separator: " "))\t"
                + "\(String(format: "%.2f", ours.reduce(0, +) / Double(max(ours.count, 1))))\n"
            let clip = URL(fileURLWithPath: root).appending(path: "\(id)/puppet5s/clip.mp4")
            if let ffmpeg, FileManager.default.fileExists(atPath: clip.path) {
                let we = Self.motion(try Self.clipFrames(clip, ffmpeg: ffmpeg))
                report += "\(id)\tWE\t\(we.map { String(format: "%.2f", $0) }.joined(separator: " "))\t"
                    + "\(String(format: "%.2f", we.reduce(0, +) / Double(max(we.count, 1))))\n"
            }
        }
        try report.write(to: output.appending(path: "motion.tsv"), atomically: true, encoding: .utf8)
        print("Puppet motion against WE's puppet5s clips:\n\(report)")
    }

    /// 480×270 grey, top 255 rows, from a 1920×1080 frame (4×4 box average).
    static func grey(_ image: WEReferenceImage) -> [Float] {
        var out = [Float](repeating: 0, count: 480 * 255)
        for y in 0..<255 {
            for x in 0..<480 {
                var sum: Float = 0
                for dy in 0..<4 {
                    for dx in 0..<4 {
                        let index = ((y * 4 + dy) * image.width + x * 4 + dx) * 4
                        sum += 0.299 * Float(image.pixels[index]) + 0.587 * Float(image.pixels[index + 1])
                            + 0.114 * Float(image.pixels[index + 2])
                    }
                }
                out[y * 480 + x] = sum / 16
            }
        }
        return out
    }

    static func motion(_ frames: [[Float]]) -> [Double] {
        zip(frames, frames.dropFirst()).map { (a: [Float], b: [Float]) -> Double in
            var sum: Float = 0
            for (x, y) in zip(a, b) { sum += abs(x - y) }
            return Double(sum) / Double(a.count)
        }
    }

    /// WE's clip at 2 fps as `grey` frames.
    static func clipFrames(_ clip: URL, ffmpeg: String) throws -> [[Float]] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = ["-loglevel", "error", "-i", clip.path, "-vf", "fps=2,scale=480:270,format=gray",
                             "-f", "rawvideo", "-"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let frameBytes = 480 * 270
        return stride(from: 0, to: data.count - frameBytes + 1, by: frameBytes).map { start in
            (0..<(480 * 255)).map { Float(data[data.startIndex + start + $0]) }
        }
    }
}
