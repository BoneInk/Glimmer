import XCTest
import simd
@testable import OpenWallpaperEngine

/// Where x-ray's sprite lands for a cursor at known points (docs/test-risks.md FX1), against WE's
/// captures of the cursor request: projects built by `build_cursor_request.py`, captured by
/// `capture_cursor.ps1` (a still 1 s after the cursor moves to each point). x-ray at its defaults
/// draws its white halo where `g_PointerPosition` maps through `g_EffectTextureProjectionMatrix`
/// into the layer, so the halo's centre is the whole mapping: the pointer's y, the layer's
/// transform, the camera's zoom and parallax, and a scene cropped to the display.
///
/// Runs only when `OWE_CURSOR_REQUEST` (`TEST_RUNNER_OWE_CURSOR_REQUEST`) is the request folder
/// (`shots.json`, `projects/`); ours go to `<folder>/ours/`. With WE's captures in
/// `<folder>/cursor_captures/`, each halo's centre must be within `tolerance` of WE's.
final class WECursorCaptureTests: XCTestCase {
    /// Display pixels.
    private static let tolerance = 4.0
    /// capture_cursor.ps1: the wallpaper settles 4 s with the cursor parked, then each still is
    /// taken 1 s after the cursor moves.
    private static let parkTime = 4.0
    private static let stillInterval = 1.0
    private static let park = SIMD2<Double>(40, 40)

    private struct Shots: Decodable {
        var project: String
        var stills: [[Double]]
        /// A project without the effect whose stills are the controls, where the layer moves with
        /// the cursor (parallax); otherwise the parked frame is.
        var control: String?
    }

    func testXRayHaloFollowsTheCursorAsInWE() throws {
        guard let path = ProcessInfo.processInfo.environment["OWE_CURSOR_REQUEST"], !path.isEmpty else {
            throw XCTSkip("set OWE_CURSOR_REQUEST to the cursor request folder")
        }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        let ours = folder.appending(path: "ours")
        try FileManager.default.createDirectory(at: ours, withIntermediateDirectories: true)
        let captures = folder.appending(path: "cursor_captures")
        let list = try JSONDecoder().decode([Shots].self, from: Data(contentsOf: folder.appending(path: "shots.json")))
        var report = ["shot\tours x\tours y\tWE x\tWE y\tdistance"]
        for entry in list where entry.project.contains("xray") && !entry.stills.isEmpty {
            let points = entry.stills.map { SIMD2<Double>($0[0], $0[1]) }
            let frames = try render(folder.appending(path: "projects/\(entry.project)"), points: points)
            let controls = try entry.control.map { try render(folder.appending(path: "projects/\($0)"), points: points) }
            for (index, point) in points.enumerated() {
                let name = "\(entry.project)_\(Int(point.x))_\(Int(point.y))"
                try frames[index + 1].write(to: ours.appending(path: "\(name).png"))
                let control = controls?[index + 1] ?? frames[0]
                let centre = try XCTUnwrap(Self.haloCentre(frames[index + 1], control: control), "\(name): no halo in ours")
                var line = String(format: "%@\t%.1f\t%.1f", name, centre.x, centre.y)
                let weShot = captures.appending(path: "\(name).png")
                let weControl = captures.appending(path: entry.control.map { "\($0)_\(Int(point.x))_\(Int(point.y)).png" }
                    ?? "\(entry.project)_park.png")
                if FileManager.default.fileExists(atPath: weShot.path), FileManager.default.fileExists(atPath: weControl.path) {
                    let we = try WEReferenceImage.load(weShot)
                    let weCentre = Self.haloCentre(we, control: try WEReferenceImage.load(weControl))
                    if let weCentre {
                        let distance: Double = simd_distance(centre, weCentre)
                        line += String(format: "\t%.1f\t%.1f\t%.1f", weCentre.x, weCentre.y, distance)
                        XCTAssertLessThanOrEqual(distance, Self.tolerance, "\(name): the halo is \(distance) px from WE's")
                    } else {
                        line += "\tnone\t\t"
                        XCTFail("\(name): WE drew no halo")
                    }
                }
                report.append(line)
            }
        }
        let text = report.joined(separator: "\n") + "\n"
        try text.write(to: ours.appending(path: "report.tsv"), atomically: true, encoding: .utf8)
        print("Cursor request (output \(ours.path)):\n\(text)")
    }

