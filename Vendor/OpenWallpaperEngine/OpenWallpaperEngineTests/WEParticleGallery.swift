import Accelerate
import Foundation
import XCTest
import simd
@testable import OpenWallpaperEngine

/// The WE particle gallery (tools/peer/particle_gallery on the captures' branch): WE 2.8.0.42 drew
/// every built-in preset variant and every particle component preview at 1920×1080.
/// - **Presets** (`ptcl_<preset>_<variant>`): build_particles.py makes one project per variant of
///   `assets/presets/*/preset.json`: the preset's folders copied in, a 1920×1080 background image
///   layer (`bg_black`, `bg_grey` for smoke and fog, `bg_pattern` for refractive variants; the
///   pictures are in `Tests/Fixtures/WEParticleGallery`), then the variant's objects with ids from
///   10 and their origins moved to the screen centre (960, 540), in an orthographic 1920×1080 scene
///   with clear colour black. An effect the variant depends on is copied in as the editor copies it.
/// - **Components** (`ptce_<component>`): WE's own previews, `assets/scenes/particleelementpreviews/<component>`,
///   copied as they are.
///
/// capture_particles.ps1 takes the still about 6 s after opening a project, then a 5 s clip. The
/// metrics compared are the clip's (5 fps): its mean coverage at half size (pixels whose largest
/// channel differs from the background, or for a component preview from the frame's most common
/// colour, by more than 40, over the rows above the taskbar; summarize.py's measure) and its
/// motion (summarize.py's).
enum WEParticleGallery {
    static let fixtures = Fixtures.url("WEParticleGallery")
    static let comparedHeight = 1030
    static let stillTime = 5.5
    static let motionStep = 0.2
    static let motionFrames = 25
    /// The cursor wasn't over the captured display.
    static let cursor = SIMD2<Double>(-1920, -1080)
    static let coverageThreshold = 40

    struct Item {
        var name: String
        /// The background picture a preset is drawn over; nil for a component preview.
        var background: String?
        /// Writes the project and returns its folder. Called right before the item draws: the whole
        /// gallery takes long enough for a temporary folder written up front to be cleaned away.
        var make: () throws -> URL
    }

    struct Expectation: Decodable {
        var name: String
        /// The clip's mean percent of compared pixels differing from the background (presets) or
        /// from the frame's most common colour (components) by more than 40.
        var coverage: Double
        var motion: Double
        var coverageTolerance: Double?
        var motionTolerance: Double?
        /// A known gap: its test-risks id and cause.
        var knownGap: String?
        /// A system of a few particles is one random draw per capture (WE's too): its clip's
        /// metrics are the mean over this many particle seeds (`WEReferenceRenderer.particleSeed`).
        var seeds: Int?

        var allowedCoverage: Double { coverageTolerance ?? max(0.3, coverage * 0.5) }
        var allowedMotion: Double { motionTolerance ?? max(0.3, motion * 0.5) }
    }

    static func expectations() throws -> [Expectation] {
        try JSONDecoder().decode([Expectation].self, from: Data(contentsOf: fixtures.appending(path: "expected.json")))
    }

