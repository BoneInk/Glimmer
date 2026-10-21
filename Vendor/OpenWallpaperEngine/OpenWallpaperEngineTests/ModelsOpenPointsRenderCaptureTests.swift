import XCTest
import simd
import ImageIO
@testable import OpenWallpaperEngine

/// docs/models-plan.md §5.10, 5.11, 5.17, 5.18, 5.19, 5.20, 5.22 and 5.31 against WE 2.8.42's captures
/// of running wallpapers (we-test-wp-images, tools/peer/requests/owe-beta3/models-open: 510, 511,
/// 517-puppet-cull, 518-fade-threshold, 519b, 520, 522 and 531b, a README, the stills and the projects each).
/// The camera captures' gradient image isn't in the projects; a test draws its own, opaque and
/// 1024 px square as WE's, so only its edges are measured. The projects are in `Tests/Fixtures/Models/OpenPoints`
/// without their binaries, which come from the repository's fixtures: the box from WE's import of
/// `rootmotion_box` (models_gt/mg4), the rope from bone-physics A (`Models/BonePhysics/rope-A.mdl`)
/// with the texture-channels capture's `rope.tex`. Each is drawn headlessly at 1920×1080 by the
/// real loader and renderer (`ModelSceneHarness`); WE's shaders come from `OWE_ASSETS`, so the
/// tests skip without them. With `OWE_WE_REFERENCE` the stills are measured the same way.
final class ModelsOpenPointsRenderCaptureTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        _ = try Fixtures.assets()
        scratch = FileManager.default.temporaryDirectory.appending(path: "owe-models-open-\(UUID().uuidString)",
                                                                   directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch, FileManager.default.fileExists(atPath: scratch.path) {
            try FileManager.default.removeItem(at: scratch)
        }
    }

    // MARK: - 5.10 Text objects' `depthtest`

    /// A perspective scene: the box, and "DEPTH TEST" behind it, turned 45°. With the text's
    /// `depthtest` "enabled" the box hides the text behind it; "disabled" draws the text over it.
    /// Text over the box shows as bright pixels with the box's dark faces on both sides in the row.
    func testATextObjectsDepthTestLetTheBoxHideIt() throws {
        let enabled = try frame("510-text-depth-enabled", binaries: Self.box)
        let disabled = try frame("510-text-depth-disabled", binaries: Self.box)
        XCTAssertGreaterThan(Self.drawnPixels(enabled), 1000, "the box and the text draw")
        let hidden = Self.textOverBox(enabled), shown = Self.textOverBox(disabled)
        XCTAssertLessThan(hidden, 20, "enabled: the box occludes the text")
        XCTAssertGreaterThan(shown, 200, "disabled: the text is drawn over the box")

        guard let folder = ModelsOpenPointsCaptureTests.capture("510-text-depthtest") else { return }
        let weEnabled = try WEReferenceImage.load(folder.appending(path: "mo2_510_text_depth_enabled.png"))
        let weDisabled = try WEReferenceImage.load(folder.appending(path: "mo2_510_text_depth_disabled.png"))
        XCTAssertLessThan(Self.textOverBox(Image(weEnabled)), 20, "WE: occluded")
        XCTAssertGreaterThan(Self.textOverBox(Image(weDisabled)), 200, "WE: drawn over")
    }

    // MARK: - 5.11 Missing vertex attributes

    /// The box through a custom shader reading `a_Color` and `a_TexCoordC1`, which the mesh lacks:
    /// WE draws nothing of it (only the clear colour) and logs nothing. The app skips the draw too.
    /// The control (not captured in WE) reads only `a_Position` and draws: it declares `a_Color`
    /// without reading it, and only the inputs the compiled stage reads count, as in D3D11's
    /// `CreateInputLayout` against the compiled shader's input signature.
    func testAMeshLackingAShaderInputIsNotDrawn() throws {
        let missing = try frame("511-missing-attribute", binaries: Self.box)
        XCTAssertEqual(Self.drawnPixels(missing), 0, "only the clear colour")

        let control = try project("511-missing-attribute", binaries: Self.box, as: "511-control")
        try """
        attribute vec3 a_Position;
        attribute vec4 a_Color;
        uniform mat4 g_ModelViewProjectionMatrix;
        void main() {
        	gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
        }
        """.write(to: control.appending(path: "shaders/probe_missing.vert"), atomically: true, encoding: .utf8)
        try """
        void main() {
        	gl_FragColor = vec4(0.0, 0.0, 0.0, 1.0);
        }
        """.write(to: control.appending(path: "shaders/probe_missing.frag"), atomically: true, encoding: .utf8)
        XCTAssertGreaterThan(Self.drawnPixels(try render(control)), 1000, "the control draws the box")

        guard let folder = ModelsOpenPointsCaptureTests.capture("511-missing-attribute") else { return }
        let still = try WEReferenceImage.load(folder.appending(path: "mo2_511_missing_attr.png"))
        XCTAssertEqual(Self.drawnPixels(Image(still)), 0, "WE: only the clear colour")
    }

    // MARK: - 5.31 A script's `origin` on a puppet image

    /// The rope puppet whose `origin` script sets `x = 760 + min(t, 4) · 100` moves in a running
    /// wallpaper: its unswung top (row 300) is centred on the script's x, 860 at 1 s, 1060 at 3 s,
    /// 1160 at 5.5 s (the app's 856.5, 1056.5 and 1160, the bar a few px left of the origin). WE's stills are centred on 855.5, 1055.5 and 1159.5 (the bar's x 824–887,
    /// 1024–1087 and 1128–1191), the script's x within the capture's timing (a few px, under 0.05 s,
    /// before the 4 s hold; exact after it).
    func testAScriptsOriginMovesAPuppetImage() throws {
        let directory = try project("531b-puppet-origin-script", binaries: [
            "Models/BonePhysics/rope-A.mdl": "models/rope_puppet.mdl",
            "Models/TextureChannels/materials/rope.tex": "materials/rope.tex",
        ])
        let harness = try ModelSceneHarness(directory: directory, settings: SceneRenderSettings(), size: SIMD2(1920, 1080),
                                            storage: scratch.appending(path: "storage", directoryHint: .isDirectory))
        defer { harness.close() }
        XCTAssertTrue(harness.waitForPipelines(), "the pipelines compile")
        // The puppet's mesh pipeline is one of them: until it lands the image is transparent.
        XCTAssertGreaterThan(harness.renderer.puppetMeshDraws, 0, "the puppet's mesh drew before the clock runs")
        var time = 0.0
        for shot in [1.0, 3, 5.5] {
            while time + 1.0 / 60 < shot {
                harness.frame()
                time += 1.0 / 30
            }
            let bytes = try TextureUploadTests.read(try XCTUnwrap(harness.renderer.sharedFrame), device: harness.device)
            let centre = try XCTUnwrap(Self.rowCentre(Image(width: 1920, height: 1080, pixels: bytes), row: 300), "t \(shot)")
            XCTAssertEqual(centre, 760 + min(shot, 4) * 100, accuracy: 5, "t \(shot)")
        }
        XCTAssertEqual(harness.gpuErrors, [])

        guard let folder = ModelsOpenPointsCaptureTests.capture("531b-puppet-origin-script") else { return }
        for (shot, low, high) in [(1.0, 850.0, 862.0), (3, 1050, 1062), (5.5, 1157, 1163)] {
            let still = try WEReferenceImage.load(folder.appending(path: "mo2_531b_puppet_origin_script_t\(shot == 5.5 ? "5.5" : "\(Int(shot))").png"))
            let centre = try XCTUnwrap(Self.rowCentre(Image(still), row: 300), "WE t \(shot)")
            XCTAssertTrue((low...high).contains(centre), "WE t \(shot): \(centre)")
        }
    }

    // MARK: - 5.17 A `cullmode` "normal" puppet

    /// WE's capture (517-puppet-cull): the rope puppet, its material's `cullmode` "normal", draws
    /// at (960, 540) scaled 1 1 1 and nothing of it shows scaled −1 1 1. WE's editor winds the
    /// rig counter-clockwise; drawn by the real loader and renderer, the upright rope shows and
    /// the mirrored one is culled.
    func testANormalCullPuppetDrawsUprightAndIsCulledMirrored() throws {
        func rope(scale: String) throws -> Image {
            let directory = try project("531b-puppet-origin-script", binaries: [
                "Models/BonePhysics/rope-A.mdl": "models/rope_puppet.mdl",
                "Models/TextureChannels/materials/rope.tex": "materials/rope.tex",
            ], as: "517-cull-normal-\(scale)")
            try Self.editJSON(directory.appending(path: "scene.json")) { scene in
                var objects = scene["objects"] as! [[String: Any]]
                objects[0]["origin"] = "960 540 0"
                objects[0]["scale"] = scale
                scene["objects"] = objects
            }
            try Self.editJSON(directory.appending(path: "materials/rope.json")) { material in
                var passes = material["passes"] as! [[String: Any]]
                passes[0]["cullmode"] = "normal"
                material["passes"] = passes
            }
            return try render(directory)
        }
        XCTAssertGreaterThan(Self.drawnPixels(try rope(scale: "1 1 1")), 1000, "the upright rope draws")
        XCTAssertEqual(Self.drawnPixels(try rope(scale: "-1 1 1")), 0, "the mirrored rope is culled")

        guard let folder = ModelsOpenPointsCaptureTests.capture("517-puppet-cull") else { return }
        let upright = try WEReferenceImage.load(folder.appending(path: "mo_517_cull_normal.png"))
        let mirrored = try WEReferenceImage.load(folder.appending(path: "mo_517_cull_normal_flipx.png"))
        XCTAssertGreaterThan(Self.drawnPixels(Image(upright)), 1000, "WE: the upright rope draws")
        XCTAssertEqual(Self.drawnPixels(Image(mirrored)), 0, "WE: the mirrored rope is culled")
    }

    // MARK: - 5.18 A model's opacity

    /// The editor's Opacity (Material → Shader) writes a lowercase `alpha` into the pass's
    /// `constantshadervalues`, generic4's `g_TintAlpha`: the translucent box's contrast against
    /// the clear colour scales linearly with it (WE: 102, 51, 10, 1, 0 at 1, 0.5, 0.1, 0.01, 0),
    /// and the draw is issued at 0 too. A capital `Alpha` and the object's `alpha` change nothing.
    func testAModelsOpacityIsTheLowercaseAlphaWithoutAThreshold() throws {
        func box(_ name: String, constants: [String: Any], objectAlpha: Double = 1) throws -> (image: Image, draws: Int) {
            let directory = try project("518-alpha", binaries: Self.box, as: name)
            try Self.editJSON(directory.appending(path: "materials/models/rootmotion_box/red.json")) { material in
                var passes = material["passes"] as! [[String: Any]]
                passes[0]["constantshadervalues"] = constants.merging(["Color": "1 1 1"]) { a, _ in a }
                material["passes"] = passes
            }
            try Self.editJSON(directory.appending(path: "scene.json")) { scene in
                var objects = scene["objects"] as! [[String: Any]]
                objects[0]["alpha"] = objectAlpha
                scene["objects"] = objects
            }
            let harness = try ModelSceneHarness(directory: directory, settings: SceneRenderSettings(), size: SIMD2(1920, 1080),
                                                storage: scratch.appending(path: "storage", directoryHint: .isDirectory))
            defer { harness.close() }
            try harness.settle(seconds: 10)
            let bytes = try TextureUploadTests.read(try XCTUnwrap(harness.renderer.sharedFrame), device: harness.device)
            XCTAssertEqual(harness.gpuErrors, [], name)
            return (Image(width: 1920, height: 1080, pixels: bytes), harness.models?.meshDraws["17"] ?? 0)
        }
        let clear = try box("alpha-0", constants: ["Alpha": 1, "alpha": 0])
        XCTAssertGreaterThan(clear.draws, 0, "the box is drawn at alpha 0")
        XCTAssertEqual(Self.maxDelta(clear.image, Image(width: 1920, height: 1080, pixels: Self.cleared(clear.image))), 0,
                       "alpha 0 leaves the clear colour")
        let full = Self.maxDelta(try box("alpha-1", constants: ["Alpha": 1, "alpha": 1]).image, clear.image)
        XCTAssertGreaterThan(full, 60)
        for alpha in [0.5, 0.1, 0.01] {
            let faded = try box("alpha-\(alpha)", constants: ["Alpha": 1, "alpha": alpha])
            XCTAssertGreaterThan(faded.draws, 0)
            XCTAssertEqual(Double(Self.maxDelta(faded.image, clear.image)), alpha * Double(full), accuracy: 1.5, "alpha \(alpha)")
        }
        // The inert keys: capital `Alpha` 0 and the object's `alpha` 0 draw the box at full opacity.
        XCTAssertEqual(Self.maxDelta(try box("capital", constants: ["Alpha": 0]).image, clear.image), full, "capital Alpha")
        XCTAssertEqual(Self.maxDelta(try box("object", constants: ["Alpha": 1, "alpha": 1], objectAlpha: 0).image, clear.image),
                       full, "object alpha")

        guard let folder = ModelsOpenPointsCaptureTests.capture("518-fade-threshold") else { return }
        let weClear = Image(try WEReferenceImage.load(folder.appending(path: "mo2_518e_alpha_0.png")))
        for (file, expected) in [("1", 102), ("0p5", 51), ("0p1", 10), ("0p01", 1), ("0p001", 0)] {
            let still = Image(try WEReferenceImage.load(folder.appending(path: "mo2_518e_alpha_\(file).png")))
            XCTAssertEqual(Self.maxDelta(still, weClear), expected, accuracy: 1, "WE alpha \(file)")
        }
    }

    // MARK: - 5.19, 5.20, 5.22 Camera paths in an orthographic scene

    /// The image's left edge when no camera moves it (WE: x 525–1394).
    private static let restEdge = 525

    /// An editor-made path (eye and centre x 0 → 400 → 0 over 60 frames at 30 fps, mode single)
    /// on a camera layer with `"visible": {"value": true}` moves an orthographic scene's view: the
    /// image is 400 px left at 1 s and back at 2 s, and the random queue picks the path again (WE:
    /// 391 px at its t = 1 still, 400 in 520's; models-open/519b). Without `visible` nothing plays.
    func testACameraPathMovesAnOrthographicScene() throws {
        let edges = try leftEdges(try gradientProject("519b-ortho-campath"), at: [0.5, 1, 1.5, 2, 3])
        XCTAssertEqual(edges[1], Self.restEdge - 400, accuracy: 8, "t 1")
        for index in [0, 2] { XCTAssertTrue((Self.restEdge - 300...Self.restEdge - 100).contains(edges[index]), "\(edges)") }
        XCTAssertEqual(edges[3], Self.restEdge, accuracy: 8, "t 2: the path's end")
        XCTAssertEqual(edges[4], Self.restEdge - 400, accuracy: 8, "t 3: played again")

        let hidden = try gradientProject("519b-ortho-campath", as: "519b-no-visible") { scene in
            var objects = scene["objects"] as! [[String: Any]]
            objects[1].removeValue(forKey: "visible")
            scene["objects"] = objects
        }
        XCTAssertEqual(try leftEdges(hidden, at: [0.5, 1, 1.5]), [Self.restEdge, Self.restEdge, Self.restEdge], "no visible")

        guard let folder = ModelsOpenPointsCaptureTests.capture("519b-ortho-camera-path") else { return }
        let peak = try XCTUnwrap(Self.leftEdge(Image(try WEReferenceImage.load(folder.appending(path: "mo2_519b_ortho_campath_t1.png")))))
        XCTAssertTrue((125...140).contains(peak), "WE t 1: \(peak)")
        let early = try XCTUnwrap(Self.leftEdge(Image(try WEReferenceImage.load(folder.appending(path: "mo2_519b_ortho_campath_t0.5.png")))))
        XCTAssertTrue((Self.restEdge - 300...Self.restEdge - 100).contains(early), "WE t 0.5: \(early)")
    }

    /// A script writing the camera layer's origin every frame (x = −400·min(t/5, 1)) shows only
    /// without a path: with one the view follows the path alone (WE: 125 px at 1 and 3 s, at rest
    /// at 6 s); without, the image moves right 80, 240 and 400 px at 1, 3 and 6 s (WE: 80, 234, 400).
    func testAPlayingPathWinsOverACameraScript() throws {
        let path = try leftEdges(try gradientProject("520-writeback-vs-script"), at: [1, 2, 3, 6])
        XCTAssertEqual(path[0], Self.restEdge - 400, accuracy: 8, "t 1")
        XCTAssertEqual(path[1], Self.restEdge, accuracy: 8, "t 2")
        XCTAssertEqual(path[2], Self.restEdge - 400, accuracy: 8, "t 3")
        XCTAssertEqual(path[3], Self.restEdge, accuracy: 8, "t 6")
        let script = try leftEdges(try gradientProject("520b-script-only"), at: [1, 3, 6])
        for (edge, shift) in zip(script, [80, 240, 400]) { XCTAssertEqual(edge, Self.restEdge + shift, accuracy: 10, "\(script)") }

        guard let folder = ModelsOpenPointsCaptureTests.capture("520-writeback-vs-script") else { return }
        for (file, expected) in [("520_writeback_vs_script_t1", 125), ("520_writeback_vs_script_t3", 125),
                                 ("520_writeback_vs_script_t6", 525), ("520b_script_only_t1", 605),
                                 ("520b_script_only_t3", 765), ("520b_script_only_t6", 925)] {
            let still = Image(try WEReferenceImage.load(folder.appending(path: "mo2_\(file).png")))
            XCTAssertEqual(try XCTUnwrap(Self.leftEdge(still)), expected, accuracy: 10, "WE \(file)")
        }
    }

    /// Two eye/centre x keys at frame 30 (400, then −400): the first wins, the view reaches +400
    /// at 1 s and eases back, the image never moves right of rest. A path with `visible` false
    /// doesn't play (models-open/522).
    func testTheFirstOfTwoKeysAtAFrameWinsAndAHiddenPathDoesntPlay() throws {
        let edges = try leftEdges(try gradientProject("522-samekey"), at: (1...60).map { Double($0) / 30 })
        XCTAssertEqual(edges[29], Self.restEdge - 400, accuracy: 8, "frame 30")
        XCTAssertLessThanOrEqual(edges.max() ?? .max, Self.restEdge + 2, "−400 is never reached")
        XCTAssertEqual(try leftEdges(try gradientProject("522-path-hidden"), at: [0.5, 1, 1.5]),
                       [Self.restEdge, Self.restEdge, Self.restEdge], "visible false")

        guard let folder = ModelsOpenPointsCaptureTests.capture("522-keys-edge") else { return }
        for time in ["0.3", "0.9", "1.4", "1.8"] {
            let still = Image(try WEReferenceImage.load(folder.appending(path: "mo2_522_samekey_t\(time).png")))
            XCTAssertLessThan(try XCTUnwrap(Self.leftEdge(still)), Self.restEdge, "WE t \(time)")
        }
        let still = Image(try WEReferenceImage.load(folder.appending(path: "mo2_522_path_hidden_t1.png")))
        XCTAssertEqual(Self.leftEdge(still), Self.restEdge, "WE: hidden")
    }

    // MARK: - Helpers

    /// A camera capture's project with a gradient image in place of WE's, its scene edited.
    private func gradientProject(_ name: String, as copy: String? = nil,
                                 scene edit: ((inout [String: Any]) -> Void)? = nil) throws -> URL {
        let directory = try project(name, binaries: [:], as: copy)
        try Self.writeGradient(to: directory.appending(path: "materials/gradient.png"))
        if let edit { try Self.editJSON(directory.appending(path: "scene.json"), edit) }
        return directory
    }

    /// The image's left edge on row 540 at each time in `shots` (ascending seconds, 30 fps).
    private func leftEdges(_ directory: URL, at shots: [Double]) throws -> [Int] {
        let harness = try ModelSceneHarness(directory: directory, settings: SceneRenderSettings(), size: SIMD2(1920, 1080),
                                            storage: scratch.appending(path: "storage", directoryHint: .isDirectory))
        defer { harness.close() }
        var time = 0.0
        var edges: [Int] = []
        for shot in shots {
            while time + 1.0 / 60 < shot {
                harness.frame()
                time += 1.0 / 30
            }
            let bytes = try TextureUploadTests.read(try XCTUnwrap(harness.renderer.sharedFrame), device: harness.device)
            edges.append(try XCTUnwrap(Self.leftEdge(Image(width: 1920, height: 1080, pixels: bytes)), "t \(shot)"))
        }
        XCTAssertEqual(harness.gpuErrors, [], directory.lastPathComponent)
        return edges
    }

    /// The first pixel of `row` that differs from the background (the right edge's colour).
    static func leftEdge(_ image: Image, row: Int = 540) -> Int? {
        let background = image.range(image.width - 1, row)
        return (0..<image.width).first {
            let pixel = image.range($0, row)
            return abs(pixel.low - background.low) + abs(pixel.high - background.high) > 24
        }
    }

    /// The largest channel difference between two frames above the taskbar's rows.
    static func maxDelta(_ a: Image, _ b: Image) -> Int {
        var largest = 0
        for index in 0..<(rows * a.width * 4) where index % 4 != 3 {
            largest = max(largest, abs(Int(a.pixels[index]) - Int(b.pixels[index])))
        }
        return largest
    }

    /// A frame of `image`'s top-left pixel everywhere (its clear colour).
    static func cleared(_ image: Image) -> [UInt8] {
        let pixel = Array(image.pixels[0..<4])
        return Array([[UInt8]](repeating: pixel, count: image.width * image.height).joined())
    }

    /// An opaque 1024 px gradient: red ramps across, green and blue stay well off the clear colour.
    private static func writeGradient(to url: URL) throws {
        let size = 1024
        var pixels = [UInt8](repeating: 255, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let index = (y * size + x) * 4
                pixels[index] = UInt8(80 + x * 175 / size)
                pixels[index + 1] = 200
                pixels[index + 2] = 120
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                          provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    /// Rewrites a JSON object file.
    private static func editJSON(_ url: URL, _ edit: (inout [String: Any]) -> Void) throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        edit(&object)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    private static let box = ["Models/OpenPoints/rootmotion_box.mdl": "models/rootmotion_box/rootmotion_box.mdl"]

    /// A frame's pixels, any channel order (the measures only compare channels' extremes).
    struct Image {
        let width: Int, height: Int, pixels: [UInt8]

        init(width: Int, height: Int, pixels: [UInt8]) {
            self.width = width
            self.height = height
            self.pixels = pixels
        }

        init(_ still: WEReferenceImage) {
            self.init(width: still.width, height: still.height, pixels: still.pixels)
        }

        /// The darkest and brightest channel at (x, y).
        func range(_ x: Int, _ y: Int) -> (low: Int, high: Int) {
            let index = (y * width + x) * 4
            let channels = pixels[index..<index + 3].map(Int.init)
            return (channels.min()!, channels.max()!)
        }
    }

    /// The Windows taskbar covers the stills' bottom 48 rows.
    private static let rows = 1080 - 48

    /// Pixels that differ from the top-left one (the clear colour) above the taskbar's rows.
    static func drawnPixels(_ image: Image) -> Int {
        let background = image.range(0, 0)
        var count = 0
        for y in 0..<min(rows, image.height) {
            for x in 0..<image.width {
                let pixel = image.range(x, y)
                if abs(pixel.low - background.low) + abs(pixel.high - background.high) > 24 { count += 1 }
            }
        }
        return count
    }

    /// Bright text pixels (every channel above 200) with a dark box pixel (every channel below
    /// 110) within 40 px both left and right in their row: the text drawn over the box.
    static func textOverBox(_ image: Image) -> Int {
        var count = 0
        for y in 0..<min(rows, image.height) {
            for x in 40..<(image.width - 40) where image.range(x, y).low > 200 {
                let dark = { (dx: Int) in image.range(x + dx, y).high < 110 }
                if (1...40).contains(where: { dark(-$0) }) && (1...40).contains(where: { dark($0) }) { count += 1 }
            }
        }
        return count
    }

    /// The centre of what differs from the background in one row; nil when nothing does.
    static func rowCentre(_ image: Image, row: Int) -> Double? {
        let background = image.range(0, row)
        let xs = (0..<image.width).filter {
            let pixel = image.range($0, row)
            return abs(pixel.low - background.low) + abs(pixel.high - background.high) > 120
        }
        guard let first = xs.first, let last = xs.last else { return nil }
        return Double(first + last) / 2
    }

    /// A writable copy of `name`'s fixture project with `binaries` (fixture path → project path).
    private func project(_ name: String, binaries: [String: String], as copy: String? = nil) throws -> URL {
        let directory = scratch.appending(path: copy ?? name, directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: Fixtures.url("Models/OpenPoints/\(name)"), to: directory)
        for (source, destination) in binaries {
            let target = directory.appending(path: destination)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: Fixtures.url(source), to: target)
        }
        return directory
    }

    private func frame(_ name: String, binaries: [String: String]) throws -> Image {
        try render(try project(name, binaries: binaries))
    }

    /// The settled frame of the wallpaper in `directory`.
    private func render(_ directory: URL) throws -> Image {
        let harness = try ModelSceneHarness(directory: directory, settings: SceneRenderSettings(), size: SIMD2(1920, 1080),
                                            storage: scratch.appending(path: "storage", directoryHint: .isDirectory))
        defer { harness.close() }
        try harness.settle(seconds: 10)
        let bytes = try TextureUploadTests.read(try XCTUnwrap(harness.renderer.sharedFrame), device: harness.device)
        XCTAssertEqual(harness.gpuErrors, [], directory.lastPathComponent)
        return Image(width: 1920, height: 1080, pixels: bytes)
    }
}