    /// WE 2.8.0.42's halo centres from RenderDoc stills (we-test-wp-images,
    /// `cursor_captures_rd/halo_centres.tsv`): cursor, then the halo's centre, in display pixels.
    /// The centres were measured with a lower threshold than `haloCentre`, so ours may differ by
    /// a few pixels; 560,540 is clipped by the layer's edge. With camera parallax the halo stays
    /// under the cursor (the layer's effect projection includes the parallax shift): pre-parallax
    /// mapping put it 160 px off, at 960,540 for the cursor at 1100,620.
    private static let weHaloCentres: [String: [(cursor: SIMD2<Double>, halo: SIMD2<Double>)]] = [
        "curs_xray_plain": [(SIMD2(960, 540), SIMD2(961.9, 540.4)), (SIMD2(700, 350), SIMD2(702.5, 351.5)),
                            (SIMD2(1250, 760), SIMD2(1249.1, 760.0)), (SIMD2(560, 540), SIMD2(567.3, 540.1)),
                            (SIMD2(960, 180), SIMD2(964.7, 180.0))],
        "curs_xray_moved": [(SIMD2(1250, 460), SIMD2(1251.5, 459.5)), (SIMD2(1100, 340), SIMD2(1099.2, 340.9)),
                            (SIMD2(1400, 600), SIMD2(1401.8, 598.7)), (SIMD2(1000, 520), SIMD2(995.8, 522.9))],
        "curs_xray_zoom": [(SIMD2(960, 540), SIMD2(963.1, 540.9)), (SIMD2(1200, 700), SIMD2(1199.4, 699.8)),
                           (SIMD2(700, 380), SIMD2(703.8, 381.1))],
        "curs_xray_crop": [(SIMD2(960, 540), SIMD2(961.9, 540.4)), (SIMD2(1200, 800), SIMD2(1198.1, 799.9)),
                           (SIMD2(700, 250), SIMD2(703.4, 251.8))],
        "curs_xray_parallax": [(SIMD2(960, 540), SIMD2(961.9, 540.4)), (SIMD2(1100, 620), SIMD2(1098.7, 619.9)),
                               (SIMD2(840, 460), SIMD2(844.3, 461.2))],
    ]
    /// Display pixels, against `weHaloCentres`.
    private static let measuredTolerance = 6.0

    /// FX1: every case (plain, moved, zoomed, cropped, parallax) against WE's measured centres.
    func testXRayHaloMatchesWEMeasuredCentres() throws {
        guard let path = ProcessInfo.processInfo.environment["OWE_CURSOR_REQUEST"], !path.isEmpty else {
            throw XCTSkip("set OWE_CURSOR_REQUEST to the cursor request folder")
        }
        let projects = URL(fileURLWithPath: path, isDirectory: true).appending(path: "projects")
        for (project, cases) in Self.weHaloCentres.sorted(by: { $0.key < $1.key }) {
            let points: [SIMD2<Double>] = cases.map(\.cursor)
            let frames = try render(projects.appending(path: project), points: points)
            // Parallax moves the layer with the cursor: the control is the same scene without x-ray.
            let controls = project.contains("parallax")
                ? try render(projects.appending(path: "curs_parallax_none"), points: points) : nil
            for (index, entry) in cases.enumerated() {
                let name = "\(project)_\(Int(entry.cursor.x))_\(Int(entry.cursor.y))"
                let control = controls?[index + 1] ?? frames[0]
                let centre = try XCTUnwrap(Self.haloCentre(frames[index + 1], control: control), "\(name): no halo")
                let distance: Double = simd_distance(centre, entry.halo)
                XCTAssertLessThanOrEqual(distance, Self.measuredTolerance,
                                         "\(name): the halo is at \(centre), \(distance) px from WE's \(entry.halo)")
            }
        }
    }

    /// The parked frame, then one frame per point.
    private func render(_ directory: URL, points: [SIMD2<Double>]) throws -> [WEReferenceImage] {
        let data = try Data(contentsOf: directory.appending(path: "project.json"))
        let project = try decodeTolerant(WEProject.self, from: data)
        var settings = SceneRenderSettings()
        settings.postProcessing = .enabled
        settings.particleBudget = .unlimited
        settings.textureReduction = 1
        settings.sceneDetail = .full
        settings.renderResolution = .yourDisplay
        settings.antiAliasing = .msaa_x2
        let storage = FileManager.default.temporaryDirectory.appending(path: "owe-cursor-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: storage) } // Scratch storage; a leftover is harmless.
        var shots = [WEReferenceRenderer.Shot(time: Self.parkTime, cursor: Self.park)]
        for (index, point) in points.enumerated() {
            let time: Double = Self.parkTime + Double(index + 1) * Self.stillInterval
            shots.append(WEReferenceRenderer.Shot(time: time, cursor: point))
        }
        let renderer = WEReferenceRenderer(directory: directory, project: project, settings: settings, storage: storage)
        defer { Fixtures.removeStoredSettings(for: directory) }
        return try renderer.render(shots)
    }

    /// The centre of the pixels the halo brightened: the frame against the parked one, weighted by
    /// how much brighter each pixel is (over 24 of 765), in display pixels.
    static func haloCentre(_ image: WEReferenceImage, control: WEReferenceImage) -> SIMD2<Double>? {
        var weight = 0.0
        var sum = SIMD2<Double>.zero
        let height = min(image.height, control.height)
        for y in 0..<height {
            for x in 0..<min(image.width, control.width) {
                let i = (y * image.width + x) * 4, j = (y * control.width + x) * 4
                var gain = 0
                for c in 0..<3 { gain += Int(image.pixels[i + c]) - Int(control.pixels[j + c]) }
                guard gain > 24 else { continue }
                let w = Double(gain)
                weight += w
                sum += SIMD2<Double>(Double(x) + 0.5, Double(y) + 0.5) * w
            }
        }
        return weight > 0 ? sum / weight : nil
    }
}
