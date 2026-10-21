import XCTest
import simd
@testable import OpenWallpaperEngine

/// The library halves of WE's models ground truth (docs/test-risks.md MG3, MG7), against the
/// captures of WE 2.8.0.42 in the peer's `models_gt` folder. Skipped without the library items
/// (`OWE_LIBRARY`) or the captures (`OWE_MODELS_GT`). With `OWE_GROUND_TRUTH_OUT` set, our frames
/// are written there next to WE's for a look.
final class ModelGroundTruthLibraryTests: XCTestCase {
    private static var library: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["OWE_LIBRARY"] ?? "/Volumes/980Pro/OpenWallpaperStorage")
    }

    private static var captures: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["OWE_MODELS_GT"]
            ?? "/Volumes/980Pro/dd-agentREF/peer/tools/peer/models_gt")
    }

    private static var out: URL? {
        ProcessInfo.processInfo.environment["OWE_GROUND_TRUTH_OUT"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
    }

    private func item(_ id: String) throws -> URL {
        let url = Self.library.appending(path: id, directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: url.appending(path: "project.json").path) else {
            throw XCTSkip("\(id) isn't in the library")
        }
        return url
    }

    private func scratch(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "owe-\(name)-\(UUID().uuidString)")
        addTeardownBlock {
            if FileManager.default.fileExists(atPath: url.path) {
                do { try FileManager.default.removeItem(at: url) } catch { XCTFail("\(url.path): \(error)") }
            }
        }
        return url
    }

    // MARK: - MG7

    /// 3734636606 with shadows high, against WE's RenderDoc capture (`mg7/mg7_report.txt`, the
    /// cloth's draw at event 15469): one directional light with three 512² cascades side by side in
    /// a 1536×512 atlas (`g_LFeature_ShadowProjectionTransform[i]` = (i/3, 0, 1/3, 1)), ambient and
    /// skylight (0.1255, 0.2588, 0.3804), the light's colour (6, 5.2941, 4.8941) and direction
    /// (0.5068, 0.7514, −0.4226), and the cloth's pixel ≈ (0.621, 0.177, 0.192) (158, 45, 49).
    func testTheClothUnderHighShadowsMatchesWEsCapture() throws {
        let directory = try item("3734636606")
        var settings = SceneRenderSettings()
        settings.shadows = .high
        let harness = try ModelSceneHarness(directory: directory, settings: settings, size: SIMD2(1920, 1080),
                                            storage: scratch("mg7"))
        defer { harness.close() }
        let probe = SceneDrawProbe()
        harness.renderer.drawProbe = probe
        try harness.settle(seconds: 10)
        for _ in 0..<60 { harness.frame() }
        let lighting = try XCTUnwrap(probe.lighting)
        XCTAssertEqual(lighting.shadows.extent, SIMD2(1536, 512))
        XCTAssertEqual(lighting.shadows.maps.count, 3)
        let transforms = try XCTUnwrap(lighting.arrays["g_LFeature_ShadowProjectionTransform"])
        let expected: [Float] = [0, 0, 1.0 / 3, 1, 1.0 / 3, 0, 1.0 / 3, 1, 2.0 / 3, 0, 1.0 / 3, 1]
        XCTAssertGreaterThanOrEqual(transforms.count, expected.count)
        for (index, value) in expected.enumerated() where index < transforms.count {
            XCTAssertEqual(transforms[index], value, accuracy: 1e-4, "transform float \(index)")
        }
        let we = SIMD3<Float>(0.1255, 0.2588, 0.3804)
        XCTAssertLessThan(simd_distance(lighting.ambient, we), 2e-3, "\(lighting.ambient)")
        XCTAssertLessThan(simd_distance(lighting.skylight, we), 2e-3, "\(lighting.skylight)")
        let color = try XCTUnwrap(lighting.arrays["g_LDirectional_Color"])
        let direction = try XCTUnwrap(lighting.arrays["g_LDirectional_Direction"])
        XCTAssertLessThan(simd_distance(SIMD3(color[0], color[1], color[2]), SIMD3(6, 5.2941, 4.8941)), 2e-3, "\(color)")
        XCTAssertLessThan(simd_distance(SIMD3(direction[0], direction[1], direction[2]), SIMD3(0.5068, 0.7514, -0.4226)),
                          2e-3, "\(direction)")
        let bytes = try Self.frame1080(harness)
        if let out = Self.out {
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            try WEReferenceImage(width: 1920, height: 1080, pixels: bytes).write(to: out.appending(path: "mg7-ours-high.png"))
        }
        // The cloth's red, over its pixels near WE's two (the cloth hangs where WE's did; its
        // physics moves it by a few pixels).
        let cloth = Self.meanRed(bytes, width: 1920, around: [SIMD2(1070, 410), SIMD2(1020, 330)], radius: 12)
        XCTAssertLessThan(simd_distance(cloth, SIMD3(158.4, 45.1, 49.0)), 6, "ours \(cloth)")
        XCTAssertEqual(harness.gpuErrors, [])
    }

    /// The mean colour of the cloth-red pixels (r > 100, g and b < 90) within `radius` of `points`.
    static func meanRed(_ bytes: [UInt8], width: Int, around points: [SIMD2<Int>], radius: Int) -> SIMD3<Float> {
        var sum = SIMD3<Float>(repeating: 0)
        var count: Float = 0
        for point in points {
            for y in (point.y - radius)...(point.y + radius) {
                for x in (point.x - radius)...(point.x + radius) {
                    let index = (y * width + x) * 4
                    guard index >= 0, index + 2 < bytes.count else { continue }
                    let pixel = SIMD3<Float>(Float(bytes[index]), Float(bytes[index + 1]), Float(bytes[index + 2]))
                    guard pixel.x > 100, pixel.y < 90, pixel.z < 90 else { continue }
                    sum += pixel
                    count += 1
                }
            }
        }
        return count > 0 ? sum / count : SIMD3(repeating: 0)
    }

    // MARK: - MG3

    /// WE's stills of the two library items with additive layers, 2, 4, 6 (and 8) s after load
    /// (`captures/MG3_library_<id>_t<s>.png`), against ours at the same times: the mean difference
    /// over the rigged figure's box and the frame's. Reports the numbers (and writes our frames with
    /// `OWE_GROUND_TRUTH_OUT`).
    func testTheAdditiveLibraryItemsAgainstWEsStills() throws {
        let cases: [(id: String, times: [Double], box: (x: Range<Int>, y: Range<Int>))] = [
            ("3803167460", [2, 4, 6], (1240..<1920, 0..<1030)),
            ("3803042537", [2, 4, 6, 8], (560..<1400, 0..<1030)),
        ]
        var report: [String] = []
        for entry in cases {
            let directory = try item(entry.id)
            let harness = try ModelSceneHarness(directory: directory, settings: SceneRenderSettings(), size: SIMD2(1920, 1080),
                                                storage: scratch("mg3-\(entry.id)"))
            defer { harness.close() }
            try harness.settle(seconds: 10)
            var time = 0.0
            for shot in entry.times {
                while time + 1.0 / 60 < shot {
                    harness.frame()
                    time += 1.0 / 30
                }
                let bytes = try Self.frame1080(harness)
                let still = Self.captures.appending(path: "captures/MG3_library_\(entry.id)_t\(Int(shot)).png")
                guard FileManager.default.fileExists(atPath: still.path) else { throw XCTSkip("no WE still \(still.lastPathComponent)") }
                let we = try WEReferenceImage.load(still)
                XCTAssertEqual(we.width, 1920)
                let box = Self.meanDifference(bytes, we.pixels, width: 1920, x: entry.box.x, y: entry.box.y)
                let frame = Self.meanDifference(bytes, we.pixels, width: 1920, x: 0..<1920, y: 0..<1030)
                report.append(String(format: "%@ t%.0f: figure box Δ %.1f, frame Δ %.1f", entry.id, shot, box, frame))
                if let out = Self.out {
                    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                    try WEReferenceImage(width: 1920, height: 1080, pixels: bytes)
                        .write(to: out.appending(path: "mg3-\(entry.id)-ours-t\(Int(shot)).png"))
                }
            }
            XCTAssertEqual(harness.gpuErrors, [], entry.id)
        }
        let text = report.joined(separator: "\n")
        add(XCTAttachment(string: text))
        if let out = Self.out { try text.write(to: out.appending(path: "mg3-report.txt"), atomically: true, encoding: .utf8) }
    }

    /// The shared frame at 1920×1080: an orthographic scene's frame is at the scene's size
    /// (3840×2160 for both MG3 items), box-filtered down, or scaled to cover.
    static func frame1080(_ harness: ModelSceneHarness) throws -> [UInt8] {
        let texture = try XCTUnwrap(harness.renderer.sharedFrame)
        let image = WEReferenceImage(width: texture.width, height: texture.height,
                                     pixels: try TextureUploadTests.read(texture, device: harness.device))
        if image.width == 1920, image.height == 1080 { return image.pixels }
        if image.width == 3840, image.height == 2160 { return image.reduced(by: 2).pixels }
        return image.covering(width: 1920, height: 1080).pixels
    }

    /// The mean absolute RGB difference (levels) over a box of two RGBA frames.
    static func meanDifference(_ a: [UInt8], _ b: [UInt8], width: Int, x: Range<Int>, y: Range<Int>) -> Double {
        var total = 0
        var count = 0
        for row in y {
            for column in x {
                let index = (row * width + column) * 4
                guard index + 2 < a.count, index + 2 < b.count else { continue }
                for channel in 0..<3 { total += abs(Int(a[index + channel]) - Int(b[index + channel])) }
                count += 3
            }
        }
        return count > 0 ? Double(total) / Double(count) : 0
    }
}