    /// One project per variant of every preset in `assets/presets`, as build_particles.py builds them.
    static func presetItems(assets: URL, in parent: URL, only: Set<String>) throws -> [Item] {
        let fm = FileManager.default
        let presets = assets.appending(path: "presets", directoryHint: .isDirectory)
        var items: [Item] = []
        for preset in try fm.contentsOfDirectory(atPath: presets.path).sorted() {
            let source = presets.appending(path: preset, directoryHint: .isDirectory)
            let file = source.appending(path: "preset.json")
            guard fm.fileExists(atPath: file.path) else { continue }
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file), options: .json5Allowed) as? [String: Any])
            for (index, variant) in ((root["variants"] as? [[String: Any]]) ?? []).enumerated() {
                let name = "\(preset)_\(index)"
                guard only.isEmpty || only.contains(name) else { continue }
                let objects = (variant["objects"] as? [[String: Any]]) ?? []
                let names = objects.map { ($0["name"] as? String) ?? "" }.joined(separator: " ").lowercased()
                let background = names.contains("refract") ? "bg_pattern" : ["smoke", "fog"].contains(preset) ? "bg_grey" : "bg_black"
                items.append(Item(name: name, background: background) {
                    try makePresetProject(name: name, source: source, variant: variant, background: background,
                                          assets: assets, in: parent)
                })
            }
        }
        return items
    }

    /// Every component preview in `assets/scenes/particleelementpreviews`, copied as it is.
    static func elementItems(assets: URL, in parent: URL, only: Set<String>) throws -> [Item] {
        let fm = FileManager.default
        let previews = assets.appending(path: "scenes/particleelementpreviews", directoryHint: .isDirectory)
        var items: [Item] = []
        for component in try fm.contentsOfDirectory(atPath: previews.path).sorted() {
            let name = "ptce_\(component)"
            let source = previews.appending(path: component, directoryHint: .isDirectory)
            guard only.isEmpty || only.contains(name),
                  fm.fileExists(atPath: source.appending(path: "project.json").path) else { continue }
            items.append(Item(name: name, background: nil) {
                let directory = parent.appending(path: name, directoryHint: .isDirectory)
                if fm.fileExists(atPath: directory.path) { try fm.removeItem(at: directory) }
                try fm.createDirectory(at: parent, withIntermediateDirectories: true)
                try fm.copyItem(at: source, to: directory)
                return directory
            })
        }
        return items
    }

    private static func makePresetProject(name: String, source: URL, variant: [String: Any], background: String,
                                          assets: URL, in parent: URL) throws -> URL {
        let fm = FileManager.default
        let directory = parent.appending(path: "ptcl_\(name)", directoryHint: .isDirectory)
        if fm.fileExists(atPath: directory.path) { try fm.removeItem(at: directory) }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        for entry in try fm.contentsOfDirectory(atPath: source.path)
        where !entry.hasPrefix("preview") && entry != "preset.json" && !entry.hasPrefix(".") {
            try fm.copyItem(at: source.appending(path: entry), to: directory.appending(path: entry))
        }
        try fm.createDirectory(at: directory.appending(path: "materials"), withIntermediateDirectories: true)
        try fm.createDirectory(at: directory.appending(path: "models"), withIntermediateDirectories: true)
        try WEEffectGallery.texData(png: fixtures.appending(path: "\(background).png"))
            .write(to: directory.appending(path: "materials/bg.tex"))
        try json(["clampuvs": true, "format": "rgba8888", "nomip": true, "nonpoweroftwo": true])
            .write(to: directory.appending(path: "materials/bg.tex-json"))
        try json(["passes": [["blending": "translucent", "cullmode": "nocull", "depthtest": "disabled",
                              "depthwrite": "disabled", "shader": "genericimage2", "textures": ["bg"]]]])
            .write(to: directory.appending(path: "materials/bg.json"))
        try json(["autosize": true, "material": "materials/bg.json"]).write(to: directory.appending(path: "models/bg.json"))
        var objects: [[String: Any]] = [["id": 1, "name": "background", "image": "models/bg.json", "origin": "960 540 0",
                                         "angles": "0 0 0", "scale": "1 1 1", "size": "1920 1080", "visible": true]]
        for (index, original) in ((variant["objects"] as? [[String: Any]]) ?? []).enumerated() {
            var object = original
            object["id"] = 10 + index
            object["origin"] = offset(object["origin"] ?? "0 0 0", by: SIMD2(960, 540))
            if object["visible"] == nil { object["visible"] = true }
            objects.append(object)
        }
        // The editor copies an effect the preset depends on into the project (the lightshafts
        // variants; WE doesn't read an effect's materials from its assets folder).
        for dependency in (variant["dependencies"] as? [[String: Any]]) ?? [] {
            guard let file = dependency["file"] as? String, file.hasPrefix("effects/") else { continue }
            let effect = URL(fileURLWithPath: file).deletingLastPathComponent().lastPathComponent
            try WEEffectGallery.copyEffect(effect, assets: assets, into: directory)
        }
        let scene: [String: Any] = [
            "camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"],
            "general": ["clearcolor": "0 0 0", "ambientcolor": "0.3 0.3 0.3", "skylightcolor": "0.3 0.3 0.3",
                        "orthogonalprojection": ["width": 1920, "height": 1080]],
            "objects": objects]
        try json(scene).write(to: directory.appending(path: "scene.json"))
        let project: [String: Any] = ["file": "scene.json", "title": "ptcl_\(name)", "type": "scene",
                                      "general": ["properties": [String: Any]()]]
        try json(project).write(to: directory.appending(path: "project.json"))
        return directory
    }

    /// build_particles.py's `offset`: "x y z" moved by `delta`, formatted to three decimals; anything
    /// else unchanged.
    private static func offset(_ value: Any, by delta: SIMD2<Double>) -> Any {
        let parts = String(describing: value).split(separator: " ").compactMap { Double($0) }
        guard parts.count == 3 else { return value }
        return String(format: "%.3f %.3f %.3f", parts[0] + delta.x, parts[1] + delta.y, parts[2])
    }

    private static func json(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: - Metrics

    /// summarize.py's coverage: the percent of pixels in the rows above the taskbar whose largest
    /// channel differs from `background` by more than 40.
    static func coverage(_ image: WEReferenceImage, background: WEReferenceImage, height: Int = comparedHeight) -> Double {
        let count = image.width * min(height, image.height, background.height)
        var covered = 0
        image.pixels.withUnsafeBufferPointer { p in
            background.pixels.withUnsafeBufferPointer { q in
                for i in 0..<count {
                    let o = i * 4
                    let d = max(abs(Int(p[o]) - Int(q[o])), abs(Int(p[o + 1]) - Int(q[o + 1])), abs(Int(p[o + 2]) - Int(q[o + 2])))
                    if d > coverageThreshold { covered += 1 }
                }
            }
        }
        return Double(covered) * 100 / Double(count)
    }

    /// `image` resized to `width` × `height` (vImage; the harness's per-pixel loops are slow in a Debug build).
    static func scaled(_ image: WEReferenceImage, width: Int, height: Int) -> WEReferenceImage {
        var result = WEReferenceImage(width: width, height: height)
        var source = image.pixels
        source.withUnsafeMutableBytes { input in
            result.pixels.withUnsafeMutableBytes { output in
                var from = vImage_Buffer(data: input.baseAddress, height: vImagePixelCount(image.height),
                                         width: vImagePixelCount(image.width), rowBytes: image.width * 4)
                var to = vImage_Buffer(data: output.baseAddress, height: vImagePixelCount(height),
                                       width: vImagePixelCount(width), rowBytes: width * 4)
                _ = vImageScale_ARGB8888(&from, &to, nil, vImage_Flags(kvImageNoFlags))
            }
        }
        return result
    }

    /// summarize.py's motion: the frames at 480×270 luma (BT.601), the top 257 rows, the mean
    /// absolute change between consecutive frames.
    static func motion(_ frames: [WEReferenceImage]) -> Double {
        let lumas = frames.map { frame -> [Float] in
            let small = scaled(frame, width: 480, height: 270)
            return small.pixels.withUnsafeBufferPointer { p in
                (0..<(480 * 257)).map { i in 0.299 * Float(p[i * 4]) + 0.587 * Float(p[i * 4 + 1]) + 0.114 * Float(p[i * 4 + 2]) }
            }
        }
        guard lumas.count > 1 else { return 0 }
        var total = 0.0
        for (a, b) in zip(lumas, lumas.dropFirst()) {
            var difference = [Float](repeating: 0, count: a.count)
            vDSP_vsub(b, 1, a, 1, &difference, 1, vDSP_Length(a.count))
            var mean: Float = 0
            vDSP_meamgv(difference, 1, &mean, vDSP_Length(a.count))
            total += Double(mean)
        }
        return total / Double(lumas.count - 1)
    }

    /// The coverage against the frame's most common colour, for a component preview (a flat clear colour).
    static func coverageAgainstMode(_ image: WEReferenceImage, height: Int = comparedHeight) -> Double {
        let count = image.width * min(height, image.height)
        var counts: [UInt32: Int] = [:]
        image.pixels.withUnsafeBufferPointer { p in
            for i in stride(from: 0, to: count, by: 7) {
                let o = i * 4
                counts[UInt32(p[o]) << 16 | UInt32(p[o + 1]) << 8 | UInt32(p[o + 2]), default: 0] += 1
            }
        }
        let mode = counts.max { $0.value < $1.value }?.key ?? 0
        var flat = WEReferenceImage(width: image.width, height: image.height)
        for i in 0..<(image.width * image.height) {
            flat.pixels[i * 4] = UInt8(mode >> 16 & 0xff)
            flat.pixels[i * 4 + 1] = UInt8(mode >> 8 & 0xff)
            flat.pixels[i * 4 + 2] = UInt8(mode & 0xff)
        }
        return coverage(image, background: flat, height: height)
    }

    /// Every second pixel of every second row (the gallery's background at the clip's half size).
    static func subsampled(_ image: WEReferenceImage) -> WEReferenceImage {
        var result = WEReferenceImage(width: image.width / 2, height: image.height / 2)
        for y in 0..<result.height {
            for x in 0..<result.width {
                let from = ((y * 2) * image.width + x * 2) * 4, to = (y * result.width + x) * 4
                result.pixels.replaceSubrange(to..<(to + 4), with: image.pixels[from..<(from + 4)])
            }
        }
        return result
    }
}
